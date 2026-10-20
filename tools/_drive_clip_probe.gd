extends Node
## 临时诊断：正常驾驶时车体四角压进墙里的深度 + 转向响应。
## 打印全 ASCII。

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	_main._sel_tank = 1   # 游隼：3.4 x 4.4
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.player.shield_t = 0.0

	var a: Arena = _main.arena
	_clear(a)
	a._rebuild_all()
	await _frames(4)
	var p: Player = _main.player
	print("PROBE tank=%s body_r=%.2f body_len=%.2f" % [p.tank_id, p.body_radius, p.body_length])

	# ---- 1. 斜着撞墙：以各种角度全速开向一面墙，量车体角点最深压进多少 ----
	for deg in [20.0, 35.0, 50.0, 70.0, 90.0]:
		await _ram(p, a, deg)

	# ---- 2. 沿走廊斜着开：4m 走廊、初始偏角，看能不能顺、压多深 ----
	for deg in [0.0, 8.0, 15.0, 25.0]:
		await _corridor_drive(p, a, deg)

	# ---- 3. 沿单侧墙平行行驶，再持续给舵（模拟"贴着墙拐弯"） ----
	await _wall_turn(p, a, 2.35)

	get_tree().quit(0)


func _clear(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


func _reset(p: Player, pos: Vector3, yaw := 0.0) -> void:
	p.global_position = pos
	p.rotation.y = yaw
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = pos


func _corner_depth(p: Player, a: Arena) -> float:
	var hx := p.body_radius + 0.05
	var hz := p.body_length * 0.5
	var fwd := Vector3(-sin(p.rotation.y), 0.0, -cos(p.rotation.y))
	var right := Vector3(cos(p.rotation.y), 0.0, -sin(p.rotation.y))
	var deep := 0.0
	for sz in [-1.0, 1.0]:
		for sx in [-1.0, 1.0]:
			var pt: Vector3 = p.global_position + fwd * hz * sz + right * hx * sx
			deep = maxf(deep, _point_depth(a, pt))
	return deep


func _point_depth(a: Arena, pt: Vector3) -> float:
	var c := Arena.to_cell(pt)
	if not a.blocks_tank(c.x, c.y):
		return 0.0
	var center := Arena.cell_center(c.x, c.y)
	var half := Arena.CELL * 0.5
	return minf(half - absf(pt.x - center.x), half - absf(pt.z - center.z))


## 全速撞墙：墙在第 8 行（z = 0 的南侧），车从远处朝墙开
func _ram(p: Player, a: Arena, deg: float) -> void:
	for x in range(2, 22):
		a.grid[16][x] = Arena.STEEL
	a._rebuild_all()
	var start := Arena.cell_center(11, 10)
	_reset(p, start, 0.0)
	await _frames(2)
	var yaw: float = deg_to_rad(deg)
	p.rotation.y = yaw
	var deepest := 0.0
	var deep_frames := 0
	for i in 200:
		p.drive(1.0, 0.0, 1.0 / Engine.physics_ticks_per_second)
		var d := _corner_depth(p, a)
		deepest = maxf(deepest, d)
		if d > 0.10:
			deep_frames += 1
	print("PROBE ram%3.0f  deep=%.2f frames>10cm=%3d/200 spd=%.1f pos=(%.1f,%.1f)" % [
		deg, deepest, deep_frames, p._speed, p.global_position.x, p.global_position.z])
	_clear(a)


## 4 m 走廊（第 11/13 列是墙，第 12 列可走），以偏角 deg 起步直行
func _corridor_drive(p: Player, a: Arena, deg: float) -> void:
	for y in range(2, 22):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
	var center := Arena.cell_center(12, 17)
	_reset(p, center, deg_to_rad(deg))
	await _frames(2)
	var deepest := 0.0
	var deep_frames := 0
	var min_speed := 99.0
	for i in 300:
		p.drive(1.0, 0.0, 1.0 / Engine.physics_ticks_per_second)
		var d := _corner_depth(p, a)
		deepest = maxf(deepest, d)
		if d > 0.10:
			deep_frames += 1
		min_speed = minf(min_speed, absf(p._speed))
	print("PROBE corr%3.0f deep=%.2f frames>10cm=%3d/300 minSpd=%.1f z=%.1f yaw=%.1f" % [
		deg, deepest, deep_frames, min_speed, p.global_position.z, rad_to_deg(p.rotation.y)])
	_clear(a)


## 贴着单侧墙平行开，然后持续给舵
func _wall_turn(p: Player, a: Arena, dist_to_wall: float) -> void:
	for y in range(2, 22):
		a.grid[y][12] = Arena.BRICK
	a._rebuild_all()
	var c := Arena.cell_center(11, 14)
	var pos := Vector3(-dist_to_wall, 0.0, c.z)
	_reset(p, pos, 0.0)
	await _frames(2)
	var deepest := 0.0
	var blocked := 0
	var yaw0: float = p.rotation.y
	for i in 300:
		p.drive(1.0, 1.0, 1.0 / Engine.physics_ticks_per_second)
		deepest = maxf(deepest, _corner_depth(p, a))
		if p.turn_blocked:
			blocked += 1
	print("PROBE wallturn dist=%.2f turn=%.1f deep=%.2f blocked=%d/300 spd=%.1f" % [
		dist_to_wall, rad_to_deg(absf(angle_difference(yaw0, p.rotation.y))), deepest, blocked, p._speed])
	_clear(a)
