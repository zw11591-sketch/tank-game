extends Node
## 临时诊断：用**真实网格顶点**逐点量"看得见的车体"压进砖墙多深，
## 与 Tank 自己的 _hull_half_* 矩形判据对比。打印标签全用 ASCII。

const STEP := 1.0 / 120.0

var _main: Node
var _a: Arena
var _p: Player
var _verts: Array = []   # [{mi, arr}]


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
	_collect(_p)
	print("PROBE verts=%d hullRect=(%.3f, %.3f/%.3f)" % [
		_vert_count(), _p._hull_half_w, _p._hull_half_f, _p._hull_half_b])
	for e in _verts:
		print("PROBE mesh %s verts=%d" % [String((e[0] as Node).name),
			(e[1] as PackedVector3Array).size()])

	# 1) 单格走廊：转到头
	_clear()
	for y in range(2, 24):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	_reset(Arena.cell_center(12, 12), 0.0)
	var worst_mesh := 0.0
	var worst_rect := 0.0
	for i in 300:
		_p.drive(0.0, 1.0, STEP)
		worst_mesh = maxf(worst_mesh, _mesh_depth())
		worst_rect = maxf(worst_rect, _rect_depth())
	print("PROBE pivot yaw=%.1f meshDeep=%.3f rectDeep=%.3f" % [
		rad_to_deg(_p.rotation.y), worst_mesh, worst_rect])

	# 2) 全速撞墙
	_clear()
	for x in range(2, 24):
		_a.grid[14][x] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	_reset(Arena.cell_center(12, 10), 0.0)
	worst_mesh = 0.0
	worst_rect = 0.0
	for i in 300:
		_p.drive(1.0, 0.0, STEP)
		worst_mesh = maxf(worst_mesh, _mesh_depth())
		worst_rect = maxf(worst_rect, _rect_depth())
	print("PROBE ram meshDeep=%.3f rectDeep=%.3f z=%.2f" % [
		worst_mesh, worst_rect, _p.global_position.z])

	# 3) 斜着蹭墙
	_clear()
	for y in range(2, 24):
		_a.grid[y][12] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	_reset(Vector3(-1.90, 0.0, Arena.cell_center(11, 4).z), deg_to_rad(20.0))
	worst_mesh = 0.0
	worst_rect = 0.0
	for i in 480:
		_p.drive(1.0, 0.0, STEP)
		worst_mesh = maxf(worst_mesh, _mesh_depth())
		worst_rect = maxf(worst_rect, _rect_depth())
	print("PROBE graze meshDeep=%.3f rectDeep=%.3f" % [worst_mesh, worst_rect])
	get_tree().quit(0)


func _collect(n: Node) -> void:
	if n is MeshInstance3D and n.mesh != null:
		if _counts(n) and n.mesh.get_surface_count() > 0:
			var arr: Array = n.mesh.surface_get_arrays(0)
			if not arr.is_empty():
				_verts.append([n, arr[Mesh.ARRAY_VERTEX]])
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		_collect(c)


func _counts(mi: Node) -> bool:
	if not (mi as MeshInstance3D).visible:
		return false
	if (mi as MeshInstance3D).mesh is SphereMesh:
		return false
	var n: Node = mi
	while n != null and n != _p:
		var s := String(n.name)
		if s.begins_with("Shield") or s.begins_with("Guide"):
			return false
		if s.begins_with("Turret") or s.begins_with("Barrel") or s.begins_with("Muzzle"):
			return false
		n = n.get_parent()
	return true


func _vert_count() -> int:
	var n := 0
	for e in _verts:
		n += (e[1] as PackedVector3Array).size()
	return n


## 真实顶点到实心格边界的最大压入深度
func _mesh_depth() -> float:
	var deep := 0.0
	for e in _verts:
		var mi: MeshInstance3D = e[0]
		var verts: PackedVector3Array = e[1]
		var xf := mi.global_transform
		for v in verts:
			var w: Vector3 = xf * v
			deep = maxf(deep, _pt_depth(w))
	return deep


## Tank 自己的矩形判据（与 _ClipAfter 的 _depth 相同）
func _rect_depth() -> float:
	var yaw: float = _p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (_p._hull_half_f - _p._hull_half_b) * 0.5
	var center: Vector3 = _p.global_position + fwd * off
	var hl := (_p._hull_half_f + _p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 7:
		for ix in 7:
			var u := (float(ix) / 6.0 - 0.5) * 2.0
			var w := (float(iz) / 6.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * _p._hull_half_w) + fwd * (w * hl)
			deep = maxf(deep, _pt_depth(pt))
	return deep


func _pt_depth(pt: Vector3) -> float:
	var c := Arena.to_cell(pt)
	if not _a.blocks_tank(c.x, c.y):
		return 0.0
	var cc := Arena.cell_center(c.x, c.y)
	var half := Arena.CELL * 0.5
	return minf(half - absf(pt.x - cc.x), half - absf(pt.z - cc.z))


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


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
