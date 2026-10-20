extends Node
## 临时验收：车身左右转向的"跟手程度"。
##
## 玩家反馈"左右转向不是很灵活"。这个量不能靠看代码判断，只能按帧量：
## 按下 A 之后，车体在 0.25 / 0.5 / 1.0 秒各转了多少度、到位要多久、
## 转向过程中车速掉到多少。三个因素都会让手感变"钝"，但它们修法完全不同：
##   * 转速（turn_speed × authority）—— 给多少
##   * 转向权限随车速插值 —— 掉速会把转向一起拖慢，这是负反馈
##   * 相对驾驶的油门折扣（TURN_THROTTLE_FLOOR）—— 掉速的来源
##
## 四个工况各量一遍：镜头相对 / 传统履带 × 静止 / 巡航，再补两个"贴着单格走廊"的。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --path <proj> res://tools/TurnProbe.tscn

const MEASURE := 240          # 2 s：足够转完 90° 并看清尾部收敛
const SAMPLE_EVERY := 6

var _f := 0
var _started := false
var _drop := 0.0
var _phase := ""
var _t := 0
var _pre := 0
var _key := ""
var _yaw0 := 0.0
var _spd_min := 0.0
var _samples: Array = []
var _case := 0

const CASES := [
	{"name": "rel_rest_A", "rel": true, "corridor": false, "pre": 0},
	{"name": "rel_cruise_A", "rel": true, "corridor": false, "pre": 120},
	{"name": "leg_rest_A", "rel": false, "corridor": false, "pre": 0},
	{"name": "leg_cruise_A", "rel": false, "corridor": false, "pre": 120},
	{"name": "rel_rest_A_wall", "rel": true, "corridor": true, "pre": 0},
	{"name": "leg_rest_A_wall", "rel": false, "corridor": true, "pre": 0},
]


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	var main := get_node("Main")
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _physics_process(_d: float) -> void:
	_f += 1
	var main := get_node("Main")
	if main.player == null:
		return
	if _f == 60 and not _started:
		_started = true
		main.state = "play"
		main.player.shield_t = 0.0
		_begin(CASES[0])
		return
	if not _started:
		return

	_t += 1
	if _phase == "pre":
		if _t >= _pre:
			_release_all()
			_start_measure(main.player)
		return

	var p: Player = main.player
	var dyaw: float = angle_difference(_yaw0, p.rotation.y)
	_spd_min = minf(_spd_min, p.speed())
	if _t % SAMPLE_EVERY == 0:
		_samples.append([float(_t) / 120.0, rad_to_deg(absf(dyaw)), p.speed_kmh(),
				rad_to_deg(p.rotation.y)])
	if _t >= MEASURE:
		_report(CASES[_case]["name"], dyaw)
		_case += 1
		if _case >= CASES.size():
			get_tree().quit(0)
			return
		_begin(CASES[_case])


func _begin(c: Dictionary) -> void:
	var main := get_node("Main")
	Settings.drive_relative = bool(c["rel"])
	_build(bool(c["corridor"]))
	var p: Player = main.player
	var home := Arena.cell_center(12, 12)
	p.global_position = home
	p.rotation.y = 0.0
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p.turn_blocked = false
	main.rig.reset_to(p)
	main.rig.global_position = home
	_release_all()
	_pre = int(c["pre"])
	_t = 0
	_phase = "pre"
	if _pre > 0:
		Input.action_press("move_forward")
	else:
		_start_measure(p)


func _start_measure(p: Player) -> void:
	_phase = "run"
	_t = 0
	_yaw0 = p.rotation.y
	_spd_min = 1.0e9
	_samples = []
	_key = "turn_left"
	Input.action_press(_key)


func _report(tag: String, dyaw: float) -> void:
	var t45 := -1.0
	var t90 := -1.0
	for s in _samples:
		if t45 < 0.0 and s[1] >= 45.0:
			t45 = s[0]
		if t90 < 0.0 and s[1] >= 90.0:
			t90 = s[0]
	var at := {}
	for s in _samples:
		at[snappedf(s[0], 0.05)] = s[1]
	print("PROBE %-18s yaw%+7.1fdeg t45=%s t90=%s @0.25=%5.1f @0.50=%5.1f @1.00=%5.1f spdMin=%4.1fkmh" % [
		tag, rad_to_deg(dyaw),
		("%.2fs" % t45) if t45 >= 0.0 else "  -  ",
		("%.2fs" % t90) if t90 >= 0.0 else "  -  ",
		float(at.get(0.25, 0.0)), float(at.get(0.5, 0.0)), float(at.get(1.0, 0.0)),
		_spd_min])


func _release_all() -> void:
	for n in ["move_forward", "move_back", "turn_left", "turn_right"]:
		Input.action_release(n)


func _build(corridor: bool) -> void:
	var a: Arena = get_node("Main").arena
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	if corridor:
		for y in range(4, 21):
			a.grid[y][11] = Arena.BRICK
			a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
