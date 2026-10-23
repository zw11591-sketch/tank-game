extends Node
## 局域网联机核心（autoload `Net`）。
##
## 角色：
##   OFFLINE —— 单机战役，所有网络函数都是空操作。
##   HOST    —— 房主。模拟敌人 AI、炮弹、伤害、基地、道具、计分，并把状态广播出去。
##   CLIENT  —— 客户端。只模拟自己的车，远端对象按快照插值；炮弹是纯视觉复制品。
##
## 这里不使用 MultiplayerSpawner / MultiplayerSynchronizer：本作的战场、坦克、炮弹
## 全部在运行时由代码构建，节点路径不稳定；而联机需要「每个玩家拥有自己车的移动权，
## 房主拥有战斗与关卡权」这种不对称权威，手工 RPC 更容易控制，也更好排查。

enum Role { OFFLINE, HOST, CLIENT }

const PROTOCOL := 1
const DEFAULT_PORT := 45888
const DEFAULT_DISCOVERY_PORT := 45887
const MAX_PLAYERS := 4
const SNAPSHOT_HZ := 25.0
const CLIENT_STATE_HZ := 30.0
## 房主对客户端上报位移的容忍上限。超过这个距离大概率是瞬移/丢包，
## 直接把房主那份位置拉回客户端上报的位置，而不是让两边越跑越远。
const HOST_SNAP_DIST := 3.0

signal roster_changed
signal match_started(info: Dictionary)
signal match_ended(won: bool, score: int)
signal stage_started(info: Dictionary)
signal session_ended(reason: String)
signal notice(text: String)

var role: int = Role.OFFLINE
var game: Node = null
var discovery: LanDiscovery = null

var room_name := "坦克房间"
var room_stage := 1
var room_terrain := -1
var room_difficulty := 1
var room_seed := 0

## peer_id -> {name, tank_id, ready, lives, alive}
var players: Dictionary = {}
## net_id -> Tank。玩家用 peer_id 当 net_id，敌人从 1001 开始。
var tanks: Dictionary = {}

var match_active := false
var match_info: Dictionary = {}

var _snapshot_t := 0.0
var _client_t := 0.0
var _next_enemy_id := 1001
var _next_powerup_id := 1
var _join_ip := ""
var _last_client_state: Dictionary = {}
## 房主侧：通过校验的客户端击发次数。探针用它确认"开火"这条链路通了。
var _net_shots := 0
## 客户端侧：收到房主开火广播并生成表现炮弹的次数。探针用它确认回程链路。
var _net_visual_shots := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	discovery = LanDiscovery.new()
	discovery.name = "LanDiscovery"
	add_child(discovery)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func setup_game(g: Node) -> void:
	game = g


# ---------------- 角色与身份 ----------------

func is_offline() -> bool:
	return role == Role.OFFLINE


func is_host() -> bool:
	return role == Role.HOST


func is_client() -> bool:
	return role == Role.CLIENT


func is_multiplayer() -> bool:
	return role != Role.OFFLINE


func local_pid() -> int:
	# 建房过程中（create_server 之前）还没有 peer，此时房主就是 1。
	# 直接问 multiplayer 会刷 "No multiplayer peer is assigned"。
	if role == Role.OFFLINE or not multiplayer.has_multiplayer_peer():
		return 1
	return multiplayer.get_unique_id()


func my_name() -> String:
	var n := String(Settings.player_name).strip_edges()
	if n.is_empty():
		n = OS.get_environment("USERNAME").strip_edges()
	if n.is_empty():
		n = "指挥官"
	return n


## 客户端连的是哪台机器（列表点击或手动输入都记在这里）。房主返回空串。
## 大厅房间页拿它显示"已连接：x.x.x.x"，出问题时玩家能直接报出这个地址。
func server_addr() -> String:
	return _join_ip if role == Role.CLIENT else ""


func game_build() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "%s/%s/p%d" % [
		String(ProjectSettings.get_setting("application/config/name", "TankBattle")),
		String(v.get("string", "4.x")), PROTOCOL,
	]


func my_row() -> Dictionary:
	return players.get(local_pid(), {})


func get_players_array() -> Array:
	var list: Array = []
	for pid in players.keys():
		var row: Dictionary = (players[pid] as Dictionary).duplicate()
		row["pid"] = int(pid)
		list.append(row)
	list.sort_custom(func(a, b): return int(a["pid"]) < int(b["pid"]))
	return list


