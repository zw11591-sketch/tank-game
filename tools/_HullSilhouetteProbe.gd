extends Node
## 临时诊断：把车体可见轮廓的**真实凸包**从模型顶点里量出来，与 _hull_half_* 的
## 包围盒矩形对比；再算两种轮廓在 4 m / 8 m 走廊里各能原地转多少度。
## 打印标签全用 ASCII。

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
	var p: Player = _main.player
	await get_tree().process_frame
	print("PROBE tank=%s hullRect=(%.3f, %.3f/%.3f)" % [
		p.tank_id, p._hull_half_w, p._hull_half_f, p._hull_half_b])

	var pts := _silhouette(p)
	print("PROBE verts=%d hullPts=%d" % [_last_vert_count, pts.size()])
	var maxx := 0.0
	var maxf := 0.0
	var maxb := 0.0
	for q in pts:
		maxx = maxf(maxx, absf(q.x))
		maxf = maxf(maxf, -q.y)
		maxb = maxf(maxb, q.y)
	print("PROBE hullTrue halfW=%.3f front=%.3f back=%.3f" % [maxx, maxf, maxb])
	for q in pts:
		print("PROBE pt  x=%6.3f z=%6.3f" % [q.x, q.y])

	print("PROBE corridor rect w4=%.1fdeg  w8=%.1fdeg" % [
		_max_yaw_rect(p, 4.0), _max_yaw_rect(p, 8.0)])
	print("PROBE corridor poly w4=%.1fdeg  w8=%.1fdeg" % [
		_max_yaw_poly(pts, p, 4.0), _max_yaw_poly(pts, p, 8.0)])
	get_tree().quit(0)


var _last_vert_count := 0


## 车体可见轮廓在车体局部 XZ 平面上的凸包（顺时针），只取 y 落在车体高度内的顶点
func _silhouette(p: Player) -> PackedVector2Array:
	var raw: Array = []
	_last_vert_count = 0
	for mi in _hull_meshes(p, p):
		var arr := mi.mesh.surface_get_arrays(0)
		if arr.is_empty():
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		_last_vert_count += verts.size()
		for v in verts:
			var aabb_y := mi.get_aabb()
			if aabb_y.size.y <= 0.0:
				continue
			raw.append(Vector2(v.x, v.z))
	# 去重后取凸包
	var uniq: Array = []
	for q in raw:
		var dup := false
		for u in uniq:
			if (u as Vector2).distance_squared_to(q) < 1e-8:
				dup = true
				break
		if not dup:
			uniq.append(q)
	return _convex_hull(uniq)


func _convex_hull(src: Array) -> PackedVector2Array:
	var pts: Array = src.duplicate()
	pts.sort_custom(func(a, b):
		return a.x < b.x or (is_equal_approx(a.x, b.x) and a.y < b.y))
	if pts.size() < 3:
		return PackedVector2Array(pts)
	var cross := func(o, a, b):
		return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
	var lower: Array = []
	for q in pts:
		while lower.size() >= 2 and cross.call(lower[-2], lower[-1], q) <= 0.0:
			lower.pop_back()
		lower.append(q)
	var upper: Array = []
	for i in range(pts.size() - 1, -1, -1):
		var q = pts[i]
		while upper.size() >= 2 and cross.call(upper[-2], upper[-1], q) <= 0.0:
			upper.pop_back()
		upper.append(q)
	lower.pop_back()
	upper.pop_back()
	var out := PackedVector2Array()
	for q in lower:
		out.append(q)
	for q in upper:
		out.append(q)
	return out


func _max_yaw_rect(p: Player, width: float) -> float:
	var yaw := 0.0
	while yaw < PI * 0.5:
		yaw += deg_to_rad(0.5)
		if not _rect_ok(p, width, yaw):
			return yaw - deg_to_rad(0.5)
	return 90.0


func _rect_ok(p: Player, width: float, yaw: float) -> bool:
	var half := width * 0.5
	var rx := cos(yaw)
	var rz := -sin(yaw)
	var fx := -sin(yaw)
	var fz := -cos(yaw)
	var ofs := (p._hull_half_f - p._hull_half_b) * 0.5
	var cx := fx * ofs
	var cz := fz * ofs
	for sz in [-1.0, 0.0, 1.0]:
		for sx in [-1.0, 0.0, 1.0]:
			var lx: float = sx * p._hull_half_w
			var lz: float = sz * (p._hull_half_f + p._hull_half_b) * 0.5
			var wx := cx + rx * lx + fx * lz
			var wz := cz + rz * lx + fz * lz
			if absf(wx) > half - 1e-4:
				return false
	return true


func _max_yaw_poly(pts: PackedVector2Array, p: Player, width: float) -> float:
	var yaw := 0.0
	while yaw < PI * 0.5:
		yaw += deg_to_rad(0.5)
		if not _poly_ok(pts, width, yaw):
			return yaw - deg_to_rad(0.5)
	return 90.0


func _poly_ok(pts: PackedVector2Array, width: float, yaw: float) -> bool:
	var half := width * 0.5
	var rx := cos(yaw)
	var rz := -sin(yaw)
	var fx := -sin(yaw)
	var fz := -cos(yaw)
	for q in pts:
		var wx := rx * q.x + fx * q.y
		var wz := rz * q.x + fz * q.y
		if absf(wx) > half - 1e-4:
			return false
	return true


func _hull_meshes(root: Node, n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and n.mesh != null and (n as MeshInstance3D).mesh.surface_get_arrays(0).size() > 0:
		if _counts(root, n):
			out.append(n)
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		out.append_array(_hull_meshes(root, c))
	return out


func _counts(root: Node, mi: Node) -> bool:
	if not (mi as MeshInstance3D).visible:
		return false
	if (mi as MeshInstance3D).mesh is SphereMesh:
		return false
	var n: Node = mi
	while n != null and n != root:
		var s := String(n.name)
		if s.begins_with("Shield") or s.begins_with("Guide"):
			return false
		if s.begins_with("Turret") or s.begins_with("Barrel") or s.begins_with("Muzzle"):
			return false
		n = n.get_parent()
	return true
