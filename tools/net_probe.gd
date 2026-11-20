extends Node
## 联机自动验收探针：在同一台机器上开两个 headless 进程验证局域网合作模式。
##
##   godot --headless --path . res://tools/NetProbe.tscn -- --role=host --port=45988
##   godot --headless --path . res://tools/NetProbe.tscn -- --role=client --port=45988
##
## 两个进程通过回环地址连接，检查：握手与名册、双车生成、客户端移动是否被
## 房主收到、开火是否生成炮弹、拆墙事件、敌车生成/死亡广播、客户端退出后
## 房主是否清掉他的车，以及 Roguelite 的单局状态（Run 行、三选一、选卡、
## 补给站、坚守撤退）在两端是否一致。每个断言都打印 PASS/FAIL，最后以退出码 0/1 结束。
##
## 两台机器冷启动时都要加载模型与纹理，客户端可能十几秒才进主循环，所以
## 所有等待都做成"轮询到条件成立"，而不是按固定秒数对齐；固定时间轴在
## 慢机器上会稳定误报。Run 阶段的每一步都有明确的帧数上限，卡住只会 FAIL，不会挂死。

const PORT := 45988
## 等待对端/事件的上限。正常回环一两秒就满足，留足余量只为冷启动。
const JOIN_TIMEOUT := 30.0
const EVENT_TIMEOUT := 15.0
## 单条"轮询到条件成立"的上限。每次轮询睡 0.05 秒，所以 300 次约等于 15 秒。
## 既给慢机器留了余量，又保证状态机卡死时探针会以 FAIL 收场而不是永远挂着。
const POLL_FRAMES := 300
## Run 阶段的握手点。房主发"现在检查第 N 步 + 期望值"，客户端做完回一个 ACK。
const PH_ARENA := 5
const PH_RUN := 10
const PH_OFFER := 20
const PH_CARD := 30
const PH_STATION := 40
const PH_ENEMY := 45
const PH_WITHDRAW := 50

var game: Node
var role := "host"
var port := PORT
var fails: Array = []
var checks := 0
var _remote_pid := 0
var _remote_spawn := Vector3.INF
var _enemy_id := 0
var _brick := Vector2i(-1, -1)

# ---------------- Run 阶段的节拍器 ----------------
#
# 正式流程里没有"房主做完了第 N 步、客户端也验完了"这种信号，而两端的断言
# 必须针对同一个动作。这里用两条只属于探针的可靠 RPC 当节拍器（不碰 scripts/）：
# 房主先发阶段与期望值，客户端验完回执；房主再放行下一步。这样任何一头的日志
# 都能直接对应到另一头，也避免两端各跑各的、靠 sleep 对齐。

## 房主 → 客户端的阶段号与期望值。客户端只读。
var _host_phase := 0
var _host_phase_data: Dictionary = {}
## 客户端 → 房主的回执号与读数。房主用它们做交叉校验。
var _ack_phase := 0
var _ack_data: Dictionary = {}
## 房主本局下发的一次性校验码：客户端回执里必须原样带回，
## 否则说明这条回执不是针对这一次 Run 检查的（例如上一次对局残留）。
var _run_go_probe := ""


@rpc("authority", "call_remote", "reliable")
func probe_host_phase(n: int, data: Dictionary) -> void:
	if role == "host":
		return
	# 先写数据再写阶段号：客户端看到阶段号时，期望值一定已经就位。
	_host_phase_data = data
	_host_phase = n


@rpc("any_peer", "call_remote", "reliable")
func probe_client_ack(n: int, data: Dictionary) -> void:
	if role != "host":
		return
	_ack_data = data
	_ack_phase = n


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--role="):
			role = a.trim_prefix("--role=")
		elif a.begins_with("--port="):
			port = int(a.trim_prefix("--port="))
	Settings.net_port = port
	Settings.player_name = "探针-" + role
	_run_go_probe = "%d-%d" % [Time.get_ticks_usec(), randi()]

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


