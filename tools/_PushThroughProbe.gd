extends Node
## 临时诊断：被另一辆车/道具"顶进墙里"之后，车会从哪一侧出来（可能整段穿墙）。
## 打印标签全用 ASCII。

const STEP := 1.0 / 120.0

var _main: Node
var _a: Arena
var _p: Player


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
	_main.state_timer = 1.0e9
	_main.spawn_queue.clear()
	_main.max_active = 0
	for e in _main.enemies.duplicate():
		e.queue_free()
		_main.enemies.erase(e)
	_p = _main.player
	_p.shield_t = 0.0
	_p.set_physics_process(false)
	_a = _main.arena
	await _frames(2)

	_clear()
	for y in range(2, 24):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	print("PROBE wall cell13 brick=%s blocks=%s" % [
		_a.cell(13, 12) == Arena.BRICK, _a.blocks_tank(13, 12)])

	for push in [0.5, 1.0, 2.0, 3.0, 4.0]:
		_case(push, 0.0)
	for push in [1.0, 2.5, 4.0]:
		_case(push, PI * 0.5)
	get_tree().quit(0)


func _case(push: float, yaw: float) -> void:
	var p := _p
	var home := Arena.cell_center(12, 12)
	p.global_position = home
	p.rotation.y = yaw
	p._speed = 0.0
	p.rotation.y = yaw
	p._safe_pos = home
	var dir := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := p._depen_offset_at(home + dir * push, yaw)
	p.nudge(dir * push)
	var after: Vector3 = p.global_position
	var d0 := _depth(p)

	# 之后按住油门继续开，看它从墙的哪一侧出来
	var crossed := false
	var worst := d0
	var wall_far_x: float = Arena.cell_center(13, 12).x + Arena.CELL * 0.5
	for i in 240:
		p.drive(1.0, 0.0, STEP)
		worst = maxf(worst, _depth(p))
		if p.global_position.x > wall_far_x + 0.5:
			crossed = true
	print("PROBE push=%.1f yaw=%3.0f raw_off=(%.2f,%.2f) nudge->(%.2f,%.2f) deep=%.2f worst=%.2f end=(%.2f,%.2f) crossed=%s" % [
		push, rad_to_deg(yaw), off.x, off.z, after.x, after.z, d0, worst,
		p.global_position.x, p.global_position.z, crossed])


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY


func _depth(p: Player) -> float:
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
			var c := Arena.to_cell(pt)
			if not _a.blocks_tank(c.x, c.y):
				continue
			var cc := Arena.cell_center(c.x, c.y)
			var half := Arena.CELL * 0.5
			deep = maxf(deep, minf(half - absf(pt.x - cc.x), half - absf(pt.z - cc.z)))
	return deep


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
