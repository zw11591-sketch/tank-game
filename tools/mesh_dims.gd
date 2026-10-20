extends SceneTree
## 量一下模型的包围盒，与碰撞体 / 4 米见方的碰撞格对照。
##
## 视觉比碰撞体大，玩家就会看到车"开进了障碍物里"——那和真的穿墙在观感上
## 是同一件事，而且调物理参数永远修不掉。所以这里直接把两者的尺寸摊开对比。
##
## 量的是**整棵子树**的包围盒（车体 + 履带 + 炮塔 + 炮管），不是 Assets.mesh_of()
## 拿到的第一个网格：第一版只量了车体网格，于是"履带比车体宽、炮管比车头长"
## 这两项在报表里完全看不见——而那正好是穿墙最明显的两处。

const TANKS := {
	"tank_player": 1.5, "tank_scout": 1.35, "tank_medium": 1.5,
	"tank_heavy": 1.75, "tank_artillery": 1.5, "tank_destroyer": 1.5,
	"tank_boss": 2.3,
}

const BLOCKS := [
	"wall_brick_a", "wall_steel_a", "water_surface",
	"prop_sandbags", "prop_hedgehog", "prop_wreck", "prop_pipe",
]


func _init() -> void:
	print("== 坦克：整车包围盒 vs 碰撞圆柱 ==")
	print("%-16s %6s %6s %6s | %6s %6s %6s" % [
		"KEY", "sizeX", "sizeY", "sizeZ", "r*2", "溢出X", "溢出Z"])
	for key in TANKS:
		var inst := Assets.instantiate(key)
		if inst == null:
			print("%-16s MISSING" % key)
			continue
		var a := _visual_aabb(inst)
		var d: float = float(TANKS[key]) * 2.0
		print("%-16s %6.2f %6.2f %6.2f | %6.2f %6.2f %6.2f" % [
			key, a.size.x, a.size.y, a.size.z, d,
			maxf(0.0, (a.size.x - d) * 0.5), maxf(0.0, (a.size.z - d) * 0.5)])
		inst.queue_free()

	print("")
	print("== 掩体 / 散布物：包围盒 vs 4.00 米格 ==")
	for key in BLOCKS:
		var m: Mesh = Assets.mesh_of(key)
		if m == null:
			print("%-16s MISSING" % key)
			continue
		var a := m.get_aabb()
		var over := "  <== 超出格子" if (a.size.x > 4.02 or a.size.z > 4.02) else ""
		print("%-16s %6.2f %6.2f %6.2f  minY=%5.2f%s" % [
			key, a.size.x, a.size.y, a.size.z, a.position.y, over])
	quit(0)


func _visual_aabb(root: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in _meshes(root):
		var a: AABB = mi.global_transform * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D and n.mesh != null:
		out.append(n)
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		out.append_array(_meshes(c))
	return out
