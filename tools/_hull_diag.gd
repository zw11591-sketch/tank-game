extends SceneTree
## 临时诊断：把每台车的 Hull / Turret / Barrel 各节点的世界包围盒摊开，
## 与碰撞轮廓（body_radius / body_length）逐项对照，找出"视觉比碰撞大多少"。

func _init() -> void:
	for key in ["tank_player", "tank_heavy", "tank_boss"]:
		var inst := Assets.instantiate(key)
		if inst == null:
			print("MISSING ", key)
			continue
		print("== ", key)
		print("  whole   ", _aabb_of(inst, inst))
		for nm in ["Hull", "Turret", "Barrel", "Muzzle"]:
			var n := Assets.find_node(inst, nm)
			if n == null:
				print("  ", nm, " missing")
				continue
			print("  %-7s %s  localpos=%s" % [nm, _aabb_of(n, inst), n.position])
		inst.free()
	quit(0)


func _aabb_of(n: Node, root: Node) -> String:
	var out := AABB()
	var first := true
	for mi in _meshes(n):
		var a: AABB = mi.global_transform * mi.get_aabb() if mi.is_inside_tree() else _xform_aabb(root, mi)
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return "size=(%.2f, %.2f, %.2f) center=(%.2f, %.2f, %.2f)" % [
		out.size.x, out.size.y, out.size.z, out.position.x, out.position.y, out.position.z]


## 节点还没进场景树：手动沿父链累乘变换
func _xform_aabb(root: Node, mi: MeshInstance3D) -> AABB:
	var xf := Transform3D.IDENTITY
	var n: Node = mi
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf * mi.get_aabb()


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.get_children():
		if c is MeshInstance3D and c.mesh != null:
			out.append(c)
		out.append_array(_meshes(c))
	return out