# ---------------- 建房 / 加入 ----------------

func host_room(room: String = "") -> bool:
	shutdown_peer()
	role = Role.HOST
	match_active = false
	room_name = room if not room.strip_edges().is_empty() else "%s的房间" % my_name()
	room_stage = 1
	room_terrain = -1
	room_difficulty = 1
	players.clear()
	players[1] = _new_row(1)

	var peer := ENetMultiplayerPeer.new()
	# ENet 的 max_clients 不含房主自己，所以是"人数上限 - 1"。
	# 用设置里的值而不是常量，房间信标里的 max 才和真实容量一致。
	var err := peer.create_server(Settings.net_port, maxi(1, Settings.net_max_players - 1))
	if err != OK:
		role = Role.OFFLINE
		notice.emit("无法创建房间：%s（端口 %d 可能被占用）" % [
			error_string(err), Settings.net_port])
		return false
	multiplayer.multiplayer_peer = peer
	discovery.start_host(Callable(self, "beacon_info"), Settings.discovery_port)
	roster_changed.emit()
	notice.emit("房间已创建：%s" % room_name)
	return true


func join_room(ip: String, port := -1) -> bool:
	shutdown_peer()
	var target := ip.strip_edges()
	if target.is_empty():
		notice.emit("请输入房主 IP")
		return false
	_join_ip = target
	role = Role.CLIENT
	match_active = false
	players.clear()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(target, port if port > 0 else Settings.net_port)
	if err != OK:
		role = Role.OFFLINE
		notice.emit("无法连接 %s：%s" % [target, error_string(err)])
		return false
	multiplayer.multiplayer_peer = peer
	notice.emit("正在连接 %s …" % target)
	return true


func leave() -> void:
	shutdown_peer()
	role = Role.OFFLINE
	match_active = false
	players.clear()
	tanks.clear()
	match_info.clear()
	if discovery != null:
		discovery.stop()


func shutdown_peer() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
		multiplayer.multiplayer_peer = null
	if discovery != null:
		discovery.stop()


func _new_row(pid: int) -> Dictionary:
	return {
		"pid": pid,
		"name": my_name() if pid == local_pid() or role == Role.OFFLINE else "玩家%d" % pid,
		"tank_id": Settings.selected_tank if TankRoster.has(Settings.selected_tank) \
				else TankRoster.DEFAULT_ID,
		"ready": false,
		"lives": 3,
		"alive": true,
	}


# ---------------- 大厅状态 ----------------

func set_tank(tank_id: String) -> void:
	if not TankRoster.has(tank_id):
		return
	Settings.selected_tank = tank_id
	Settings.save_cfg()
	if role == Role.CLIENT:
		rpc_id(1, "net_set_tank", tank_id)
		return
	var row: Dictionary = players.get(local_pid(), {})
	if row.is_empty():
		return
	row["tank_id"] = tank_id
	players[local_pid()] = row
	if role == Role.HOST:
		rpc("net_roster", players)
	roster_changed.emit()


func set_ready(ready: bool) -> void:
	if role == Role.CLIENT:
		rpc_id(1, "net_set_ready", ready)
		return
	var row: Dictionary = players.get(local_pid(), {})
	if row.is_empty():
		return
	row["ready"] = ready
	players[local_pid()] = row
	if role == Role.HOST:
		rpc("net_roster", players)
	roster_changed.emit()


func set_room(stage: int, terrain: int, difficulty: int) -> void:
	if role != Role.HOST:
		return
	room_stage = clampi(stage, 1, 8)
	room_terrain = clampi(terrain, -1, Arena.TERRAINS.size() - 1)
	room_difficulty = clampi(difficulty, 0, 2)
	var info := {"stage": room_stage, "terrain": room_terrain, "difficulty": room_difficulty}
	rpc("net_room", info)
	roster_changed.emit()


