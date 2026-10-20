extends Node
## 临时诊断：单格走廊里，逐度打印"转过去之后推不推得出来"，定位转向被过度否决的原因。
## 打印标签全用 ASCII。

var _main: Node
var _a: Arena
var _p: Player


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 2      # 铁砧（最宽的玩家车）
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
	for y in range(2, 22):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	print("PROBE tank=%s hull=(%.2f, %.2f/%.2f) cell=%.1f" % [
		_p.tank_id, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b, Arena.CELL])

	_p.global_position = Arena.cell_center(12, 12)
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = _p.global_position
	await _frames(2)
	for i in range(0, 25):
		var yaw := deg_to_rad(float(i))
		var pos := _p.global_position
		var raw := _p._hull_depth_at(pos, yaw)
		var off: Vector3 = _p._depen_offset_at(pos, yaw)
		var res: float = _p._resolved_depth(pos, yaw)
		print("PROBE deg=%2d raw=%.3f push=(%.3f,%.3f) res=%.3f" % [
			i, raw, off.x, off.z, res])

	# 实际给舵：每帧的转角
	_p.rotation.y = 0.0
	_p._settle()
	var total := 0.0
	for i in 120:
		var before: float = _p.rotation.y
		_p.drive(0.0, 1.0, 1.0 / 120.0)
		var d: float = absf(angle_difference(before, _p.rotation.y))
		total += d
		if i < 8:
			print("PROBE frame=%d d=%.3fdeg blocked=%s pos=(%.3f,%.3f)" % [
				i, rad_to_deg(d), str(_p.turn_blocked),
				_p.global_position.x, _p.global_position.z])
	print("PROBE total=%.1fdeg" % rad_to_deg(total))
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
