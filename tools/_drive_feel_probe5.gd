extends Node
## 临时诊断 5：贴墙行进时的真实手感——向内/向外打舵、丁字口转弯。

var _main: Node
var _a: Arena
var _p: Player
var _dt := 1.0 / 120.0


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	_main._sel_tank = 0
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_p = _main.player
	_p.shield_t = 0.0
	_a = _main.arena
	await _frames(4)

	for gap in [0.10, 0.40]:
		await _wall_run(gap, 1.0, "into")
		await _wall_run(gap, -1.0, "away")
	await _tee()
	get_tree().quit(0)


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY
	_a._rebuild_all()


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


func _wall_run(gap: float, steer: float, tag: String) -> void:
	_clear()
	for y in range(2, 22):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	var c := Arena.cell_center(12, 12)
	var wall_face: float = Arena.cell_center(13, 12).x - Arena.CELL * 0.5
	_p.global_position = Vector3(wall_face - gap - _p._hull_half_w, 0.0, c.z)
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = _p.global_position
	await _frames(2)
	var y0 := _p.rotation.y
	var z0 := _p.global_position.z
	var worst := 0.0
	var blocked := 0
	var marks: Array = []
	for i in 120:
		_p.drive(1.0, steer, _dt)
		worst = maxf(worst, _p._hull_depth(_p.rotation.y))
		if _p.turn_blocked:
			blocked += 1
		if (i + 1) % 12 == 0:
			marks.append("%.1f" % absf(_p._speed))
	print("PROBE wall %-4s gap=%.2f steer=%+.0f yaw=%.0f blocked=%3d/120 deep=%.3f dz=%.2f v@0.1s=[%s]" % [
		tag, gap, steer, rad_to_deg(absf(angle_difference(y0, _p.rotation.y))),
		blocked, worst, absf(_p.global_position.z - z0), ",".join(marks)])
	_clear()


func _tee() -> void:
	# 沿 +Z 的走廊（x=12），在 z 格 12 处右侧开口（x=13 空，x=14.. 空地）
	_clear()
	for y in range(4, 20):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a.grid[12][13] = Arena.EMPTY
	for y in range(4, 20):
		if y != 12:
			_a.grid[y][14] = Arena.BRICK
	_a._rebuild_all()
	var c := Arena.cell_center(12, 8)
	_p.global_position = Vector3(c.x, 0.0, c.z)
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = _p.global_position
	await _frames(2)
	var y0 := _p.rotation.y
	var worst := 0.0
	var marks: Array = []
	for i in 180:
		# 走到丁字口附近开始向左打舵（开口在 +X，即右侧，朝 -Z 行驶时是右手边）
		var z := _p.global_position.z
		var steer := -1.0 if z < c.z + 8.0 else 0.0
		_p.drive(1.0, steer, _dt)
		worst = maxf(worst, _p._hull_depth(_p.rotation.y))
		if (i + 1) % 15 == 0:
			marks.append("%.0f" % rad_to_deg(absf(angle_difference(y0, _p.rotation.y))))
	print("PROBE tee yaw@0.125s=[%s] deep=%.3f endpos=(%.1f,%.1f)" % [
		",".join(marks), worst, _p.global_position.x, _p.global_position.z])
	_clear()