func start_match() -> void:
	if role != Role.HOST or match_active:
		return
	if players.is_empty():
		return
	# 房主独占地图/难度决定权；其余人只负责选车与准备。
	var pick_terrain := room_terrain
	if pick_terrain < 0:
		pick_terrain = randi() % Arena.TERRAINS.size()
	room_seed = int(Time.get_unix_time_from_system()) ^ randi()
	# 出生顺序按 peer id 排序，而不是按 Dictionary 的插入顺序：
	# 后加入的玩家 id 更大，但两个客户端拿到的字典遍历顺序未必一致。
	var pids: Array = players.keys()
	pids.sort()
	var list: Array = []
	var i := 0
	for pid in pids:
		var row: Dictionary = players[pid]
		row["lives"] = 3
		row["alive"] = true
		players[pid] = row
		list.append({
			"pid": int(pid),
			"name": String(row.get("name", "玩家")),
			"tank_id": String(row.get("tank_id", TankRoster.DEFAULT_ID)),
			"spawn": i,
		})
		i += 1
	match_info = {
		"stage": room_stage,
		"terrain": pick_terrain,
		"seed": room_seed,
		"difficulty": room_difficulty,
		"players": list,
	}
	match_active = true
	# 先广播开局，再让房主自己生成战场：房主的 _start_stage() 会紧接着发出
	# net_stage_start，可靠 RPC 按发送顺序到达，客户端因此一定先拿到名册
	# （match_info.players）再按名册落车。反过来的话客户端会先收到关卡事件、
	# 用空名册生成一张没有玩家的图。
	rpc("net_match_start", match_info)
	if game != null and game.has_method("net_begin_match"):
		game.net_begin_match(match_info)
	match_started.emit(match_info)


func beacon_info() -> Dictionary:
	return {
		"name": room_name,
		"stage": room_stage,
		"diff": room_difficulty,
		"players": players.size(),
		"max": Settings.net_max_players,
		"port": Settings.net_port,
		# 对局中握手会被拒绝，但让大厅在点击之前就显示"对局进行中"，
		# 比点进去再弹一条错误提示友好。
		"active": match_active,
		"build": game_build(),
	}


# ---------------- 连接生命周期 ----------------

func _on_peer_connected(_pid: int) -> void:
	# 真正的入场要等 hello：对方必须先报协议版本、构建号与昵称。
	pass


func _on_connected_to_server() -> void:
	discovery.stop()
	rpc_id(1, "net_hello", PROTOCOL, game_build(), my_name(), Settings.selected_tank)


func _on_connection_failed() -> void:
	shutdown_peer()
	role = Role.OFFLINE
	session_ended.emit("连接失败：请检查 IP、端口与防火墙")


func _on_server_disconnected() -> void:
	shutdown_peer()
	role = Role.OFFLINE
	match_active = false
	session_ended.emit("房主已离开，房间关闭")


func _on_peer_disconnected(pid: int) -> void:
	if role != Role.HOST:
		return
	players.erase(pid)
	unregister_tank(pid)
	if match_active and game != null and game.has_method("net_player_left"):
		game.net_player_left(pid)
	rpc("net_roster", players)
	roster_changed.emit()


# ---------------- 大厅 RPC ----------------

@rpc("any_peer", "call_remote", "reliable")
func net_hello(protocol: int, build: String, pname: String, tank_id: String) -> void:
	if role != Role.HOST:
		return
	var pid := multiplayer.get_remote_sender_id()
	if pid <= 1:
		return
	if protocol != PROTOCOL or build != game_build():
		rpc_id(pid, "net_reject", "版本不一致：请使用同一份构建")
		return
	if match_active:
		rpc_id(pid, "net_reject", "对局已经开始")
		return
	if players.size() >= Settings.net_max_players:
		rpc_id(pid, "net_reject", "房间已满")
		return
	var row := _new_row(pid)
	row["name"] = pname if not pname.strip_edges().is_empty() else "玩家%d" % pid
	if TankRoster.has(tank_id):
		row["tank_id"] = tank_id
	players[pid] = row
	rpc_id(pid, "net_welcome", {
		"room_name": room_name,
		"stage": room_stage,
		"terrain": room_terrain,
		"difficulty": room_difficulty,
		"players": players,
		"protocol": PROTOCOL,
	})
	rpc("net_roster", players)
	roster_changed.emit()
	notice.emit("%s 加入了房间" % String(row["name"]))


@rpc("authority", "call_remote", "reliable")
func net_welcome(info: Dictionary) -> void:
	room_name = String(info.get("room_name", "坦克房间"))
	room_stage = int(info.get("stage", 1))
	room_terrain = int(info.get("terrain", -1))
	room_difficulty = int(info.get("difficulty", 1))
	var p = info.get("players", {})
	players = p if p is Dictionary else {}
	roster_changed.emit()
	notice.emit("已加入 %s" % room_name)


