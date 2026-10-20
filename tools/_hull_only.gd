extends SceneTree
## 临时诊断：只量 HullMesh / TurretMesh / BarrelMesh 的局部包围盒。

func _init() -> void:
	for key in ["tank_player", "tank_scout", "tank_heavy", "tank_artillery", "tank_destroyer", "tank_boss"]:
		var inst := Assets.instantiate(key)
		if inst == null:
			print("MISSING ", key)
			continue
		var hull := Assets.find_node(inst, "HullMesh")
		var tur := Assets.find_node(inst, "TurretMesh")
		var bar := Assets.find_node(inst, "BarrelMesh")
		print("== %s  hull=%s turret=%s barrel=%s" % [key, _a(root_of(hull, inst), hull), _a(root_of(tur, inst), tur), _a(root_of(bar, inst), bar)])
		print("   dims=%s" % str(TankRoster.dims(key)))
		inst.free()
	quit(0)


static func root_of(_n: Node, root: Node) -> Node:
	return root


func _a(root: Node, n: Node) -> String:
	if n == null:
		return "missing"
	var out := AABB()
	var first := true
	for mi in _meshes(n):
		var xf := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != root:
			if cur is Node3D:
				xf = (cur as Node3D).transform * xf
			cur = cur.get_parent()
		var a: AABB = xf * mi.get_aabb()
		out = a if first else out.merge(a)
		first = false
	return "xz=(%.2f,%.2f) c=(%.2f,%.2f)" % [out.size.x, out.size.z, out.position.x, out.position.z]


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D and n.mesh != null:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
