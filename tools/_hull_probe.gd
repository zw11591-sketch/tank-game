extends Node
## 临时诊断：把每款车的**车体可见轮廓**（不含炮塔 / 炮管）量成数字，
## 与 Tank._hull_half_w / _hull_half_l 用的名册尺寸对照。
## 打印全 ASCII。

const KEYS := ["tank_player", "tank_scout", "tank_medium", "tank_heavy",
		"tank_artillery", "tank_destroyer", "tank_boss"]


func _ready() -> void:
	await get_tree().process_frame
	for key in KEYS:
		var inst := Assets.instantiate(key)
		if inst == null:
			print("PROBE %-16s MISSING" % key)
			continue
		add_child(inst)
		await get_tree().process_frame
		var hull := _aabb(inst, true)
		var whole := _aabb(inst, false)
		print("PROBE %-16s hull size=(%.2f, %.2f, %.2f) center=(%.2f, %.2f, %.2f) | whole size=(%.2f, %.2f, %.2f)" % [
			key, hull.size.x, hull.size.y, hull.size.z,
			hull.get_center().x, hull.get_center().y, hull.get_center().z,
			whole.size.x, whole.size.y, whole.size.z])
		for mi in _meshes(inst):
			var a: AABB = mi.get_aabb()
			var xf := _xf_under(inst, mi)
			a = xf * a
			var path := String(inst.get_path_to(mi))
			if not _under_turret(inst, mi):
				print("PROBE   %-40s x=[%+.2f,%+.2f] z=[%+.2f,%+.2f] y=[%+.2f,%+.2f]" % [
					path, a.position.x, a.position.x + a.size.x,
					a.position.z, a.position.z + a.size.z,
					a.position.y, a.position.y + a.size.y])
		inst.queue_free()
	get_tree().quit(0)


func _under_turret(root: Node, n: Node) -> bool:
	var p := n
	while p != null and p != root:
		var s := String(p.name)
		if s.begins_with("Turret") or s.begins_with("Barrel") or s.begins_with("Muzzle"):
			return true
		p = p.get_parent()
	return false


func _aabb(root: Node, hull_only: bool) -> AABB:
	var out := AABB()
	var first := true
	for mi in _meshes(root):
		if hull_only and _under_turret(root, mi):
			continue
		var a: AABB = _xf_under(root, mi) * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and n.mesh != null:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _xf_under(root: Node, node: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		if n == root:
			break
		n = n.get_parent()
	return xf