@rpc("authority", "call_remote", "reliable")
func net_reject(reason: String) -> void:
	notice.emit(reason)
	leave()
	session_ended.emit(reason)


@rpc("authority", "call_remote", "reliable")
func net_roster(roster: Dictionary) -> void:
	players = roster
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func net_set_tank(tank_id: String) -> void:
	if role != Role.HOST or not TankRoster.has(tank_id):
		return
	var pid := multiplayer.get_remote_sender_id()
	var row: Dictionary = players.get(pid, {})
	if row.is_empty():
		return
	row["tank_id"] = tank_id
	players[pid] = row
	rpc("net_roster", players)
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func net_set_ready(ready: bool) -> void:
	if role != Role.HOST:
		return
	var pid := multiplayer.get_remote_sender_id()
	var row: Dictionary = players.get(pid, {})
	if row.is_empty():
		return
	row["ready"] = ready
	players[pid] = row
	rpc("net_roster", players)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func net_room(info: Dictionary) -> void:
	room_stage = int(info.get("stage", room_stage))
	room_terrain = int(info.get("terrain", room_terrain))
	room_difficulty = int(info.get("difficulty", room_difficulty))
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func net_match_start(info: Dictionary) -> void:
	if role != Role.CLIENT:
		return
	match_info = info
	match_active = true
	if game != null and game.has_method("net_begin_match"):
		game.net_begin_match(info)
	match_started.emit(info)


## 房主把最新名册发给客户端。大厅里的准备、选车、命数变化都走这一条。
func push_roster() -> void:
	if role == Role.HOST:
		rpc("net_roster", players)


func broadcast_stage_start(stage: int, terrain: int, seed: int, diff: int) -> void:
	if role != Role.HOST:
		return
	var info := {"stage": stage, "terrain": terrain, "seed": seed, "difficulty": diff}
	rpc("net_stage_start", info)
	stage_started.emit(info)


@rpc("authority", "call_remote", "reliable")
func net_stage_start(info: Dictionary) -> void:
	if role != Role.CLIENT:
		return
	if game != null and game.has_method("net_begin_stage"):
		game.net_begin_stage(info)
	stage_started.emit(info)


# ---------------- 注册表 ----------------

func register_tank(t: Tank, net_id: int) -> void:
	if t == null:
		return
	t.net_id = net_id
	tanks[net_id] = t


func unregister_tank(net_id: int) -> void:
	tanks.erase(net_id)


func get_tank(net_id: int) -> Tank:
	var t = tanks.get(net_id, null)
	if t != null and is_instance_valid(t):
		return t
	tanks.erase(net_id)
	return null


func clear_tanks() -> void:
	tanks.clear()


func tank_for_peer(pid: int) -> Tank:
	for t in tanks.values():
		if t is Player and is_instance_valid(t) and int(t.peer_id) == pid:
			return t
	return null


func alloc_enemy_id() -> int:
	_next_enemy_id += 1
	return _next_enemy_id


func alloc_powerup_id() -> int:
	_next_powerup_id += 1
	return _next_powerup_id


# ---------------- 每帧网络采样 ----------------

func _process(delta: float) -> void:
	if not match_active or game == null:
		return
	if role == Role.HOST:
		_snapshot_t -= delta
		if _snapshot_t <= 0.0:
			_snapshot_t = 1.0 / SNAPSHOT_HZ
			if game.has_method("net_collect_snapshot"):
				var data: Dictionary = game.net_collect_snapshot()
				if not data.is_empty():
					rpc("net_snapshot", data)
	elif role == Role.CLIENT:
		_client_t -= delta
		if _client_t <= 0.0:
			_client_t = 1.0 / CLIENT_STATE_HZ
			if game.has_method("net_collect_local_state"):
				var st: Dictionary = game.net_collect_local_state()
				if not st.is_empty():
					rpc_id(1, "net_client_state", st)


@rpc("authority", "call_remote", "unreliable_ordered")
func net_snapshot(data: Dictionary) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_apply_snapshot"):
		game.net_apply_snapshot(data)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func net_client_state(data: Dictionary) -> void:
	if role != Role.HOST or game == null:
		return
	var pid := multiplayer.get_remote_sender_id()
	if not players.has(pid):
		return
	_last_client_state = data
	if game.has_method("net_apply_client_state"):
		game.net_apply_client_state(pid, data)


