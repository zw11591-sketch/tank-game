extends Node
## 联机自动验收探针：在同一台机器上开两个 headless 进程验证局域网合作模式。
##
##   godot --headless --path . res://tools/NetProbe.tscn -- --role=host --port=45988
##   godot --headless --path . res://tools/NetProbe.tscn -- --role=client --port=45988
##
## 两个进程通过回环地址连接，检查：握手与名册、双车生成、客户端移动是否被
## 房主收到、开火是否生成炮弹、拆墙事件、敌车死亡广播、以及客户端退出后
## 房主是否清掉他的车。每个断言都打印 PASS/FAIL，最后以退出码 0/1 结束。
##
## 两台机器冷启动时都要加载模型与纹理，客户端可能十几秒才进主循环，所以
## 所有等待都做成"轮询到条件成立"，而不是按固定秒数对齐；固定时间轴在
## 慢机器上会稳定误报。

const PORT := 45988
## 等待对端/事件的上限。正常回环一两秒就满足，留足余量只为冷启动。
const JOIN_TIMEOUT := 30.0
const EVENT_TIMEOUT := 15.0

var game: Node
var role := "host"
var port := PORT
var fails: Array = []
var checks := 0
var _remote_pid := 0
var _remote_spawn := Vector3.INF
var _enemy_id := 0
var _brick := Vector2i(-1, -1)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--role="):
			role = a.trim_prefix("--role=")
		elif a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	Settings.net_port = port
	Settings.player_name = "探针-" + role

	# 直接实例化正式主场景：探针要验证的是真实流程，而不是另写一条旁路。
	var scene: PackedScene = load("res://scenes/Main.tscn")
	game = scene.instantiate()
	add_child(game)

	if role == "host":
		await _run_host()
	else:
		await _run_client()


func _check(label: String, ok: bool, extra := "") -> void:
	checks += 1
	if ok:
		print("  PASS  ", label, ("  " + extra) if not extra.is_empty() else "")
	else:
		fails.append(label)
		print("  FAIL  ", label, ("  " + extra) if not extra.is_empty() else "")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## 每 0.1 秒检查一次条件，返回条件是否在超时前成立。
