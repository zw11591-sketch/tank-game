extends Node
## 临时诊断：从空地斜着开进单格宽街口，量车体角点压进砖墙的深度。
##
## _drive_clip_probe.gd 的 corrXX 是把车*直接摆*在走廊中间带着偏角起步，
## 那个初始状态玩家到不了。真正会发生的是：在路口斜着（镜头相对驾驶留了
## 十几度的航向误差）对着街口一脚油门。这里就量这个。

var _main: Node


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
	_main.player.shield_t = 0.0
	var a: Arena = _main.arena
	_clear(a)
	a._rebuild_all()
	await _frames(4)
	var p: Player = _main.player
	print("PROBE tank=%s r=%.2f len=%.2f hullW=%.2f f=%.2f b=%.2f" % [
		p.tank_id, p.body_radius, p.body_length, p._hull_half_w, p._hull_half_f, p._hull_half_b])

	for deg in [0.0, 8.0, 15.0, 25.0, 35.0]:
		await _entry(p, a, deg)

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


## 南边空地，第 10 行一堵墙、第 12 列留一格宽的门；车从 (12,16) 朝 -Z 斜着开进去
func _entry(p: Player, a: Arena, deg: float) -> void:
	_clear(a)
	for x in range(2, 22):
		a.grid[10][x] = Arena.BRICK
	a.grid[10][12] = Arena.EMPTY
	for y in range(2, 10):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
	var start := Arena.cell_center(12, 16)
	p.global_position = start
	p.rotation.y = deg_to_rad(deg)
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = start
	await _frames(2)

	var deepest := 0.0
	var deep_frames := 0
	var blocked := 0
	var mouth_z := Arena.cell_center(12, 10).z
	for _i in 360:
		p.drive(1.0, 0.0, 1.0 / Engine.physics_ticks_per_second)
		var d := _visible_depth(p, a)
		deepest = maxf(deepest, d)
		if d > 0.10:
			deep_frames += 1
		if p.turn_blocked:
			blocked += 1
	print("PROBE entry%3.0f deep=%.2f frames>10cm=%3d/360 through=%s pos=(%.1f,%.1f) yaw=%.1f blk=%d" % [
		deg, deepest, deep_frames,
		"yes" if p.global_position.z < mouth_z - 2.0 else "no",
		p.global_position.x, p.global_position.z,
		rad_to_deg(p.rotation.y), blocked])
	_clear(a)


## 按坦克自己的碰撞轮廓（_hull_half_*）采样，量"看得见的那一层"压进多深
func _visible_depth(p: Player, a: Arena) -> float:
	var yaw: float = p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (p._hull_half_f - p._hull_half_b) * 0.5
	var center: Vector3 = p.global_position + fwd * off
	var hl := (p._hull_half_f + p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 5:
		for ix in 5:
			var u := (float(ix) / 4.0 - 0.5) * 2.0
			var w := (float(iz) / 4.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * p._hull_half_w) + fwd * (w * hl)
			deep = maxf(deep, _point(a, pt))
	return deep


func _point(a: Arena, pt: Vector3) -> float:
	var c := Arena.to_cell(pt)
	if not a.blocks_tank(c.x, c.y):
		return 0.0
	var center := Arena.cell_center(c.x, c.y)
	var half := Arena.CELL * 0.5
	return minf(half - absf(pt.x - center.x), half - absf(pt.z - center.z))
