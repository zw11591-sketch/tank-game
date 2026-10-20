extends Node
## 临时诊断：真实输入下的转向响应（W+A / A / 履带模式）。

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.player.shield_t = 0.0

	var a: Arena = _main.arena
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	a._rebuild_all()
	await get_tree().physics_frame

	var p: Player = _main.player
	Settings.drive_relative = true
	await _run(p, Vector2(1, 1), "rel W+A")
	await _run(p, Vector2(0, 1), "rel A")
	await _run(p, Vector2(1, -1), "rel W+D")
	Settings.drive_relative = false
	await _run(p, Vector2(1, 1), "legacy W+D")
	await _run(p, Vector2(0, 1), "legacy D")
	Settings.drive_relative = true
	get_tree().quit(0)


func _run(p: Player, keys: Vector2, tag: String) -> void:
	var fwd := keys.x
	var right := keys.y
	var home := Arena.cell_center(12, 12)
	p.global_position = home
	p.rotation.y = 0.0
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = home
	_main.rig.yaw = 0.0
	_main.rig.aim_yaw = 0.0
	_main.rig.global_position = home
	_set_keys(0.0, 0.0)
	await _ticks(4)

	_set_keys(fwd, right)
	var y0: float = p.rotation.y
	var marks: Array = []
	var steps := Engine.physics_ticks_per_second
	for i in steps:
		await get_tree().physics_frame
		if (i + 1) % (Engine.physics_ticks_per_second / 10) == 0:
			marks.append("%.0f" % rad_to_deg(absf(angle_difference(y0, p.rotation.y))))
	_set_keys(0.0, 0.0)
	print("PROBE %-11s yaw@0.1s=%s spd=%.1f turnRate=%.0fdeg/s" % [
		tag, ",".join(marks), p._speed, rad_to_deg(absf(angle_difference(y0, p.rotation.y)))])
	await _ticks(4)


func _set_keys(fwd: float, right: float) -> void:
	for n in ["move_forward", "move_back", "turn_left", "turn_right"]:
		Input.action_release(n)
	if fwd > 0.5:
		Input.action_press("move_forward")
	elif fwd < -0.5:
		Input.action_press("move_back")
	if right < -0.5:
		Input.action_press("turn_left")
	elif right > 0.5:
		Input.action_press("turn_right")


func _ticks(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