## 探针里的每个环节都可能被加载时间或网络抖动推迟，轮询比固定睡眠稳。
func _wait_until(cond: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if bool(cond.call()):
			return true
		await _wait(0.1)
		waited += 0.1
	return bool(cond.call())


func _report() -> void:
	if fails.is_empty():
		print("PROBE %s OK  (%d checks)" % [role.to_upper(), checks])
		get_tree().quit(0)
	else:
		print("PROBE %s FAILED  (%d/%d checks failed): %s" % [
			role.to_upper(), fails.size(), checks, ", ".join(fails)])
		get_tree().quit(1)


# ---------------- 房主 ----------------

func _run_host() -> void:
	if not Net.host_room("探针房间"):
		print("PROBE HOST FAILED: 无法建房（端口 %d 被占用？）" % port)
		get_tree().quit(1)
		return
	# 等客户端握手。冷启动时客户端要先加载完所有模型，窗口放宽到 30 秒。
	if not await _wait_until(func(): return Net.players.size() >= 2, JOIN_TIMEOUT):
		print("PROBE HOST FAILED: %d 秒内没有客户端加入" % int(JOIN_TIMEOUT))
		get_tree().quit(1)
		return

	var pids: Array = Net.players.keys()
	pids.sort()
	_remote_pid = int(pids[1])
	print("PROBE HOST: 客户端 %d 已加入，开始对局" % _remote_pid)
	Net.start_match()
	await _wait(0.5)
	_check("双人开局进入 ready/play", game.state == "ready" or game.state == "play", game.state)
	_check("房主侧有两辆真人车", game.players.size() == 2, str(game.players.size()))
	var remote = game.player_for_pid(_remote_pid)
	_check("房主侧存在客户端车辆", remote != null)
	if remote != null:
		_remote_spawn = remote.global_position

	# 在远离玩家的角落放一辆陪练车，作为"房主生成 → 客户端复制"的样本。
	await _wait(0.4)
	_enemy_id = Net.alloc_enemy_id()
	var e := Enemy.new()
	e.configure(1, game.stage, game.difficulty)
	game._scale_enemy_for_coop(e)
	e.is_remote = false
	e.team = 1
	e.net_id = _enemy_id
	e.setup(game, game.arena, game.arena.cell_center(2, 2))
	game.add_child(e)
	game.enemies.append(e)
	Net.register_tank(e, _enemy_id)
	# 让这辆陪练车只挨打不还手：探针只关心事件是否到达，不关心 AI 行为。
	e._react_t = 9999.0
	e._aim_err_t = 9999.0
	Net.broadcast_enemy_spawn({
		"id": _enemy_id, "type": 1, "pos": e.global_position, "hp": e.hp,
		"stage": game.stage, "diff": game.difficulty,
	})
	print("PROBE HOST: 敌车 net_id=%d 已生成" % _enemy_id)

	# 客户端会在进入 play 后踩油门两秒。等房主这份副本真正动起来。
	var moved_ok: bool = await _wait_until(func():
		return remote != null and is_instance_valid(remote) \
				and remote.global_position.distance_to(_remote_spawn) > 1.0,
			20.0)
	var moved := 0.0
	var flags := "nil"
	if remote != null and is_instance_valid(remote):
		moved = remote.global_position.distance_to(_remote_spawn)
		# 这一行是排查用的不变量：房主侧这个副本必须是"非本地、远端、正确 peer"，
		# 任何一项不对，apply_net_state / 插值都会静默失效，表现为车定在原地。
		flags = "local=%s remote=%s peer=%d" % [
			str(remote.is_local), str(remote.is_remote), int(remote.peer_id)]
	_check("房主收到客户端位移", moved_ok,
			"%.2f m / %d 包 / %s" % [moved, game._net_client_updates, flags])
	_check("位移校验未误伤", game._net_pullbacks == 0, str(game._net_pullbacks))

	# 客户端在进入 play 后立刻打过一发，房主应已收到并生成了权威炮弹。
	var shot_ok: bool = await _wait_until(func(): return Net._net_shots > 0, EVENT_TIMEOUT)
	_check("房主收到客户端开火", shot_ok, str(Net._net_shots))

	# 拆一格砖墙，客户端应收到 cell 事件。先在房主自己这边确认这一格真的碎了：
	# 否则客户端超时会被误判成"事件没到"，而实际是根本没触发事件。
	_brick = _first_brick(game.arena)
	_check("找到可拆砖墙", _brick.x >= 0, str(_brick))
	if _brick.x >= 0:
		var res: String = game.arena.hit_cell(_brick, 999999, false)
		_check("房主侧砖墙已碎", game.arena.cell(_brick.x, _brick.y) == Arena.EMPTY,
				"%s / cell=%d" % [res, game.arena.cell(_brick.x, _brick.y)])

	# 留出时间让客户端先认到陪练车、再看到它消失，然后杀掉它。
	await _wait(3.0)
	var target = Net.get_tank(_enemy_id)
	_check("房主侧已注册敌车", target != null)
	if target != null:
		target.take_hit(int(target.max_hp * 3) + 500,
				target.global_position + Vector3(0, 2, 0), Shell.Kind.AP)
	await _wait_until(func(): return Net.get_tank(_enemy_id) == null, 5.0)
	_check("房主侧敌车已移除", Net.get_tank(_enemy_id) == null)

	# 等客户端主动断开，验证房主的断线清理。
	await _wait_until(func(): return Net.players.size() <= 1, JOIN_TIMEOUT)
	_check("客户端退出后名册只剩房主", Net.players.size() == 1, str(Net.players.size()))
	_check("退出玩家的车已清掉", game.player_for_pid(_remote_pid) == null)
	_report()


# ---------------- 客户端 ----------------

func _run_client() -> void:
	await _wait(1.0)
	var ip := "127.0.0.1"
	if not Net.join_room(ip, port):
		print("PROBE CLIENT FAILED: 无法连接 %s:%d" % [ip, port])
		get_tree().quit(1)
		return
	if not await _wait_until(func(): return Net.match_active, JOIN_TIMEOUT):
		print("PROBE CLIENT FAILED: %d 秒内未收到开局" % int(JOIN_TIMEOUT))
		get_tree().quit(1)
		return
	print("PROBE CLIENT: 对局已开始")

	# 双方的车都该落场了。
	await _wait(1.2)
	_check("客户端侧有两辆真人车", game.players.size() == 2, str(game.players.size()))
	_check("本地玩家已拿到镜头", game.player != null and game.rig.target == game.player,
			"pid=%d 本地=%d" % [
				int(game.player.peer_id) if game.player != null else 0, Net.local_pid()])
	# 砖墙坐标只取一次：稍后房主会拆掉它，再取一次就会拿到下一格。
	_brick = _first_brick(game.arena)
	_check("客户端找到同一格砖墙", _brick.x >= 0, str(_brick))
	var host_tank: Tank = null
	for t in game.players:
		if is_instance_valid(t) and int(t.peer_id) == 1:
			host_tank = t
	_check("客户端存在房主的车", host_tank != null)

	# 倒计时期间油门是锁死的，先等房主把状态推到 play 再踩油门。
	var play_ok: bool = await _wait_until(func(): return game.state == "play", 10.0)
	_check("客户端跟随房主进入 play", play_ok, game.state)

	if game.player != null and is_instance_valid(game.player):
		# 开火走完整链路：客户端提交意图 → 房主生成炮弹并广播 → 客户端生成表现炮弹。
		var fired: bool = game.player.fire()
		_check("客户端开火成功", fired)
		var echo_ok: bool = await _wait_until(func(): return Net._net_visual_shots > 0, 8.0)
		_check("客户端收到房主的开火广播", echo_ok, str(Net._net_visual_shots))

		_remote_spawn = game.player.global_position
		# 车从静止起步，加速度与物理解交都会让前几帧位移很小；这里按"位移超过
		# 阈值"轮询，而不是睡固定秒数后一次性量，避免慢机器上误报。
		Input.action_press("move_forward")
		var t0 := Time.get_ticks_msec()
		var moved_ok: bool = await _wait_until(func():
			return game.player != null and is_instance_valid(game.player) \
					and game.player.global_position.distance_to(_remote_spawn) > 0.5,
				8.0)
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		Input.action_release("move_forward")
		var local_moved: float = 0.0
		if game.player != null and is_instance_valid(game.player):
			local_moved = game.player.global_position.distance_to(_remote_spawn)
		_check("客户端本地车已移动", moved_ok,
				"%.2f m / %.2fs / 状态 %s / pid %d vs 本地 %d" % [
					local_moved, secs, game.state,
					int(game.player.peer_id) if game.player != null else 0,
					Net.local_pid()])

	# 房主生成的陪练敌车应已复制过来。
	await _wait_until(func(): return game.enemies.size() >= 1, EVENT_TIMEOUT)
	_check("客户端已收到敌车生成", game.enemies.size() >= 1, str(game.enemies.size()))
	var enemy_ids: Array = []
	for e in game.enemies:
		if is_instance_valid(e):
			enemy_ids.append(int(e.net_id))

	# 等房主拆墙事件到达。
	if _brick.x >= 0:
		var got_ok: bool = await _wait_until(func():
			return game.arena.cell(_brick.x, _brick.y) == Arena.EMPTY, EVENT_TIMEOUT)
		var got: int = game.arena.cell(_brick.x, _brick.y)
		_check("客户端收到拆墙事件", got_ok, "cell=%d" % got)

	# 房主随后击杀陪练车：记录过的任一 net_id 消失即说明死亡事件到达。
	var death_ok := false
	if not enemy_ids.is_empty():
		death_ok = await _wait_until(func(): return _any_id_gone(enemy_ids), EVENT_TIMEOUT)
	_check("客户端收到敌车死亡", death_ok, str(enemy_ids.size()) + " 辆已记录")

	# 主动断开，验证房主的断线清理。
	await _wait(0.5)
	print("PROBE CLIENT: 断线退出")
	Net.leave()
	_report()


# ---------------- 工具 ----------------

## 同一张地图在两端生成，砖墙位置完全一致；按固定顺序取第一格即可，
## 不需要把坐标从房主发给客户端。
func _first_brick(arena: Arena) -> Vector2i:
	for y in Arena.GRID_H:
		for x in Arena.GRID_W:
			if arena.cell(x, y) == Arena.BRICK:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _any_id_gone(ids: Array) -> bool:
	for id in ids:
		if Net.get_tank(int(id)) == null:
			return true
	return false
