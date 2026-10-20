extends Node
## 临时诊断：窄走廊里"站着打舵"时，车体矩形最多压进墙里多深。
##
## 只量 _hull_half_*（现在等于模型实测轮廓）做出的矩形与实心格的重叠，
## 于是数字就是玩家看得见的那一层，不是物理圆柱。

const STEP := 1.0 / 120.0

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 0
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1e9
	_main.player.shield_t = 0.0
	_main.spawn_queue.clear()
	_main.max_active = 0
	var p: Player = _main.player
	p.set_physics_process(false)
	print("PROBE clip2 tank=%s hull=(%.2f, %.2f/%.2f)" % [
		p.tank_id, p._hull_half_w, p._hull_half_f, p._hull_half_b])

	var a: Arena = _main.arena
	_clear(a)
	a._rebuild_all()
	await _frames(2)

	# 单格宽走廊（4 m），车沿走廊轴停在中间，只打舵不打油
	for y in range(2, 24):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
	await _frames(2)
	_reset(p, Arena.cell_center(12, 12), 0.0)
	await _frames(2)
	var deep := 0.0
	var yaw0: float = p.rotation.y
	for i in 600:
		p.drive(0.0, 1.0, STEP)
		deep = maxf(deep, _depth(p, a))
	print("PROBE clip2 corridor pivot turned=%.1f maxVisDeep=%.2f" % [
		rad_to_deg(absf(angle_difference(yaw0, p.rotation.y))), deep])

	# 顶着单侧墙、同时给油门与舵（贴墙磨）
	_clear(a)
	for y in range(2, 24):
		a.grid[y][12] = Arena.BRICK
	a._rebuild_all()
	await _frames(2)
	_reset(p, Vector3(-2.15, 0.0, Arena.cell_center(11, 12).z), 0.0)
	await _frames(2)
	deep = 0.0
	yaw0 = p.rotation.y
	for i in 600:
		p.drive(1.0, 1.0, STEP)
		deep = maxf(deep, _depth(p, a))
	print("PROBE clip2 wall grind turned=%.1f maxVisDeep=%.2f" % [
		rad_to_deg(absf(angle_difference(yaw0, p.rotation.y))), deep])

	# 车鼻插进单格宽的口袋（route_probe 里那种楔死工况）
	_clear(a)
	for y in range(4, 24):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a.grid[4][12] = Arena.BRICK
	for x in range(2, 11):
		a.grid[7][x] = Arena.BRICK
	a._rebuild_all()
	await _frames(2)
	_reset(p, Arena.cell_center(12, 13), 0.0)
	await _frames(2)
	deep = 0.0
	var moved := 0.0
	var from: Vector3 = p.global_position
	for i in 480:
		p.drive(1.0, 0.0, STEP)
		deep = maxf(deep, _depth(p, a))
	moved = p.global_position.distance_to(from)
	print("PROBE clip2 keyhole moved=%.2f maxVisDeep=%.2f" % [moved, deep])

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


## 车体矩形（按 _hull_half_*）在实心格里的最大压入深度
func _depth(p: Player, a: Arena) -> float:
	var yaw: float = p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (p._hull_half_f - p._hull_half_b) * 0.5
	var center: Vector3 = p.global_position + fwd * off
	var hl := (p._hull_half_f + p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 7:
		for ix in 7:
			var u := (float(ix) / 6.0 - 0.5) * 2.0
			var w := (float(iz) / 6.0 - 0.5) * 2.0
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
