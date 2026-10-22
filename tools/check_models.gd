extends SceneTree
## 模型契约校验（开发期，不参与导出——tools/* 已在 export_presets 的 exclude_filter 里）。
##
## 把 assets/models 下的每台车都实例化一遍，核对 tank.gd 依赖的那份节点契约：
## Hull / Turret / Barrel / Muzzle 齐不齐、负重轮是不是左右成对。缺任何一个，
## tank.gd 会 push_warning 并释放整台车退回图元——游戏照样能跑，观感却悄悄回到方块。
## 那种退化不会报错、不掉帧，只能靠这个脚本在构建后立刻发现。
##
## 顺带统计三角面数与材质名：面数用来对照 build_all.py 的预算，
## 材质名用来确认 M_Paint / M_Accent 仍在（阵营涂装只认这两个名字，
## 改名会让"换色"整条链路静默失效）。
##
## 运行： godot.exe --headless --path . --script res://tools/check_models.gd

## 单侧可滚动行走轮的数量：负重轮 + 诱导轮 + 主动轮 + 2 个托带轮。
## 负重轮真值来自 tools/blender/dims.py 的 TANKS 表；后三者每侧各一个/两个。
## 侦察车是轮式底盘，没有履带环，所以没有这三个附加轮。
const WHEELS := {
	"tank_player": 10, "tank_scout": 4, "tank_medium": 10, "tank_heavy": 11,
	"tank_artillery": 10, "tank_destroyer": 10, "tank_boss": 12,
}

const VERTS := ["Hull", "Turret", "Barrel", "Muzzle"]


func _initialize() -> void:
	var fail := 0
	print("车型            面数   材质                     贴图   缺失项")
	print("--------------------------------------------------------------")
	for key in Assets.TANK_KEYS.values():
		fail += _check(String(key))
	print("--------------------------------------------------------------")
	print("共 %d 台车，%d 项不合格" % [Assets.TANK_KEYS.size(), fail])
	quit(1 if fail > 0 else 0)


func _check(key: String) -> int:
	var inst := Assets.instantiate(key)
	if inst == null:
		print("%-15s 模型缺失（游戏会退回图元，仍可玩）" % key)
		return 1

	var missing: Array[String] = []
	for v in VERTS:
		if Assets.find_node(inst, v) == null:
			missing.append(v)
	var want: int = int(WHEELS.get(key, 0))
	for side in ["Wheel_L", "Wheel_R"]:
		var got := Assets.find_all(inst, side).size()
		if got != want:
			missing.append("%s%d/%d" % [side, got, want])

	var mats := _materials(inst)
	var tris := _triangles(inst)
	var tex := _textured_surfaces(inst)
	inst.free()

	print("%-15s %6d   %-24s %-6s %s" % [
		key, tris, ", ".join(mats), "%d/%d" % [tex[0], tex[1]],
		"—" if missing.is_empty() else ", ".join(missing),
	])
	return missing.size()


## 贴图接上了没有：有 albedo 贴图的表面数 / 总表面数。
##
## 这一列是防"静默退化"的：贴图丢了以后材质名、节点、面数全都照旧，
## 只是车体回到纯色——除了看画面没有任何一处会报错。M_Paint 是明度细节图，
## 它一旦缺失，阵营涂装仍然生效，所以连"颜色不对"这个线索都没有。
func _textured_surfaces(root: Node) -> Array[int]:
	var have := 0
	var total := 0
	for mi in _meshes(root):
		var m := mi.mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			total += 1
			var mat := m.surface_get_material(s) as BaseMaterial3D
			if mat != null and mat.albedo_texture != null:
				have += 1
	return [have, total]


func _triangles(root: Node) -> int:
	var n := 0
	for mi in _meshes(root):
		var m := mi.mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			var arr := m.surface_get_arrays(s)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			n += (idx.size() / 3) if idx.size() > 0 else (verts.size() / 3)
	return n


## 只看表面材质名，不关心它挂在哪个网格上：涂装靠名字匹配。
func _materials(root: Node) -> Array[String]:
	var out: Array[String] = []
	for mi in _meshes(root):
		var m := mi.mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			var mat := m.surface_get_material(s)
			if mat != null:
				var nm := String(mat.resource_name)
				if not out.has(nm):
					out.append(nm)
	out.sort()
	return out


func _meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_collect(root, out)
	return out


func _collect(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)
