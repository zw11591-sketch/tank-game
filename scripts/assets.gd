class_name Assets
## 模型注册表：按 key 实例化 assets/models 下的 GLB，缺失则返回 null 由调用方回退图元。
##
## 之所以要有这一层，是为了让"美术资源"与"游戏能不能跑"彻底解耦：
## 删掉整个 assets/models 目录，游戏仍然用原来的 BoxMesh/CylinderMesh 正常开局，
## 只是观感回到改造前。资源管线坏掉不该让玩法停摆。
##
## 资源由 tools/build_assets.ps1 用无头 Blender 生成，键名即文件名（不含扩展名）。

const DIR := "res://assets/models/"

## 材质名约定（与 tools/blender/lib_build.py 的 PALETTE 一一对应）。
## 只有这两种会被阵营涂装覆写，金属/橡胶/玻璃保持 Blender 导出的 PBR 参数。
const MAT_PAINT := "M_Paint"
const MAT_ACCENT := "M_Accent"

## 车型 → 模型键。enemy.gd 的车型名与这里的键对齐。
const TANK_KEYS := {
	"player": "tank_player",
	"scout": "tank_scout",
	"medium": "tank_medium",
	"heavy": "tank_heavy",
	"artillery": "tank_artillery",
	"destroyer": "tank_destroyer",
	"boss": "tank_boss",
}

const BRICK_VARIANTS: Array[String] = ["wall_brick_a", "wall_brick_b", "wall_brick_c"]
const BRICK_DAMAGED: Array[String] = ["wall_brick_dmg_a", "wall_brick_dmg_b", "wall_brick_dmg_c"]
const STEEL_VARIANTS: Array[String] = ["wall_steel_a", "wall_steel_b"]
const WATER_KEY := "water_surface"
const BASE_KEY := "base_bunker"

## 散布道具。MultiMeshInstance3D 每个键一次 draw call，所以键越少越好。
const PROP_KEYS: Array[String] = [
	"prop_sandbags", "prop_barrel", "prop_ammocrate", "prop_hedgehog",
	"prop_rubble", "prop_deadtree", "prop_lamp", "prop_wire",
	"prop_wreck", "prop_pipe",
]

static var _scenes: Dictionary = {}     ## key -> PackedScene / null（null 表示确认缺失）
static var _meshes: Dictionary = {}     ## key -> Mesh / null
static var _block_meshes: Dictionary = {}   ## key -> 烘好节点变换、压进一格的方块网格


## 资源是否存在。调用方据此决定走模型还是走图元回退。
static func has_model(key: String) -> bool:
	return _load(key) != null


static func _load(key: String) -> PackedScene:
	if _scenes.has(key):
		return _scenes[key]
	var path := DIR + key + ".glb"
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = load(path) as PackedScene
	_scenes[key] = scene
	return scene


## 实例化模型根节点。缺失返回 null。
static func instantiate(key: String) -> Node3D:
	var scene := _load(key)
	if scene == null:
		return null
	return scene.instantiate() as Node3D


## 取模型里第一个网格资源。MultiMesh 与墙体都只需要网格本身，不需要整棵节点树。
static func mesh_of(key: String) -> Mesh:
	if _meshes.has(key):
		return _meshes[key]
	var mesh: Mesh = null
	var inst := instantiate(key)
	if inst != null:
		mesh = _first_mesh(inst)
		if mesh != null:
			mesh = mesh.duplicate() as Mesh      # 脱离场景，免得被 free 带走
		inst.queue_free()
	_meshes[key] = mesh
	return mesh


static func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and n.mesh != null:
		return n.mesh
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null


## 一格以内的视觉尺寸上限（m）。留 4% 余量给 `Arena._attach_block_model` 的
## ±3% 尺寸抖动，于是最大也只会顶到 3.96，不会探进相邻格。
## 数值与 Arena.CELL * 0.96 同源；写成字面量是为了不引入 Assets ↔ Arena 的循环依赖。
const BLOCK_FIT := 3.84


