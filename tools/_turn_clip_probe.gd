extends Node
## 临时诊断：转向响应 + 车体可见轮廓压进墙里的深度。
## 打印全 ASCII。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	print("DBG got main")
	_main._sel_tank = 2   # tank_heavy: 最宽，穿墙最明显
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	print("DBG sel set")
	_main._confirm_start()
	print("DBG started player=%s" % str(_main.player))
	await get_tree().process_frame
	_main.state = "play"
	print("DBG state play")
	_main.state_timer = 1.0e9
	_main.player.shield_t = 0.0
	_main.player.alive = true

	var a: Arena = _main.arena
	_clear(a)
	a._rebuild_all()
	await _frames(4)

	var p: Player = _main.player
	print("PROBE tank=%s body_r=%.2f body_len=%.2f nose_r=%.2f nose_f=%.2f" % [
		p.tank_id, p.body_radius, p.body_length, p._nose_r, p._nose_f])

	# ---- A. 开阔地：静止原地转 90°/180° 要多久 ----
	await _open_pivot(p, 90.0, "open90")
	await _open_pivot(p, 180.0, "open180")

	# ---- B. 单侧墙：车中心距墙面 d，纯转 ----
	for d in [1.95, 2.05, 2.3, 2.6, 3.0]:
		await _one_wall(p, a, d)

	# ---- C. 单格宽走廊（4m）：沿走廊轴，纯转 ----
	await _corridor(p, a, 4.0, "corr4")
	# 4.4m 走廊
	await _corridor(p, a, 4.4, "corr44")

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


## 逐帧快照：总转角 / 被几何否决的帧比例 / 车体四角压进实心格的最大深度
func _pivot(p: Player, a: Arena, secs: float, tag: String) -> void:
	var start_yaw := p.rotation.y
	var blocked := 0
	var deepest := 0.0
	var steps := int(secs * Engine.physics_ticks_per_second)
	var reached := 0.0
	var marks: Array = []
	for i in steps:
		p.drive(0.0, 1.0, 1.0 / Engine.physics_ticks_per_second)
		if p.turn_blocked:
			blocked += 1
		deepest = maxf(deepest, _corner_depth(p, a))
		var dy := absf(angle_difference(start_yaw, p.rotation.y))
		reached = rad_to_deg(dy)
		if (i + 1) % (Engine.physics_ticks_per_second / 5) == 0:
			marks.append("%.1f" % reached)
	print("PROBE pivot %-9s yaw=%6.1f blocked=%3d/%3d marks@0.2s=[%s] deep=%.2f" % [
		tag, reached, blocked, steps, ",".join(marks), deepest])


## 车体可视矩形四角压进墙里的最大深度（m，0 表示完全在外面）
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
	var dx := half - absf(pt.x - center.x)
	var dz := half - absf(pt.z - center.z)
	return minf(dx, dz)


## 车中心固定，绕一圈扫一遍：每个朝向允许的最大转角（用二分问 _limit_turn）
func _sweep(p: Player, a: Arena, tag: String) -> void:
	var free := 0.0
	var step := deg_to_rad(1.0)
	var yaw := 0.0
	p.rotation.y = 0.0
	var ys := 0.0
	# 顺时针能连续转到多少度
	for i in 180:
		var before: float = p.rotation.y
		var d: float = p._limit_turn(step)
		p.rotation.y += d
		if absf(d - step) > 1e-4:
			break
		ys += rad_to_deg(d)
	print("PROBE sweep %-9s max_turn=%6.1f" % [tag, ys])


func _open_pivot(p: Player, deg: float, tag: String) -> void:
	var a: Arena = _main.arena
	_reset(p, Arena.cell_center(12, 12), 0.0)
	await _frames(2)
	# 先量转速：0.5 秒
	var y0: float = p.rotation.y
	var steps := Engine.physics_ticks_per_second / 2
	for _i in steps:
		p.drive(0.0, 1.0, 1.0 / Engine.physics_ticks_per_second)
	var rate := absf(angle_difference(y0, p.rotation.y)) / 0.5
	print("PROBE rate open pivot rad/s=%.2f deg/s=%.0f" % [rate, rad_to_deg(rate)])
	_reset(p, Arena.cell_center(12, 12), 0.0)
	await _frames(2)
	await _pivot(p, a, 1.5, tag)


func _one_wall(p: Player, a: Arena, dist: float) -> void:
	# 墙占 x >= 2.0（第 13 列），车中心在 x = 2.0 - dist，朝 -Z
	for y in range(2, 22):
		a.grid[y][12] = Arena.BRICK
	a._rebuild_all()
	var center := Arena.cell_center(11, 12)
	var pos := Vector3(center.x + (2.0 - dist) - 0.0, 0.0, center.z)
	# cell_center(11,12).x 就是 x=0 格心；墙在第 12 列，其左边界就是 center.x + 2.0
	_reset(p, pos, 0.0)
	_sweep(p, a, "wall%.1f" % dist)
	_reset(p, pos, 0.0)
	await _frames(2)
	await _pivot(p, a, 1.0, "wall%.1f" % dist)
	_clear(a)


func _corridor(p: Player, a: Arena, width: float, tag: String) -> void:
	# 走廊沿 Z 轴：两侧墙列按宽度摆放，用格边界近似
	var cx := 12
	_clear(a)
	for y in range(2, 22):
		a.grid[y][cx - 1] = Arena.BRICK
		a.grid[y][cx + 1] = Arena.BRICK
	if width > 4.2:
		# 4.2 以上用 4 格宽 + 视觉近似（诊断用）
		a.grid[12][cx] = Arena.EMPTY
	a._rebuild_all()
	var center := Arena.cell_center(cx, 12)
	_reset(p, center, 0.0)
	_sweep(p, a, tag)
	_reset(p, center, 0.0)
	await _frames(2)
	print("DBG %s pos=(%.1f,%.1f) cell=%s blocked=%s depth0=%.2f wallCells=%s" % [
		tag, p.global_position.x, p.global_position.z,
		str(Arena.to_cell(p.global_position)), str(a.blocks_tank(cx - 1, 12)),
		p._hull_depth(0.0), str(a._blocks.size())])
	await _pivot(p, a, 1.0, tag)
	_clear(a)