## 按帧数设上限的轮询：每次睡 0.05 秒，最多 frames 次。
## 用于 Run 阶段的握手，保证任何一步卡住都只会在有限时间内判 FAIL。
func _wait_frames(cond: Callable, frames := POLL_FRAMES) -> bool:
	for i in frames:
		if bool(cond.call()):
			return true
		await _wait(0.05)
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
	# 选精英挑战再开局：Run.mutators 因此一定非空，客户端那几个字段的比对才有内容。
	# 挑战由房主在车库选好再进大厅，这里模拟的正是那条路径。
	Net.set_challenge(Mutators.ELITE)
	Net.start_match()
	await _wait(0.5)
	_check("双人开局进入 ready/play", game.state == "ready" or game.state == "play", game.state)
	_check("房主侧有两辆真人车", game.players.size() == 2, str(game.players.size()))
	var remote = game.player_for_pid(_remote_pid)
	_check("房主侧存在客户端车辆", remote != null)
	if remote != null:
		_remote_spawn = remote.global_position

	# 常规战斗检查跑在"干净场地"上：把本关自带敌人整批撤走，并锁住"肃清"分流。
	# 敌方炮弹会在客户端踩油门的那 8 秒里把车打成筛子，那种失败与联机无关。
	game._stage_cleared = true
	game.state = "play"
	game.state_timer = 0.0
	_clear_field()
	await _wait(0.4)

	# 在远离玩家的角落放一辆陪练车，作为"房主生成 → 客户端复制"的样本。
	_enemy_id = _spawn_probe_enemy(Vector2i(2, 2))
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
	#
	# 先等客户端报上它自己算出的首格砖墙：这张图两端用同一个种子生成，
	# 首格必须相同。等它报完再拆，拆墙事件才不会撞上客户端建图的那一刻。
	var arena_ack: bool = await _wait_frames(func(): return _ack_phase >= PH_ARENA)
	var client_brick = _ack_data.get("brick", [])
	_brick = _first_brick(game.arena)
	_check("两端地图首格砖墙一致",
			arena_ack and _list_eq(client_brick, [_brick.x, _brick.y]),
			"客户端 %s vs 房主 %s / 客户端阶段 %d" % [
				str(client_brick), str([_brick.x, _brick.y]),
				int(_ack_data.get("stage", -1))])
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

	# Roguelite：单局状态在两端是否一致。
	await _host_run_checks()

	# 等客户端主动断开，验证房主的断线清理。
	await _wait_until(func(): return Net.players.size() <= 1, JOIN_TIMEOUT)
	_check("客户端退出后名册只剩房主", Net.players.size() == 1, str(Net.players.size()))
	_check("退出玩家的车已清掉", game.player_for_pid(_remote_pid) == null)
	_report()


# ---------------- 房主：Roguelite 单局检查 ----------------