# ---------------- 战斗事件 ----------------

## 由 Tank.fire() 调用。客户端只上报意图，真正生成炮弹的是房主。
func submit_shot(shooter: Tank, origin: Vector3, dir: Vector3, kind: int) -> void:
	if shooter == null:
		return
	var uid := int(shooter.net_id) * 100000 + int(shooter.shot_count)
	if role == Role.CLIENT:
		rpc_id(1, "net_request_shot", origin, dir, kind, uid)
		return
	_spawn_shot_bundle(shooter, origin, dir, kind, uid)


## 多弹装填的散射统一放在这里：房主替所有玩家生成炮弹，于是客户端
## 不会连续发三次请求、被房主的装填冷却挡掉后两次。
func _spawn_shot_bundle(shooter: Tank, origin: Vector3, dir: Vector3, kind: int, uid: int) -> void:
	if game == null or not game.has_method("spawn_shell"):
		return
	game.spawn_shell(shooter, origin, dir, kind, uid)
	if role == Role.HOST:
		rpc("net_shot", shooter.net_id, origin, dir, kind, uid)
	if shooter.multi_t > 0.0:
		for s in [-1.0, 1.0]:
			var d := dir.rotated(Vector3.UP, deg_to_rad(2.4) * s)
			game.spawn_shell(shooter, origin, d, kind, uid)
			if role == Role.HOST:
				rpc("net_shot", shooter.net_id, origin, d, kind, uid)


@rpc("any_peer", "call_remote", "reliable")
func net_request_shot(origin: Vector3, dir: Vector3, kind: int, uid: int) -> void:
	if role != Role.HOST or game == null:
		return
	var pid := multiplayer.get_remote_sender_id()
	var t := tank_for_peer(pid)
	if t == null or not t.alive:
		return
	# 房主用自己那份装填计时做校验：客户端可以改自己的 UI，但改不了这里的冷却。
	if not t.can_fire():
		return
	# 发出点只允许在炮口附近，防止伪造一个穿墙的起点。
	if origin.distance_to(t.muzzle_pos()) > 6.0:
		origin = t.muzzle_pos()
	t.shot_count += 1
	t._shot_id += 1
	t._hit_claimed = false
	t.reload_t = t.reload_time
	t.expose_t = Tank.EXPOSE_TIME
	t._recoil = 0.55
	_net_shots += 1
	t.play_fire_fx(dir, kind)
	_spawn_shot_bundle(t, origin, dir, kind, uid)


