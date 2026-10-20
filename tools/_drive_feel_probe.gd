extends Node
## 临时诊断：实际驾驶中"转向被卡"与"车体压进墙"的量化。
## 全 ASCII 输出。

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
	_clear()
	await _frames(4)

	print("PROBE hull w=%.2f f=%.2f b=%.2f body_r=%.2f body_len=%.2f turn=%.2f" % [
		_p._hull_half_w, _p._hull_half_f, _p._hull_half_b,
		_p.body_radius, _p.body_length, _p.turn_speed])

	# A. 开阔地满舵 90° 用时（油门 0 / 全油门）
	await _open(Vector2(0, 1), "pivot")
	await _open(Vector2(1, 1), "drive")

	# B. 贴单墙并行，墙在左（+X 方向是右，墙放右侧）
	for gap in [0.05, 0.2, 0.5, 1.0]:
		await _along_wall(gap, 60)

	# C. 单格走廊里扶着方向直行：转向还有多少自由度
	await _corridor_drive()

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


func _reset(pos: Vector3, yaw := 0.0) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos


func _open(keys: Vector2, tag: String) -> void:
	_reset(Arena.cell_center(12, 12), 0.0)
	await _frames(2)
	var t := 0.0
	var y0 := _p.rotation.y
	var got90 := -1.0
	var worst := 0.0
	var blocked := 0
	while t < 3.0:
		_p.drive(keys.x, keys.y, _dt)
		t += _dt
		worst = maxf(worst, _p._hull_depth(_p.rotation.y))
		if _p.turn_blocked:
			blocked += 1
		if got90 < 0.0 and absf(angle_difference(y0, _p.rotation.y)) >= deg_to_rad(90.0):
			got90 = t
	if got90 < 0.0:
		got90 = 99.0
	print("PROBE open %-6s t90=%.3fs rate=%.0fdeg/s blocked=%3d deep=%.3f" % [
		tag, got90, 90.0 / got90, blocked, worst])


func _along_wall(gap: float, frames: int) -> void:
	# 右侧墙：第 13 列（cell x=13），车在 x=12 格内。墙左边界 = cell_center(13,y).x - 2
	_clear()
	for y in range(2, 22):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	var c := Arena.cell_center(12, 12)
	var wall_face: float = Arena.cell_center(13, 12).x - Arena.CELL * 0.5
	var pos := Vector3(wall_face - gap - _p._hull_half_w, 0.0, c.z)
	_reset(pos, 0.0)
	await _frames(2)
	var y0 := _p.rotation.y
	var worst := 0.0
	var blocked := 0
	var minx := pos.x
	var maxx := pos.x
	var spd_sum := 0.0
	for i in frames:
		# 全油门直行，同时始终给左舵（朝远离墙一侧）
		_p.drive(1.0, 1.0, _dt)
		worst = maxf(worst, _p._hull_depth(_p.rotation.y))
		if _p.turn_blocked:
			blocked += 1
		minx = minf(minx, _p.global_position.x)
		maxx = maxf(maxx, _p.global_position.x)
		spd_sum += absf(_p._speed)
	var yaw_deg := rad_to_deg(absf(angle_difference(y0, _p.rotation.y)))
	print("PROBE wallgap=%.2f yaw=%.0fdeg blocked=%3d/%3d deep=%.3f x=[%.2f..%.2f] vavg=%.1f" % [
		gap, yaw_deg, blocked, frames, worst, minx, maxx, spd_sum / frames])
	_clear()


func _corridor_drive() -> void:
	# 单格宽走廊沿 Z：左右各一列墙（x=11 / x=13），车在 x=12，轮子正中
	_clear()
	for y in range(2, 22):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	var c := Arena.cell_center(12, 12)
	_reset(Vector3(c.x, 0.0, c.z), 0.0)
	await _frames(2)
	var y0 := _p.rotation.y
	var worst := 0.0
	var blocked := 0
	var dist := 0.0
	var z0 := _p.global_position.z
	var marks: Array = []
	for i in 120:
		_p.drive(1.0, 0.6, _dt)
		worst = maxf(worst, _p._hull_depth(_p.rotation.y))
		if _p.turn_blocked:
			blocked += 1
		if (i + 1) % 12 == 0:
			marks.append("%.1f" % rad_to_deg(absf(angle_difference(y0, _p.rotation.y))))
	dist = absf(_p.global_position.z - z0)
	print("PROBE corr4 yaw@0.1s=[%s] blocked=%3d/120 deep=%.3f dist=%.2f" % [
		",".join(marks), blocked, worst, dist])
	_clear()
