extends Node
## 临时诊断：被另一辆车顶开（Tank.nudge）时，车体能不能被顶进墙里。
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
	_a = _main.arena
	await _frames(4)

	_clear()
	# 一条沿 Z 的墙（第 13 列），车在第 12 列贴墙
	for y in range(2, 22):
		_a.grid[y][13] = Arena.STEEL
	_a._rebuild_all()
	await _frames(2)

	# 1) 单侧墙：朝墙方向被顶 0.6 m
	_reset(Arena.cell_center(12, 12), 0.0)
	print("PROBE nudge side before=%.3f" % _depth())
	for i in 40:
		_p.nudge(Vector3(0.02, 0.0, 0.0))
	print("PROBE nudge side after=%.3f pos=(%.2f,%.2f)" % [
		_depth(), _p.global_position.x, _p.global_position.z])

	# 2) 墙角：朝角落被顶
	_clear()
	for y in range(2, 22):
		_a.grid[y][13] = Arena.STEEL
	for x in range(2, 22):
		_a.grid[13][x] = Arena.STEEL
	_a._rebuild_all()
	await _frames(2)
	_reset(Arena.cell_center(12, 12), 0.0)
	print("PROBE nudge corner before=%.3f" % _depth())
	for i in 60:
		_p.nudge(Vector3(0.02, 0.0, 0.02))
	print("PROBE nudge corner after=%.3f pos=(%.2f,%.2f)" % [
		_depth(), _p.global_position.x, _p.global_position.z])

	# 3) 单格走廊：朝侧墙被顶
	_clear()
	for y in range(2, 22):
		_a.grid[y][11] = Arena.STEEL
		_a.grid[y][13] = Arena.STEEL
	_a._rebuild_all()
	await _frames(2)
	_reset(Arena.cell_center(12, 12), 0.0)
	print("PROBE nudge corridor before=%.3f" % _depth())
	for i in 40:
		_p.nudge(Vector3(0.02, 0.0, 0.0))
	print("PROBE nudge corridor after=%.3f" % _depth())

	get_tree().quit(0)


func _reset(pos: Vector3, yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY


func _depth() -> float:
	var yaw: float = _p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (_p._hull_half_f - _p._hull_half_b) * 0.5
	var center: Vector3 = _p.global_position + fwd * off
	var hl := (_p._hull_half_f + _p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 9:
		for ix in 9:
			var u := (float(ix) / 8.0 - 0.5) * 2.0
			var w := (float(iz) / 8.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * _p._hull_half_w) + fwd * (w * hl)
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