@rpc("authority", "call_remote", "reliable")
func net_shot(net_id: int, origin: Vector3, dir: Vector3, kind: int, uid: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	_net_visual_shots += 1
	if game.has_method("spawn_visual_shell"):
		game.spawn_visual_shell(net_id, origin, dir, kind, uid)


func broadcast_hit(data: Dictionary) -> void:
	if role == Role.HOST:
		rpc("net_hit", data)


## 把"你这一发打出了什么结果"单独发给射手。合作模式下房主替所有玩家结算，
## 命中提示与命中率必须回到射手自己的 HUD，而不是显示在房主屏幕上。
func send_shell_feedback(pid: int, uid: int, text: String, pos: Vector3,
		result: String, amount: int, etype: int) -> void:
	if role == Role.HOST and pid > 1:
		rpc_id(pid, "net_shell_feedback", uid, text, pos, result, amount, etype)


@rpc("authority", "call_remote", "reliable")
func net_shell_feedback(uid: int, text: String, pos: Vector3, result: String,
		amount: int, etype: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_apply_feedback"):
		game.net_apply_feedback(uid, text, pos, result, amount, etype)


@rpc("authority", "call_remote", "reliable")
func net_hit(data: Dictionary) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_apply_hit"):
		game.net_apply_hit(data)


func broadcast_death(net_id: int, pos: Vector3, yaw: float, killer_id: int) -> void:
	if role == Role.HOST:
		rpc("net_death", net_id, pos, yaw, killer_id)


@rpc("authority", "call_remote", "reliable")
func net_death(net_id: int, pos: Vector3, yaw: float, killer_id: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_apply_death"):
		game.net_apply_death(net_id, pos, yaw, killer_id)


## 一名玩家掉线。名册 RPC 只会把名字从列表里删掉，场上的那辆车如果没人
## 通知就会永远停在原地（其他客户端仍把它当作存活队友画在雷达与名牌上）。
func broadcast_player_left(pid: int) -> void:
	if role == Role.HOST:
		rpc("net_player_left", pid)


@rpc("authority", "call_remote", "reliable")
func net_player_left(pid: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_remote_player_left"):
		game.net_remote_player_left(pid)


func broadcast_enemy_spawn(data: Dictionary) -> void:
	if role == Role.HOST:
		rpc("net_enemy_spawn", data)


@rpc("authority", "call_remote", "reliable")
func net_enemy_spawn(data: Dictionary) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_spawn_enemy"):
		game.net_spawn_enemy(data)


func broadcast_player_spawn(data: Dictionary) -> void:
	if role == Role.HOST:
		rpc("net_player_spawn", data)


@rpc("authority", "call_remote", "reliable")
func net_player_spawn(data: Dictionary) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_spawn_player"):
		game.net_spawn_player(data)


func broadcast_cell(cell: Vector2i) -> void:
	if role == Role.HOST:
		rpc("net_cell", cell)


@rpc("authority", "call_remote", "reliable")
func net_cell(cell: Vector2i) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_apply_cell"):
		game.net_apply_cell(cell)


func broadcast_powerup_spawn(data: Dictionary) -> void:
	if role == Role.HOST:
		rpc("net_powerup_spawn", data)


@rpc("authority", "call_remote", "reliable")
func net_powerup_spawn(data: Dictionary) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_spawn_powerup"):
		game.net_spawn_powerup(data)


func broadcast_powerup_taken(uid: int, pid: int, ptype: int) -> void:
	if role == Role.HOST:
		rpc("net_powerup_taken", uid, pid, ptype)


@rpc("authority", "call_remote", "reliable")
func net_powerup_taken(uid: int, pid: int, ptype: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	if game.has_method("net_take_powerup"):
		game.net_take_powerup(uid, pid, ptype)


func broadcast_smoke(pos: Vector3, dur: float, owner := 0) -> void:
	if role == Role.HOST:
		rpc("net_smoke", pos, dur, owner)


@rpc("authority", "call_remote", "reliable")
func net_smoke(pos: Vector3, dur: float, owner: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	# 自己丢的烟在本地已经立刻生效了（见 Player._drop_smoke）。房主回传的
	# 这一份只用于让其他客户端看见，自己再放一次会叠出两团烟。
	if owner == local_pid():
		return
	if game.has_method("net_add_smoke"):
		game.net_add_smoke(pos, dur)


## 客户端丢烟：烟幕会影响敌人的视线，而敌人由房主模拟，所以必须让房主知道。
## 本地先放一团保证手感，房主收到后再广播给其余客户端。
func request_smoke(pos: Vector3, dur: float) -> void:
	if role == Role.CLIENT:
		rpc_id(1, "net_request_smoke", pos, dur)


@rpc("any_peer", "call_remote", "reliable")
func net_request_smoke(pos: Vector3, dur: float) -> void:
	if role != Role.HOST or game == null:
		return
	var pid := multiplayer.get_remote_sender_id()
	var t := tank_for_peer(pid)
	if t == null or not t.alive:
		return
	# 位置只接受该玩家车体附近，防止伪造一团能罩住全场的烟。
	if pos.distance_to(t.global_position) > 6.0:
		pos = t.global_position
	if game.has_method("deploy_smoke"):
		game.deploy_smoke(pos, clampf(dur, 1.0, 12.0), pid)


func broadcast_match_end(won: bool, score_value: int) -> void:
	if role == Role.HOST:
		# 房主自己也要停掉快照与客户端状态通道：结算后继续每 40 ms 发一份
		# 世界状态纯属浪费，而且 match_active 卡在 true 会让下一次 start_match 被挡。
		match_active = false
		rpc("net_match_end", won, score_value)


@rpc("authority", "call_remote", "reliable")
func net_match_end(won: bool, score_value: int) -> void:
	if role != Role.CLIENT or game == null:
		return
	match_active = false
	if game.has_method("net_end_match"):
		game.net_end_match(won, score_value)
	match_ended.emit(won, score_value)