## 墙体 / 水面这类"整格方块"专用的网格：把 glTF 节点上的平移烘进顶点，
## 再把横向压进一格。
##
## 不能直接用 `mesh_of()`。它返回的是 glTF 里的**网格数据**，而墙面模型的原点
## 落在节点平移上：`wall_brick_*` 的网格数据沿 X 偏了约 1.95 m，`wall_steel_*`
## 沿 Y 抬了 2.2 m。`Arena._attach_block_model` 是按格子摆一个 MeshInstance3D 的，
## 它拿到的就是这个偏了位的网格数据——于是每一块砖墙都整体偏出碰撞格约半格，
## 屏幕上就是"坦克明明没动，墙却压在身上"（tools/steer_clip_probe.gd 的 clip 行：
## 1 格宽走廊两侧的墙面落在 x=2.48 / 1.63，而碰撞格边界是 2.0 / 2.0）。
##
## 烘进顶点之后还有第二件事：砖墙最外侧那两块砖各多出半块，整块宽 4.85 m，
## 而格子只有 4.0 m。横向按轴独立压到 `BLOCK_FIT`，砖的**高度和进深都不动**，
## 于是墙仍然填满整格、砖缝也还在，只是不再伸进旁边的通道。
##
## 原点统一成"底面中心"：横坐标居中、最低点 y=0，与 `_attach_block_model` 里
## `mi.position = -h * 0.5` 的约定一致，调用方不需要知道模型原本偏了多少。
static func block_mesh(key: String) -> Mesh:
	if _block_meshes.has(key):
		return _block_meshes[key]
	var out: Mesh = null
	var inst := instantiate(key)
	if inst != null:
		var mi := _first_mesh_instance(inst)
		if mi != null and mi.mesh != null:
			out = _bake_block_mesh(mi.mesh, _xform_under(inst, mi))
		inst.queue_free()
	_block_meshes[key] = out
	return out


static func _first_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and n.mesh != null:
		return n
	for c in n.get_children():
		var m := _first_mesh_instance(c)
		if m != null:
			return m
	return null


