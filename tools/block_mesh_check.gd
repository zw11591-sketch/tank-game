extends SceneTree
## 临时验收：`Assets.block_mesh()` 烘出来的方块网格是否真的落在一格之内、
## 且原点在底面中心（横坐标居中、最低点 y=0）。
##
## 用法：godot --headless --path <proj> --script res://tools/block_mesh_check.gd

const KEYS := [
	"wall_brick_a", "wall_brick_b", "wall_brick_c",
	"wall_brick_dmg_a", "wall_brick_dmg_b", "wall_brick_dmg_c",
	"wall_steel_a", "wall_steel_b", "water_surface",
]


func _init() -> void:
	for key in KEYS:
		var m: Mesh = Assets.block_mesh(key)
		if m == null:
			print("PROBE block %-18s MISSING" % key)
			continue
		var a := m.get_aabb()
		var fits := a.size.x <= Arena.CELL and a.size.z <= Arena.CELL
		print("PROBE block %-18s size=(%.2f, %.2f, %.2f) min=(%.2f, %.2f, %.2f) fits=%s" % [
			key, a.size.x, a.size.y, a.size.z,
			a.position.x, a.position.y, a.position.z, str(fits)])
	quit(0)
