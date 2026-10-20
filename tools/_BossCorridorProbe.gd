extends Node
## 临时诊断：最宽的 Boss / 重坦开进单格走廊时，可见车体压进墙里多深。

const STEP := 1.0 / 120.0

var _g: Node
var _a: Arena

func _ready() -> void:
	_g = Node.new()
	_g.set("state", "play")
	add_child(_g)
	_a = Arena.new()
	_a.game = _g
	add_child(_a)
	_a.generate(1, 6)
	await _frames(2)

	for t in [4, 2, 1]:
		await _run(t)
	get_tree().quit(0)


func _run(etype: int) -> void:
	var e := Enemy.new()
	e.etype = etype
	e.configure(etype, 1, 1)
	e.setup(_g, _a, Arena.cell_center(12, 12))
	add_child(e)
	await _frames(2)
	e.set_physics_process(false)
	e.shield_t = 0.0
	var tag := "etype%d" % etype
	print("PROBE %s hull=(%.2f x %.2f..%.2f) r=%.2f" % [
		tag, e._hull_half_w, e._hull_half_f, e._hull_half_b, e.body_radius])

	# 造一条单格宽、沿 -Z 的走廊
	_clear()
	for y in range(1, Arena.GRID_H - 1):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	var pos := Arena.cell_center(12, 12)
	e.global_position = pos
	e.rotation.y = 0.0
	e._speed = 0.0
	e.velocity = Vector3.ZERO
	e._safe_pos = pos
	var worst := 0.0
	for i in 240:
		e.drive(1.0, 0.0, STEP)
		worst = maxf(worst, _depth(e))
	print("PROBE %s straight  worst=%.3f z=%.1f" % [tag, worst, e.global_position.z])

	# 单格走廊里打舵
	e.global_position = pos
	e.rotation.y = 0.0
	e._speed = 0.0
	e.velocity = Vector3.ZERO
	e._safe_pos = pos
	worst = 0.0
	for i in 240:
		e.drive(0.0, 1.0, STEP)
		worst = maxf(worst, _depth(e))
	print("PROBE %s pivot     yaw=%.1f worst=%.3f" % [
		tag, rad_to_deg(e.rotation.y), worst])

	e.queue_free()
	await _frames(2)


func _depth(t: Tank) -> float:
	var yaw: float = t.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (t._hull_half_f - t._hull_half_b) * 0.5
	var center: Vector3 = t.global_position + fwd * off
	var hl := (t._hull_half_f + t._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 9:
		for ix in 9:
			var u := (float(ix) / 8.0 - 0.5) * 2.0
			var w := (float(iz) / 8.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * t._hull_half_w) + fwd * (w * hl)
			var c := Arena.to_cell(pt)
			if not _a.blocks_tank(c.x, c.y):
				continue
			var cc := Arena.cell_center(c.x, c.y)
			var half := Arena.CELL * 0.5
			deep = maxf(deep, minf(half - absf(pt.x - cc.x), half - absf(pt.z - cc.z)))
	return deep


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
