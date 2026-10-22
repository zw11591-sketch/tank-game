extends Node
## 验收：暂停真的停住战场，并且"暂停-继续"不会改写状态、不会重复发奖。
##
## 原来有两处会直接破坏流程：
##   1. `_set_pause(false)` 无条件把状态写回 "play"：在 "clear" 下暂停再继续，
##      _update_play 会再次判定敌人清零，把过关奖励反复加一遍；
##      在 "ready" 下暂停再继续则会跳过整段倒计时。
##   2. 暂停没有任何冻结：炮弹继续飞、冷却与连击窗口继续走。
##
## 判据：
##   * ready 期间暂停 -> 倒计时冻结；继续后仍是 ready；
##   * play 期间开一发，暂停 -> 炮弹位置与技能冷却完全不动；
##   * clear 期间暂停 -> 继续后仍是 clear，且得分不再增加；
##   * 进入下一关后，过关奖励只结算过一次；
##   * 雷达上"量程外贴边箭头"与量程内坐标使用同一套换算（不再镜像）。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会二次编码。

var _main: Node = null
var _f := 0
var _step := 0
var _marks: Dictionary = {}

const WAIT_READY_END := 500
const PAUSE_FRAMES := 24


func _ready() -> void:
	# 探针自己必须常驻：暂停是 SceneTree.paused，默认 PAUSABLE 的节点
	# 会在按下暂停的那一刻停止处理，探针就跟着一起卡死。
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	_main = get_node_or_null("Main")
	if _main == null:
		print("PAUSE FAIL noMain")
		get_tree().quit(1)
		return
	_check_radar()
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()


## 雷达贴边箭头方向：与 _map() 必须一致。
## 正前方的目标在雷达上永远朝上（屏幕 -Y），无论车头朝向如何。
func _check_radar() -> void:
	var ok := true
	var cases := [
		[0.0, Vector3(0, 0, -100)],
		[PI * 0.5, Vector3(-100, 0, 0)],
		[PI, Vector3(0, 0, 100)],
		[-PI * 0.5, Vector3(100, 0, 0)],
	]
	for c in cases:
		var yaw: float = c[0]
		var p: Vector3 = c[1]
		var e: Vector2 = HUD.Radar.edge_dir(p, Vector3.ZERO, yaw)
		if e.distance_to(Vector2(0, -1)) > 0.01:
			ok = false
			print("PAUSE radar yaw=%.2f got=%s" % [yaw, str(e)])
	print("PAUSE radarEdge=%s" % str(ok))
	_marks["radar"] = ok


func _physics_process(_delta: float) -> void:
	if _main == null:
		return
	_f += 1

	match _step:
		0:
			# 倒计时期间暂停：计时器必须冻住，继续后仍回到 ready
			if _main.state == "ready" and _f > 2:
				var before: float = _main.state_timer
				_main._set_pause(true)
				_marks["ready_before"] = before
				_marks["ready_frames"] = _f
				_f = 0
				_step = 1
		1:
			if _f >= PAUSE_FRAMES:
				var frozen: bool = absf(_main.state_timer - float(_marks["ready_before"])) < 0.0001
				var paused: bool = get_tree().paused and _main.state == "pause"
				print("PAUSE readyFrozen=%s paused=%s" % [str(frozen), str(paused)])
				_marks["ready"] = frozen and paused
				_main._set_pause(false)
				_marks["ready_resumed"] = _main.state
				print("PAUSE readyResume=%s" % _main.state)
				_f = 0
				_step = 2
		2:
			if _main.state == "play":
				_f = 0
				_step = 3
			elif _f > WAIT_READY_END:
				print("PAUSE FAIL neverPlay state=%s" % _main.state)
				get_tree().quit(1)
		3:
			# 开一发，让场景里真的有一枚在飞的炮弹
			var p = _main.player
			if p != null and is_instance_valid(p):
				p.reload_t = 0.0
				p.fire()
			_f = 0
			_step = 4
		4:
			if _f >= 2:
				var shell := _find_shell()
				var p = _main.player
				_marks["shell"] = shell
				_marks["shell_pos"] = shell.global_position if shell != null else Vector3.ZERO
				_marks["boost"] = p.boost_cd if p != null else 0.0
				_marks["combo"] = _main._combo_t
				_main._set_pause(true)
				_f = 0
				_step = 5
		5:
			if _f >= PAUSE_FRAMES:
				var shell = _marks["shell"]
				var moved := 999.0
				if shell != null and is_instance_valid(shell):
					moved = shell.global_position.distance_to(_marks["shell_pos"])
				var p = _main.player
				var cd_frozen: bool = p != null and is_instance_valid(p) \
						and absf(p.boost_cd - float(_marks["boost"])) < 0.0001
				var combo_frozen: bool = absf(_main._combo_t - float(_marks["combo"])) < 0.0001
				var shell_frozen: bool = shell == null or not is_instance_valid(shell) or moved < 0.0001
				print("PAUSE frozen shellMoved=%.4f cooldownFrozen=%s comboFrozen=%s" % [
					moved, str(cd_frozen), str(combo_frozen)])
				_marks["frozen"] = shell_frozen and cd_frozen and combo_frozen
				_main._set_pause(false)
				_f = 0
				_step = 6
		6:
			# 清空敌人，进入 clear
			_main.spawn_queue.clear()
			for e in _main.enemies:
				if is_instance_valid(e):
					e.queue_free()
			_main.enemies.clear()
			_f = 0
			_step = 7
		7:
			if _main.state == "clear":
				_marks["score_clear"] = _main.score
				_marks["stage_clear"] = _main.stage
				print("PAUSE clearScore=%d stage=%d" % [_main.score, _main.stage])
				_main._set_pause(true)
				_f = 0
				_step = 8
			elif _f > 60:
				print("PAUSE FAIL neverClear state=%s" % _main.state)
				get_tree().quit(1)
		8:
			if _f >= PAUSE_FRAMES:
				_main._set_pause(false)
				_f = 0
				_step = 10
		10:
			# 继续之后要等几帧：_update_play 会在这个窗口里再跑一次
			# "敌人是否清零"的判定，正是原来重复发奖的地方。
			if _f >= 8:
				var st: String = _main.state
				var same_score: bool = _main.score == int(_marks["score_clear"])
				print("PAUSE clearPauseResume state=%s scoreSame=%s" % [st, str(same_score)])
				_marks["clear_resume"] = st == "clear" and same_score
				_f = 0
				_step = 9
		9:
			# 等状态计时走完、进入下一关，确认奖励没有再加一次
			if _main.stage != int(_marks["stage_clear"]):
				var once: bool = _main.score == int(_marks["score_clear"])
				print("PAUSE rewardOnce=%s score=%d" % [str(once), _main.score])
				_marks["reward"] = once
				_verdict()
			elif _f > 900:
				print("PAUSE FAIL stageNeverAdvanced state=%s" % _main.state)
				get_tree().quit(1)


func _find_shell() -> Node:
	for c in _main.get_children():
		if c is Shell:
			return c
	return null


func _verdict() -> void:
	var ok: bool = bool(_marks.get("radar", false)) \
			and bool(_marks.get("ready", false)) \
			and _marks.get("ready_resumed", "") == "ready" \
			and bool(_marks.get("frozen", false)) \
			and bool(_marks.get("clear_resume", false)) \
			and bool(_marks.get("reward", false))
	print("PAUSE VERDICT pauseOk=%s" % str(ok))
	get_tree().quit(0 if ok else 1)