func _host_run_checks() -> void:
	# ---- 1. Run 行（关卡 / 难度 / 挑战 / 修正）随关卡事件与快照到达客户端 ----
	_check("房主侧 Run 已激活", Run.active and Run.stage == game.stage,
			"active=%s stage=%d game.stage=%d" % [str(Run.active), Run.stage, game.stage])
	_check("本局修正非空（精英挑战）", Run.challenge == Mutators.ELITE \
			and not Run.mutators.is_empty(), str(Run.mutators))
	var expect := {
		"probe": _run_go_probe,
		"active": Run.active,
		"stage": Run.stage,
		"diff": Run.diff,
		"challenge": Run.challenge,
		"mutators": Run.mutators.duplicate(),
	}
	probe_host_phase.rpc(PH_RUN, {"expect": expect})
	var ok: bool = await _wait_frames(func(): return _ack_phase >= PH_RUN)
	var read: Dictionary = _ack_data
	# 回执里必须带回本次下发的校验码：否则可能是一条残留的旧回执，
	# 后面的字段比对就变成了自说自话。
	_check("客户端确认 Run 行已同步",
			ok and String(read.get("probe", "")) == _run_go_probe,
			"回执=%d / 校验码=%s" % [_ack_phase, String(read.get("probe", ""))])
	_check("客户端 Run 关卡/难度/挑战与房主一致",
			int(read.get("stage", -1)) == Run.stage \
			and int(read.get("diff", -1)) == Run.diff \
			and int(read.get("challenge", -1)) == Run.challenge,
			"客户端 %d/%d/%d vs 房主 %d/%d/%d" % [
				int(read.get("stage", -1)), int(read.get("diff", -1)),
				int(read.get("challenge", -1)), Run.stage, Run.diff, Run.challenge])
	_check("客户端 Run 修正列表与房主一致",
			_list_eq(read.get("mutators", []), Run.mutators),
			"%s vs %s" % [str(read.get("mutators", [])), str(Run.mutators)])

	# ---- 2. 三选一：直接走生产入口 _open_reward()（抽卡 + state=reward + 广播） ----
	game._open_reward()
	var offer: Array = Run.offer.duplicate()
	_check("房主抽到三张卡并进入 reward",
			offer.size() == 3 and game.state == "reward",
			"state=%s offer=%s" % [game.state, str(offer)])
	probe_host_phase.rpc(PH_OFFER, {
		"offer": offer, "stage": Run.stage,
		"credits": Run.credits, "cards": Run.cards.size(),
	})
	ok = await _wait_frames(func(): return _ack_phase >= PH_OFFER)
	read = _ack_data
	_check("客户端 offer 与房主完全一致", ok and _list_eq(read.get("offer", []), offer),
			"%s vs %s" % [str(read.get("offer", [])), str(offer)])
	_check("客户端卡片界面为只读", bool(read.get("readonly", false)),
			String(read.get("ui", "")))

	# ---- 3. 选卡：房主替所有人结算，两端修正必须同步 ----
	var pick := String(offer[0])
	var ver_before := Run.mods_version
	game._on_card_picked(pick)
	_check("房主选卡写入本局", Run.cards.has(pick) and Run.mods_version > ver_before,
			"%s / cards=%d / mods v%d→%d" % [
				pick, Run.cards.size(), ver_before, Run.mods_version])
	var host_mod_damage := float(Run.mods.get("damage", 1.0))
	var host_pdmg := -1
	if game.player != null and is_instance_valid(game.player):
		host_pdmg = int(game.player.damage)
	probe_host_phase.rpc(PH_CARD, {
		"card": pick, "cards": Run.cards.duplicate(),
		"mods": Run.mods.duplicate(), "damage": host_mod_damage,
		"player_damage": host_pdmg,
	})
	ok = await _wait_frames(func(): return _ack_phase >= PH_CARD)
	read = _ack_data
	_check("客户端已持有房主选的卡",
			ok and _list_eq(read.get("cards", []), Run.cards),
			"%s vs %s" % [str(read.get("cards", [])), str(Run.cards)])
	_check("两端伤害修正一致（1e-6）",
			absf(float(read.get("damage", -1.0)) - host_mod_damage) <= 1e-6,
			"客户端 %.9f vs 房主 %.9f" % [
				float(read.get("damage", -1.0)), host_mod_damage])
	# 单看 damage 太弱：抽到的若是装甲/装填类卡牌，这个值根本不会变。
	# 把整张修正表都比对一遍，任何一项没同步都会在这里露出来。
	_check("两端全部修正一致（1e-6）", _mods_eq(read.get("mods", {}), Run.mods),
			"%s vs %s" % [str(read.get("mods", {})), str(Run.mods)])

	# ---- 4. 补给站：买"战术档案"，客户端要跟着扣款并加卡 ----
	# 战功直接拉高：这里验的是"扣款与加卡是否同步"，不是攒钱过程。
	Run.credits = maxi(Run.credits, 500)
	var credits_before := Run.credits
	var cards_before := Run.cards.size()
	var station_card: int = game.STATION_CARD
	var station_cost: int = int(game.STATION_ITEMS[station_card]["cost"])
	game._open_station()
	_check("房主进入补给站", game.state == "station" and game.run_ui.mode == "station",
			"%s / %s" % [game.state, game.run_ui.mode])
	game._on_station_buy(station_card)
	var bought := String(Run.cards[Run.cards.size() - 1]) if Run.cards.size() > cards_before else ""
	_check("房主购买战术档案成功",
			Run.cards.size() == cards_before + 1 \
			and Run.credits == credits_before - station_cost \
			and not bought.is_empty(),
			"cards %d→%d / 战功 %d→%d（−%d）/ 得到 %s" % [
				cards_before, Run.cards.size(), credits_before, Run.credits,
				station_cost, bought])
	probe_host_phase.rpc(PH_STATION, {
		"credits": Run.credits, "cards": Run.cards.size(), "card": bought,
	})
	ok = await _wait_frames(func(): return _ack_phase >= PH_STATION)
	read = _ack_data
	_check("客户端战功与卡牌数与房主一致",
			ok and int(read.get("credits", -1)) == Run.credits \
			and int(read.get("cards", -1)) == Run.cards.size(),
			"客户端 %d 战功 / %d 张 vs 房主 %d 战功 / %d 张" % [
				int(read.get("credits", -1)), int(read.get("cards", -1)),
				Run.credits, Run.cards.size()])

	# ---- 5. 坚守完成：敌人集体撤退，客户端不应留下任何敌车 ----
	# 先把关卡切到第 2 关（坚守），并放两辆陪练车，保证"撤退"有东西可撤。
	game.stage = 2
	Run.stage = 2
	game._stage_cleared = false
	game.hold_left = 12.0
	var hold_ids: Array = [
		_spawn_probe_enemy(Vector2i(2, 3)),
		_spawn_probe_enemy(Vector2i(3, 2)),
	]
	probe_host_phase.rpc(PH_ENEMY, {"ids": hold_ids})
	ok = await _wait_frames(func(): return _ack_phase >= PH_ENEMY)
	read = _ack_data
	var client_enemies := int(read.get("enemies", 0))
	_check("客户端场上有敌车可撤", ok and client_enemies > 0, str(client_enemies))

	probe_host_phase.rpc(PH_WITHDRAW, {})
	# 给客户端一点时间进入轮询，再让房主真正清场；顺序反过来的话客户端
	# 可能在事件到达前就查询，虽然仍会轮询等待，但日志会难读。
	await _wait(0.2)
	game._hold_complete()
	_check("房主侧敌人已清空", game.enemies.is_empty(), str(game.enemies.size()))
	ok = await _wait_frames(func(): return _ack_phase >= PH_WITHDRAW)
	read = _ack_data
	_check("客户端敌人列表已清空（withdraw 事件）", ok and bool(read.get("empty", false)),
			"回执=%d / 剩余=%d" % [_ack_phase, int(read.get("remaining", -1))])


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

	# 报上本机地图的首格砖墙，房主确认两端一致后才拆。顺带把"我已经建好图、
	# 车也落场了"当成一个握手点，拆墙事件因此不会撞上客户端还在建图的那几帧。
	probe_client_ack.rpc_id(1, PH_ARENA, {
		"brick": [_brick.x, _brick.y], "stage": game.stage,
		"seed": game._stage_seed, "arena": game.arena.get_instance_id(),
	})

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
		#
		# 一直踩到 3 米（或 6 秒）才松油门：房主那份副本要跨过 1 米的判定阈值，
		# 而远端车是按快照插值追的。踩到 0.5 米就松，插值常常停在 0.9 米左右，
		# "房主收到客户端位移"于是时好时坏——那不是联机问题，是探针踩得太短。
		Input.action_press("move_forward")
		var t0 := Time.get_ticks_msec()
		var moved_ok: bool = await _wait_until(func():
			return game.player != null and is_instance_valid(game.player) \
					and game.player.global_position.distance_to(_remote_spawn) > 3.0,
				6.0)
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		Input.action_release("move_forward")
		var local_moved: float = 0.0
		if game.player != null and is_instance_valid(game.player):
			local_moved = game.player.global_position.distance_to(_remote_spawn)
		_check("客户端本地车已移动", moved_ok,
				"%.2f m / %.2fs / 状态 %s / 速度 %.1f / pid %d vs 本地 %d" % [
					local_moved, secs, game.state,
					game.player.move_speed if game.player != null else -1.0,
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

	# Roguelite：单局状态在两端是否一致。
	await _client_run_checks()

	# 主动断开，验证房主的断线清理。
	await _wait(0.5)
	print("PROBE CLIENT: 断线退出")
	Net.leave()
	_report()


# ---------------- 客户端：Roguelite 单局检查 ----------------

func _client_run_checks() -> void:
	# ---- 1. Run 行：房主随关卡事件 / 快照下发的字段必须逐项一致 ----
	if not await _wait_frames(func(): return _host_phase >= PH_RUN):
		_check("收到房主的 Run 检查阶段", false, "阶段=%d" % _host_phase)
		return
	var exp: Dictionary = _host_phase_data.get("expect", {})
	_check("客户端 Run 已激活", Run.active == bool(exp.get("active", false)),
			"active=%s" % str(Run.active))
	_check("客户端 Run 关卡与房主一致", Run.stage == int(exp.get("stage", -1)),
			"%d vs %d" % [Run.stage, int(exp.get("stage", -1))])
	_check("客户端 Run 难度与房主一致", Run.diff == int(exp.get("diff", -1)),
			"%d vs %d" % [Run.diff, int(exp.get("diff", -1))])
	_check("客户端 Run 挑战与房主一致", Run.challenge == int(exp.get("challenge", -1)),
			"%d vs %d" % [Run.challenge, int(exp.get("challenge", -1))])
	_check("客户端 Run 修正列表与房主一致",
			_list_eq(Run.mutators, exp.get("mutators", [])),
			"%s vs %s" % [str(Run.mutators), str(exp.get("mutators", []))])
	probe_client_ack.rpc_id(1, PH_RUN, {
		"probe": String(exp.get("probe", "")),
		"active": Run.active, "stage": Run.stage, "diff": Run.diff,
		"challenge": Run.challenge, "mutators": Run.mutators.duplicate(),
	})

	# ---- 2. 三选一：客户端拿到同一组卡，且界面只读 ----
	if not await _wait_frames(func(): return _host_phase >= PH_OFFER):
		_check("收到房主的三选一阶段", false, "阶段=%d" % _host_phase)
		return
	var host_offer: Array = _host_phase_data.get("offer", [])
	# 可靠 RPC 与快照都会带 offer，这里给它们几帧时间落定再比对。
	var offer_ok: bool = await _wait_frames(func():
		return _list_eq(Run.offer, host_offer) and game.state == "reward", 60)
	_check("客户端收到同一组 offer（逐张相等）", offer_ok,
			"%s vs %s" % [str(Run.offer), str(host_offer)])
	_check("客户端处于 reward 且卡片界面只读",
			game.state == "reward" and game.run_ui.mode == "cards" \
			and not game.run_ui.interactive,
			"state=%s mode=%s interactive=%s" % [
				game.state, game.run_ui.mode, str(game.run_ui.interactive)])

	# 只读校验：客户端把三个入口都点一遍，Run 与状态机都不许动。
	# 规格（05_ui_and_net 第 2.3 节）：卡池与扣款只在房主那侧结算。
	var cards_before: Array = Run.cards.duplicate()
	var credits_before := Run.credits
	var offer_before: Array = Run.offer.duplicate()
	game.run_ui.confirm()
	game.run_ui.reroll()
	game.run_ui.back()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_check("客户端卡片界面只读：选卡无效", _list_eq(Run.cards, cards_before),
			"%d 张" % Run.cards.size())
	_check("客户端卡片界面只读：重掷不扣战功", Run.credits == credits_before,
			"%d vs %d" % [Run.credits, credits_before])
	_check("客户端卡片界面只读：Esc 无法离开",
			game.state == "reward" and _list_eq(Run.offer, offer_before),
			"state=%s" % game.state)
	probe_client_ack.rpc_id(1, PH_OFFER, {
		"offer": Run.offer.duplicate(),
		"readonly": game.state == "reward" and not game.run_ui.interactive,
		"ui": "%s/%s/%s" % [game.state, game.run_ui.mode, str(game.run_ui.interactive)],
	})

	# ---- 3. 选卡：客户端必须持有同一张卡，且修正数值完全同步 ----
	var ver_before := Run.mods_version
	if not await _wait_frames(func(): return _host_phase >= PH_CARD):
		_check("收到房主的选卡阶段", false, "阶段=%d" % _host_phase)
		return
	var card := String(_host_phase_data.get("card", ""))
	var hosts_cards: Array = _host_phase_data.get("cards", [])
	var card_ok: bool = await _wait_frames(func():
		return Run.cards.has(card) and _list_eq(Run.cards, hosts_cards), 120)
	_check("客户端已持有房主选的卡", card_ok,
			"%s / %s vs %s" % [card, str(Run.cards), str(hosts_cards)])
	_check("客户端 mods_version 增加", Run.mods_version > ver_before,
			"%d → %d" % [ver_before, Run.mods_version])
	var mod_damage := float(Run.mods.get("damage", 1.0))
	var host_damage := float(_host_phase_data.get("damage", -1.0))
	_check("两端伤害修正一致（1e-6）", absf(mod_damage - host_damage) <= 1e-6,
			"%.9f vs %.9f" % [mod_damage, host_damage])
	_check("两端全部修正一致（1e-6）",
			_mods_eq(Run.mods, _host_phase_data.get("mods", {})),
			"%s vs %s" % [str(Run.mods), str(_host_phase_data.get("mods", {}))])
	# 卡牌加成必须真的落到车上，不能只改 Run.mods。
	await _wait_frames(func(): return game.player != null and is_instance_valid(game.player), 120)
	var pdmg := -1
	if game.player != null and is_instance_valid(game.player):
		pdmg = int(game.player.damage)
	var host_pdmg := int(_host_phase_data.get("player_damage", -1))
	_check("客户端本地车伤害与房主一致", absi(pdmg - host_pdmg) <= 1,
			"%d vs %d" % [pdmg, host_pdmg])
	probe_client_ack.rpc_id(1, PH_CARD, {
		"cards": Run.cards.duplicate(),
		"mods": Run.mods.duplicate(),
		"damage": mod_damage,
	})

	# ---- 4. 补给站：房主扣款加卡，客户端跟着变 ----
	if not await _wait_frames(func(): return _host_phase >= PH_STATION):
		_check("收到房主的补给站阶段", false, "阶段=%d" % _host_phase)
		return
	var host_credits := int(_host_phase_data.get("credits", -1))
	var host_cards := int(_host_phase_data.get("cards", -1))
	var bought := String(_host_phase_data.get("card", ""))
	var synced: bool = await _wait_frames(func():
		return Run.credits == host_credits and Run.cards.size() == host_cards, 200)
	_check("客户端战功与房主一致", synced and Run.credits == host_credits,
			"%d vs %d" % [Run.credits, host_credits])
	_check("客户端卡牌数与房主一致", Run.cards.size() == host_cards,
			"%d vs %d" % [Run.cards.size(), host_cards])
	_check("客户端收到补给站买到的卡", bought.is_empty() or Run.cards.has(bought),
			"%s / %s" % [bought, str(Run.cards)])
	_check("客户端补给站界面只读",
			game.run_ui.mode == "station" and not game.run_ui.interactive,
			"%s / %s" % [game.run_ui.mode, str(game.run_ui.interactive)])
	probe_client_ack.rpc_id(1, PH_STATION, {
		"credits": Run.credits, "cards": Run.cards.size(),
	})

	# ---- 5. 坚守完成：敌人集体撤退，客户端敌车列表必须清空 ----
	if not await _wait_frames(func(): return _host_phase >= PH_ENEMY):
		_check("收到房主的撤退阶段", false, "阶段=%d" % _host_phase)
		return
	await _wait_frames(func(): return game.enemies.size() > 0, 120)
	_check("撤退前客户端场上有敌车", game.enemies.size() > 0, str(game.enemies.size()))
	probe_client_ack.rpc_id(1, PH_ENEMY, {"enemies": game.enemies.size()})

	if not await _wait_frames(func(): return _host_phase >= PH_WITHDRAW):
		_check("收到房主的清场阶段", false, "阶段=%d" % _host_phase)
		return
	var empty_ok: bool = await _wait_frames(func(): return game.enemies.is_empty(), 200)
	_check("客户端敌人列表已清空（withdraw 事件）", empty_ok,
			"剩余 %d 辆" % game.enemies.size())
	probe_client_ack.rpc_id(1, PH_WITHDRAW, {
		"empty": game.enemies.is_empty(), "remaining": game.enemies.size(),
	})


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


## 字符串数组按内容比较。Run 的 cards / mutators / offer 都是 String 列表，
## 用 str() 比会受格式影响，逐项比更稳。
##
## 有意写成 str(x[i]) == str(y[i])：Godot 4.7 的 String(int) 构造函数在运行时会
## 抛"Nonexistent 'String' constructor"，而这个函数也会被拿来比 [x, y] 坐标对。
func _list_eq(a, b) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	var x: Array = a
	var y: Array = b
	if x.size() != y.size():
		return false
	for i in x.size():
		if str(x[i]) != str(y[i]):
			return false
	return true


## 修正表逐项比较。都是浮点乘法系数，按 1e-6 判等；键集合不同也算不一致
## （卡牌会加/删键，两边键集不同说明有一侧没重算）。
func _mods_eq(a, b) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	var x: Dictionary = a
	var y: Dictionary = b
	if x.size() != y.size():
		return false
	for k in x.keys():
		if not y.has(k):
			return false
		if absf(float(x[k]) - float(y[k])) > 1e-6:
			return false
	return true


## 房主：把本关自带的敌人整批撤走。这不是击杀，所以走 withdraw 事件
## （客户端不留残骸、不计战绩），与坚守计时归零时的处理完全同一条路径。
func _clear_field() -> void:
	for e in game.enemies:
		if is_instance_valid(e):
			e.free_for_net()
	game.enemies.clear()
	game.spawn_queue.clear()
	if Net.is_host():
		Net.broadcast_run_event("withdraw", {})


## 房主：在远离玩家的角落放一辆陪练车，作为"生成 → 复制 → 死亡/撤退"的样本。
## 让这辆车只挨打不还手：探针只关心事件是否到达，不关心 AI 行为。
func _spawn_probe_enemy(at: Vector2i) -> int:
	var id := Net.alloc_enemy_id()
	var e := Enemy.new()
	e.configure(1, game.stage, game.difficulty)
	game._scale_enemy_for_coop(e)
	e.is_remote = false
	e.team = 1
	e.net_id = id
	e.setup(game, game.arena, game.arena.cell_center(at.x, at.y))
	game.add_child(e)
	game.enemies.append(e)
	Net.register_tank(e, id)
	e._react_t = 9999.0
	e._aim_err_t = 9999.0
	Net.broadcast_enemy_spawn({
		"id": id, "type": 1, "pos": e.global_position, "hp": e.hp,
		"stage": game.stage, "diff": game.difficulty,
	})
	return id
