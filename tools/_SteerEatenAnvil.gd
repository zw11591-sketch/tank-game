extends Node
## 临时诊断：真实关卡里用铁砧（anvil）自动行驶，统计"指令转角 / 实际转角"之比、
## 被挡帧数、以及"给油却在原地"的帧数。
## 不走 Main 的状态机。打印标签全用 ASCII。

const SECONDS := 40.0
const TOGGLE_FRAMES := 48

class Stub extends Node:
	var state := "play"
	var tanks: Array = []
	func all_tanks() -> Array:
		return tanks


var _a: Arena
var _g: Stub
var _p: Player
var _rig: CameraRig
var _acc_cmd := 0.0
var _acc_got := 0.0
var _blocked := 0
var _frames_total := 0
var _stuck := 0
var _steer := 1.0
var _gap := 0


func _ready() -> void:
	await get_tree().process_frame
	_g = Stub.new()
	add_child(_g)
	_a = Arena.new()
	_a.game = _g
	add_child(_a)
	_a.generate(1, 0)
	await _frames(2)

	_p = Player.new()
	_p.tank_id = "anvil"
	_p.setup(_g, _a, _a.player_spawn())
	add_child(_p)
	await _frames(2)
	_rig = CameraRig.new()
	add_child(_rig)
	_p.rig = _rig
	_rig.reset_to(_p)
	_g.tanks = [_p]
	_p.shield_t = 0.0
	print("PROBE spawn=%s hull=(%.2f x %.2f..%.2f) turn=%.2f" % [
		_p.global_position, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b,
		_p.turn_speed])

	for rel in [true, false]:
		Settings.drive_relative = rel
		_p.global_position = _a.player_spawn()
		_p.rotation.y = 0.0
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = _p.global_position
		_rig.reset_to(_p)
		_reset()
		await _run()
		print("PROBE rel=%s cmd=%.1fgot=%.1f ratio=%.2f blocked=%d/%d stuck=%d" % [
			rel, rad_to_deg(_acc_cmd), rad_to_deg(_acc_got),
			_acc_got / maxf(_acc_cmd, 0.001), _blocked, _frames_total, _stuck])
	Input.action_release("move_forward")
	Input.action_release("turn_left")
	Input.action_release("turn_right")
	get_tree().quit(0)


func _reset() -> void:
	_acc_cmd = 0.0
	_acc_got = 0.0
	_blocked = 0
	_frames_total = 0
	_stuck = 0
	_steer = 1.0
	_gap = 0


func _run() -> void:
	var total := int(SECONDS * 120.0)
	Input.action_press("move_forward")
	for i in total:
		if i % TOGGLE_FRAMES == 0:
			_steer = -_steer
			_gap = 14
		var steering := true
		if _gap > 0:
			_gap -= 1
			steering = false
			Input.action_release("turn_left")
			Input.action_release("turn_right")
		elif _steer > 0.0:
			Input.action_press("turn_right")
			Input.action_release("turn_left")
		else:
			Input.action_press("turn_left")
			Input.action_release("turn_right")
		if steering:
			_acc_cmd += _p.turn_speed * (1.0 / 120.0)
		var y0: float = _p.rotation.y
		var p0: Vector3 = _p.global_position
		await get_tree().physics_frame
		_acc_got += absf(angle_difference(y0, _p.rotation.y))
		_frames_total += 1
		if _p.turn_blocked:
			_blocked += 1
		if p0.distance_to(_p.global_position) < 0.001:
			_stuck += 1


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
