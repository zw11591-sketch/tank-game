extends Node
## 临时诊断：只查"两格宽走廊里为什么转不动"。
## 打印标签全用 ASCII。

const STEP := 1.0 / 120.0

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
	_p.set_physics_process(false)
	_a = _main.arena
	await _frames(2)
	print("PROBE tank=%s hull=(%.3f, %.3f/%.3f)" % [
		_p.tank_id, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b])

	_clear()
	for y in range(2, 22):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][14] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	print("PROBE grid11=%d grid12=%d grid13=%d grid14=%d x11=(%.1f..%.1f) x14=(%.1f..%.1f)" % [
		_a.cell(11, 12), _a.cell(12, 12), _a.cell(13, 12), _a.cell(14, 12),
		Arena.cell_center(11, 12).x - 2.0, Arena.cell_center(11, 12).x + 2.0,
		Arena.cell_center(14, 12).x - 2.0, Arena.cell_center(14, 12).x + 2.0])

	var pos := Arena.cell_center(12, 12)
	print("PROBE center=(%.2f,%.2f) blocks_here=%s" % [pos.x, pos.z, str(_a.blocks_tank(12, 12))])
	for i in range(0, 13):
		var yaw := deg_to_rad(float(i) * 2.0)
		var raw: float = _p._hull_depth_at(pos, yaw)
		var off: Vector3 = _p._depen_offset_at(pos, yaw)
		var res: float = _p._resolved_depth(pos, yaw)
		print("PROBE deg=%2d raw=%.3f push=(%.3f,%.3f) res=%.3f" % [i * 2, raw, off.x, off.z, res])

	_p.global_position = pos
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos
	await _frames(1)
	for i in 12:
		var before: float = _p.rotation.y
		_p.drive(0.0, 1.0, STEP)
		print("PROBE f=%2d yaw=%6.2f d=%5.2f blocked=%s pos=(%.2f,%.2f) depth=%.3f" % [
			i, rad_to_deg(_p.rotation.y), rad_to_deg(absf(angle_difference(before, _p.rotation.y))),
			str(_p.turn_blocked), _p.global_position.x, _p.global_position.z, _p._hull_depth(_p.rotation.y)])
	get_tree().quit(0)


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
