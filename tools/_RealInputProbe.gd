extends Node
## 临时诊断：走真实输入通道（Input.action_press -> Player.tick -> drive）量转向，
## 确认与直接调用 drive() 的测量一致。打印标签全用 ASCII。

var _main: Node
var _a: Arena
var _p: Player


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.spawn_queue.clear()
	_main.max_active = 0
	for e in _main.enemies.duplicate():
		e.queue_free()
		_main.enemies.erase(e)
	_p = _main.player
	_p.shield_t = 0.0
	_a = _main.arena
	await _frames(2)

	# 空场
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY
	_a._rebuild_all()
	await _frames(2)

	print("PROBE tank=%s drive_relative=%s turn=%.2f fps_cap=%d" % [
		_p.tank_id, str(Settings.drive_relative), _p.turn_speed, Settings.fps_cap])

	await _case("A_only", "turn_left", "move_forward", false)
	await _case("D_only", "turn_right", "move_forward", false)
	await _case("W+A", "turn_left", "move_forward", true)
	await _case("W+D", "turn_right", "move_forward", true)
	get_tree().quit(0)


func _case(tag: String, steer_action: String, drive_action: String, throttle: bool) -> void:
	_p.global_position = Arena.cell_center(12, 12)
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = _p.global_position
	_main.rig.reset_to(_p)
	await _frames(2)
	var yaw0: float = _p.rotation.y
	Input.action_press(steer_action)
	if throttle:
		Input.action_press(drive_action)
	var marks := {}
	for i in 120:
		await get_tree().physics_frame
		var turned := rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y)))
		if i == 29:
			marks["05"] = turned
		elif i == 59:
			marks["10"] = turned
		elif i == 119:
			marks["20"] = turned
	Input.action_release(steer_action)
	Input.action_release(drive_action)
	print("PROBE real_%s deg@0.25=%.1f 0.5=%.1f 1.0=%.1f speed=%.1f pos=(%.2f,%.2f)" % [
		tag, marks.get("05", 0.0), marks.get("10", 0.0), marks.get("20", 0.0),
		_p._speed, _p.global_position.x, _p.global_position.z])


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