## node 相对 root 的变换（含 root 自己的变换）。glTF 的平移就挂在这一层。
static func _xform_under(root: Node, node: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		if n == root:
			break
		n = n.get_parent()
	return xf


## 把变换烘进顶点、横向压进一格、原点归到"底面中心"。
##
## 法线用逆转置矩阵变换后归一化：横向压缩不是等比变换，直接用 basis 会把
## 砖块侧面的法线压歪，光照就会显示成一道道亮边。
static func _bake_block_mesh(src: Mesh, xf: Transform3D) -> Mesh:
	var box: AABB = xf * src.get_aabb()
	var sx := minf(1.0, BLOCK_FIT / maxf(box.size.x, 0.001))
	var sz := minf(1.0, BLOCK_FIT / maxf(box.size.z, 0.001))
	var scale_b := Basis.from_scale(Vector3(sx, 1.0, sz))
	var basis := scale_b * xf.basis
	var placed: AABB = Transform3D(basis, scale_b * xf.origin) * src.get_aabb()
	var xform := Transform3D(basis, scale_b * xf.origin
			+ Vector3(-placed.get_center().x, -placed.position.y, -placed.get_center().z))
	var nrm := basis.inverse().transposed()

	var out := ArrayMesh.new()
	for i in src.get_surface_count():
		var arrays := src.surface_get_arrays(i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vi in verts.size():
			verts[vi] = xform * verts[vi]
		arrays[Mesh.ARRAY_VERTEX] = verts
		var raw_n = arrays[Mesh.ARRAY_NORMAL]
		if raw_n != null:
			var nrms: PackedVector3Array = raw_n
			for ni in nrms.size():
				nrms[ni] = (nrm * nrms[ni]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = nrms
		var raw_t = arrays[Mesh.ARRAY_TANGENT]
		if raw_t != null:
			var tang: PackedFloat32Array = raw_t
			for ti in range(0, tang.size(), 4):
				var tv := (basis * Vector3(tang[ti], tang[ti + 1], tang[ti + 2]))
				if tv.length_squared() > 1e-8:
					tv = tv.normalized()
				tang[ti] = tv.x
				tang[ti + 1] = tv.y
				tang[ti + 2] = tv.z
			arrays[Mesh.ARRAY_TANGENT] = tang
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(i, src.surface_get_material(i))
	return out


## 在子树里按名字找节点（Blender 侧的 Hull / Turret / Barrel / Muzzle / Wheel_*）。
## glTF 导入偶尔会给重名节点加后缀，所以用前缀匹配而非全等。
static func find_node(root: Node, prefix: String) -> Node3D:
	if root == null:
		return null
	for c in root.get_children():
		if c is Node3D and String(c.name).begins_with(prefix):
			return c
		var deep := find_node(c, prefix)
		if deep != null:
			return deep
	return null


## 收集名字以 prefix 开头的所有节点，按名字排序（Wheel_L0..n）。
static func find_all(root: Node, prefix: String) -> Array[Node3D]:
	var out: Array[Node3D] = []
	_collect(root, prefix, out)
	out.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return out


static func _collect(n: Node, prefix: String, out: Array[Node3D]) -> void:
	for c in n.get_children():
		if c is Node3D and String(c.name).begins_with(prefix):
			out.append(c)
		_collect(c, prefix, out)


# ---------------- 阵营涂装 ----------------

## 遍历子树的所有网格表面，把 M_Paint / M_Accent 两种材质换成本阵营的颜色。
## 其余材质（金属、橡胶、玻璃、帆布）原样保留 Blender 导出的 PBR 参数，
## 所以"涂装换色"不会把整台车刷成一个塑料色块。
##
## accent_energy > 0 时识别色块改为自发光。这是**可读性机制**而不是装饰：
## 自发光是加性的，于是同一个能量值在亮图上几乎看不出来（场景本身更亮），
## 在夜战这种暗图上却成了明确的信标——不必为每张地形单独调参，
## "敌人看得见"这件事就自动在十二张图上同时成立。
## 识别色块是炮塔顶盖（见 tools/blender/gen_tanks.py 的 turret_cap），
## 正好朝着第三人称相机，所以任何车体朝向下都看得到。
static func paint(root: Node, paint_col: Color, accent_col: Color,
		accent_energy := 0.0) -> void:
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			var target := Color.TRANSPARENT
			var glow := 0.0
			if _is_mat(src, MAT_PAINT):
				target = paint_col
			elif _is_mat(src, MAT_ACCENT):
				target = accent_col
				glow = accent_energy
			if target.a <= 0.0:
				continue
			var dup := src.duplicate() as BaseMaterial3D
			dup.albedo_color = target
			if glow > 0.0:
				dup.emission_enabled = true
				dup.emission = target
				dup.emission_energy_multiplier = glow
			mi.set_surface_override_material(i, dup)


## 单独改某种材质的自发光（基地按血量变色就靠这个）
static func tint_emission(root: Node, mat_name: String, col: Color, energy: float) -> void:
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mi.get_surface_override_material(i) as BaseMaterial3D
			if src == null:
				src = mesh.surface_get_material(i) as BaseMaterial3D
			if src == null or not _is_mat(src, mat_name):
				continue
			var dup := src.duplicate() as BaseMaterial3D
			dup.albedo_color = col
			dup.emission_enabled = energy > 0.0
			dup.emission = col
			dup.emission_energy_multiplier = energy
			mi.set_surface_override_material(i, dup)


## glTF 导入会把材质名放进 resource_name，但偶尔带 `_001` 之类的去重后缀
static func _is_mat(m: Material, name: String) -> bool:
	return String(m.resource_name).begins_with(name)


static func _all_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_collect_meshes(n, out)
	return out


static func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)


# ---------------- 杂项 ----------------

## 关掉整棵子树的阴影投射（水面、远景散布物用，省阴影 pass）
static func set_cast_shadow(n: Node, on: bool) -> void:
	for mi in _all_meshes(n):
		mi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)


## 构建报告用：当前有多少模型可用
static func available() -> int:
	var n := 0
	for k in TANK_KEYS.values():
		if has_model(k):
			n += 1
	for k in BRICK_VARIANTS + BRICK_DAMAGED + STEEL_VARIANTS + PROP_KEYS:
		if has_model(k):
			n += 1
	if has_model(WATER_KEY):
		n += 1
	if has_model(BASE_KEY):
		n += 1
	return n
