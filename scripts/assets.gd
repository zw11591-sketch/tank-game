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
## 涂装与坦克金属都走自定义 shader：两者都需要"世界高度泥污 + 顶点色 AO"，
## 而金属还需要把贴图里偏亮的钢色压回枪灰——否则在强光下整车金属件读成白塑料。
const MAT_PAINT := "M_Paint"
const MAT_ACCENT := "M_Accent"
const MAT_TANK_METAL := "M_TankMetal"
## 履带上/下支段。两者颜色一致，材质名只用来区分"该往哪个方向滚"。
const MAT_TRACK := "M_Track"
const MAT_TRACK_LOW := "M_TrackLow"

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
			_dress_world_mesh(mesh)
		inst.queue_free()
	_meshes[key] = mesh
	return mesh


## 战场道具统一"做旧"。
##
## 道具的 glTF 材质是纯色 PBR：砖、混凝土、帆布、锈铁在直射阳光下都会亮成
## 一整块高反射色板（截图里那些发白的箱子就是 M_Concrete）。墙体早就走
## 世界空间的 `_wall_material`，有窑变、流痕、墙根返潮与接触 AO；道具却仍是
## 原始色，于是同一张图上"墙是脏的、箱子是新的"，一眼看出是两套资源。
##
## 这里把道具的不透明表面也换成同一套世界空间材质。发光材质（尾灯、玻璃）
## 跳过：它们靠 emission 表达功能，不该被 weathering 的压暗抹掉。
static func _dress_world_mesh(mesh: Mesh) -> void:
	for i in mesh.get_surface_count():
		var src := mesh.surface_get_material(i) as BaseMaterial3D
		if src == null:
			continue
		if src.emission_enabled and src.emission_energy_multiplier > 0.01:
			continue
		mesh.surface_set_material(i, _wall_material(src))


static func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and n.mesh != null:
		return n.mesh
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null


## 一格以内的视觉尺寸上限（m）。留 1% 余量给 `Arena._attach_block_primitive` 的
## ±3% 尺寸抖动……但抖动只作用于横向缩放，最大值仍是 3.97。
## 4.0 的格子如果只铺 3.84，相邻两块墙之间会留下 16 cm 的缝——相机一压低，
## 那排缝就是"一堵墙被切成了一排砖托盘"最直接的证据。贴到 3.97 之后
## 相邻墙块真正拼上，而 3 cm 的余量仍足以避免两格网格互相穿插。
const BLOCK_FIT := 3.97


## 墙体 / 水面这类"整格方块"专用的网格：把 glTF 节点上的平移烘进顶点，
## 再把横向压进一格。
##
## 不能直接用 `mesh_of()`。它返回的是 glTF 里的**网格数据**，而墙面模型的原点
## 落在节点平移上：`wall_brick_*` 的网格数据沿 X 偏了约 1.95 m，`wall_steel_*`
## 沿 Y 抬了 2.2 m。`Arena._attach_block_primitive` 是按格子摆一个 MeshInstance3D 的，
## 它拿到的就是这个偏了位的网格数据——于是每一块砖墙都整体偏出碰撞格约半格，
## 屏幕上就是"坦克明明没动，墙却压在身上"（tools/steer_clip_probe.gd 的 clip 行：
## 1 格宽走廊两侧的墙面落在 x=2.48 / 1.63，而碰撞格边界是 2.0 / 2.0）。
##
## 烘进顶点之后还有第二件事：砖墙最外侧那两块砖各多出半块，整块宽 4.85 m，
## 而格子只有 4.0 m。横向按轴独立压到 `BLOCK_FIT`，砖的**高度和进深都不动**，
## 于是墙仍然填满整格、砖缝也还在，只是不再伸进旁边的通道。
##
## 原点统一成"底面中心"：横坐标居中、最低点 y=0，与 `_attach_block_primitive` 里
## `mi.position = -h * 0.5` 的约定一致，调用方不需要知道模型原本偏了多少。
static func block_mesh(key: String) -> Mesh:
	if _block_meshes.has(key):
		return _block_meshes[key]
	var out: Mesh = null
	var inst := instantiate(key)
	if inst != null:
		var mi := _first_mesh_instance(inst)
		if mi != null and mi.mesh != null:
			out = _bake_block_mesh(mi.mesh, _xform_under(inst, mi), 0.0)
		inst.queue_free()
	_block_meshes[key] = out
	return out


## 连续墙段用的"整格瓦片"：与 `block_mesh` 同一份模型，但横向按**格子名义宽度**
## 精确铺满（不是压到 `BLOCK_FIT` 留缝），且不做任何逐格抖动。
##
## 砖块的砌筑是按每格 6 列切的，两端各留半块砖，所以两块瓦片首尾相接时
## 半块 + 半块正好补成一整块（`gen_walls.py` 的 `_brick_courses` 按剩余宽度裁砖）。
## 沿 +X 按 CELL 平铺 N 次，砖缝、压顶石与墓缝都跨过格界连续，一面 12 m 的墙
## 才读成一堵墙，而不是三块各自收边的积木。
static func block_tile(key: String, width := 4.0) -> Mesh:
	if _block_tiles.has(key):
		return _block_tiles[key]
	var out: Mesh = null
	var inst := instantiate(key)
	if inst != null:
		var mi := _first_mesh_instance(inst)
		if mi != null and mi.mesh != null:
			out = _bake_block_mesh(mi.mesh, _xform_under(inst, mi), width)
		inst.queue_free()
	_block_tiles[key] = out
	return out

static var _block_tiles: Dictionary = {}


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
##
## target_w > 0 时横向按这个精确宽度缩放（连续墙段用 4.0，保证首尾相接无缝、
## 无重叠）；为 0 时走原来的 `BLOCK_FIT` 单人块路径。
static func _bake_block_mesh(src: Mesh, xf: Transform3D, target_w: float) -> Mesh:
	var box: AABB = xf * src.get_aabb()
	var sx := 1.0
	var sz := 1.0
	if target_w > 0.0:
		sx = target_w / maxf(box.size.x, 0.001)
	else:
		# 允许向上放大 3.5%：墙块模型的标称宽度是 3.92 m，只允许缩小的话
		# BLOCK_FIT 再大也填不满 4.0 m 的格子，相邻墙块之间会永远留 8 cm 缝。
		# 上限 1.035 只是把 3.92 拉到 3.97，模型件本身的横向抖动仍有余量。
		sx = clampf(BLOCK_FIT / maxf(box.size.x, 0.001), 0.0, 1.035)
		sz = clampf(BLOCK_FIT / maxf(box.size.z, 0.001), 0.0, 1.035)
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
		out.surface_set_material(i, _wall_material(src.surface_get_material(i) as BaseMaterial3D))
	return out


## 墙体/道具的"风化层"。
##
## Blender 导出的墙只有纯色 PBR（砖色 / 砂浆 / 压顶石），同一面 4 m 见方的墙
## 从上到下是一个色块；相机一压低，墙面就只剩一排横向亮边。这里不重做模型，
## 而是在材质上叠四层世界空间信息：大尺度窑变色差、竖向雨水流痕、墙根返潮、
## 顶面苔藓。它们都按世界坐标取样，所以换格、换朝向都不会出现同一张图案。
static func _wall_material(src: BaseMaterial3D) -> Material:
	if src == null:
		return null
	if _wall_mat_cache.has(src):
		return _wall_mat_cache[src]
	if _wall_shader == null:
		_wall_shader = Shader.new()
		_wall_shader.code = _WALL_SHADER
	var sm := ShaderMaterial.new()
	sm.shader = _wall_shader
	sm.set_shader_parameter("base_color", src.albedo_color)
	sm.set_shader_parameter("roughness_value", src.roughness)
	sm.set_shader_parameter("metallic_value", src.metallic)
	_wall_mat_cache[src] = sm
	return sm


static var _wall_shader: Shader
static var _wall_mat_cache: Dictionary = {}

const _WALL_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.3, 0.2, 0.16, 1.0);
uniform float roughness_value = 0.9;
uniform float metallic_value = 0.0;
uniform float weather = 1.0;

varying vec3 wpos;
varying vec3 wnrm;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(13.0, 7.0);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 col = base_color.rgb * mix(vec3(1.0), COLOR.rgb, 0.75);

	// 大尺度窑变 + 中频斑驳：同一面墙不再是一个色块
	float n1 = fbm(vec2(wpos.x + wpos.z, wpos.y) * 0.65);
	float n2 = fbm(wpos.xz * 2.4 + wpos.y * 1.3 + 5.0);
	col *= 0.82 + 0.34 * n1;
	col *= 0.92 + 0.16 * n2;

	// 竖向雨水痕：只出现在立面上，墙顶不会"挂水"
	float vert = 1.0 - abs(wnrm.y);
	float streak = smoothstep(0.58, 0.90,
			fbm(vec2((wpos.x + wpos.z) * 3.2, wpos.y * 0.22)));
	col *= 1.0 - streak * 0.20 * vert * smoothstep(0.05, 3.0, wpos.y);

	// 墙根返潮：下 1.5 m 偏暗偏绿，和地面接触不再是一条硬边
	float low = smoothstep(1.55, 0.02, wpos.y);
	col = mix(col, col * vec3(0.58, 0.64, 0.52), low * 0.55 * weather);

	// 顶面苔藓：朝上的面才长，且用噪声成片出现
	float up = smoothstep(0.35, 0.85, wnrm.y);
	float moss = smoothstep(0.56, 0.84, fbm(wpos.xz * 3.1 + 13.0)) * up;
	col = mix(col, vec3(0.125, 0.150, 0.080), moss * 0.45 * weather);

	ALBEDO = col;
	ROUGHNESS = clamp(roughness_value + (1.0 - n2) * 0.06, 0.0, 1.0);
	METALLIC = metallic_value;
	// 接触遮蔽：墙根压暗，物件不再像浮在地面上
	AO = mix(0.66, 1.0, smoothstep(0.0, 2.1, wpos.y));
	AO_LIGHT_AFFECT = 0.25;
}
"""


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
		accent_energy := 0.0, readability := 0.035, edge := 0.0) -> void:
	# 车体的"金属"在 Blender 里是没指定材质的默认件（hull_main、首下、侧裙、
	# 翼子板、工具箱都落在它上面），它们其实是**同一套涂装覆盖的装甲钢板**。
	# 所以这里复用车上 M_Paint 的迷彩明度图，而不是那张烘死了钢色的贴图——
	# 阵营色乘上去之后，整车才是一台车，而不是"绿车壳贴了几块灰白板"。
	var paint_tex := _paint_albedo(root)
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			# 涂装走自定义 shader：贴图给迷彩与焊缝，shader 再叠世界高度泥污、
			# 顶点色 AO 与低频流痕。原来的做法只是把 albedo_color 乘上去，
			# 车底和车顶一样干净，模型看起来就是"刚拆封的塑料件"。
			if _is_mat(src, MAT_PAINT):
				mi.set_surface_override_material(i,
						_paint_material(src, paint_col, 0.72, 0.42, 1.0, null,
								readability, edge))
				continue
			# 车体上所谓"金属"其实是被涂装覆盖的装甲钢板：hull_main、首下装甲、
			# 侧裙、翼子板、工具箱在 Blender 里都没有显式材质，于是全部落在
			# M_Metal → M_TankMetal 上。这里原来乘的是 0.56 的枪灰，结果整车
			# 有一半面积是"浅灰塑料板"，比迷彩车体亮两档——车库截图里最显眼的
			# 那几块白板就是它们。
			#
			# 改成乘阵营色（再压一档）：钢色贴图里的轧制纹、焊缝、划痕与锈斑
			# 仍然保留，但明度与涂装面对齐，只比涂装面脏一点、暗一点。
			# metal_scale = 0.22 把金属度从 0.35 压到接近介质：装甲钢是刷了漆的，
			# 不该像裸金属那样整面反射天空。
			if _is_mat(src, MAT_TANK_METAL):
				mi.set_surface_override_material(i,
						_paint_material(src, paint_col.darkened(0.06), 0.62, 0.18, 0.22,
								paint_tex, readability, edge))
				continue
			# 尾灯：Blender 里给了自发光，远看能读出车尾朝向；但 glTF 的自发光
			# 强度在 ACES 与辉光下会被放大成两块霓虹橙方块，抢走整个车尾的注意力。
			# 这里只留一点"灯还亮着"的暗红，不再当发光体处理。
			if _is_mat(src, "M_TailLight"):
				var tail := src.duplicate() as BaseMaterial3D
				# 车尾灯只剩"暗红玻璃"：0.32 的自发光经 ACES + 泛光后
				# 是两块糊成橙白色的光斑，比车体本身还抢眼。尾灯只需要
				# 在近处读出颜色，不需要当光源。
				tail.albedo_color = Color(0.085, 0.014, 0.011)
				tail.emission_enabled = false
				tail.emission_energy_multiplier = 0.0
				tail.roughness = 0.55
				mi.set_surface_override_material(i, tail)
				continue
			# 玻璃原来是浅蓝金属漆，在日光下反成两块白板。收成暗蓝灰玻璃。
			if _is_mat(src, "M_Glass"):
				var glass := src.duplicate() as BaseMaterial3D
				glass.albedo_color = Color(0.055, 0.070, 0.082)
				glass.metallic = 0.10
				glass.roughness = 0.22
				mi.set_surface_override_material(i, glass)
				continue
			var target := Color.TRANSPARENT
			var glow := 0.0
			if _is_mat(src, MAT_ACCENT):
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


## 取车上 M_Paint 的迷彩明度图。
##
## M_TankMetal 的贴图把钢色烘进了 albedo（见 tools/blender/lib_tex.py），
## 乘上阵营色之后只会得到一块更暗的灰，永远对不上迷彩车体。金属件在真车上
## 本来就是同一套涂装覆盖的装甲钢板，所以直接复用涂装贴图；法线仍用金属那张，
## 焊缝、轧制纹与划痕因此都还在。
static func _paint_albedo(root: Node) -> Texture2D:
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as BaseMaterial3D
			if src != null and _is_mat(src, MAT_PAINT) and src.albedo_texture != null:
				return src.albedo_texture
	return null


## M_Paint 的替代材质。albedo / normal / ORM 三张图原样带过来，
## 再在 shader 里叠三层信息：世界高度泥污、顶点色 AO、低频流痕。
static func _paint_material(src: BaseMaterial3D, col: Color,
		dirt := 0.72, rim := 0.42, metal_scale := 1.0,
		albedo_override: Texture2D = null, readability := 0.035,
		edge := 0.0) -> ShaderMaterial:
	if _paint_shader == null:
		_paint_shader = Shader.new()
		_paint_shader.code = _PAINT_SHADER
	var sm := ShaderMaterial.new()
	sm.shader = _paint_shader
	sm.set_shader_parameter("paint_color", col)
	sm.set_shader_parameter("uv_scale", Vector2(src.uv1_scale.x, src.uv1_scale.y))
	sm.set_shader_parameter("uv_offset", Vector2(src.uv1_offset.x, src.uv1_offset.y))
	sm.set_shader_parameter("dirt_amount", dirt)
	sm.set_shader_parameter("rim_strength", rim)
	sm.set_shader_parameter("metal_scale", metal_scale)
	sm.set_shader_parameter("readability", readability)
	sm.set_shader_parameter("edge_glow", edge)
	var albedo_tex: Texture2D = albedo_override if albedo_override != null else src.albedo_texture
	if albedo_tex != null:
		sm.set_shader_parameter("albedo_tex", albedo_tex)
	if src.normal_texture != null:
		sm.set_shader_parameter("normal_tex", src.normal_texture)
		sm.set_shader_parameter("use_normal", 1.0)
	if src.orm_texture != null:
		sm.set_shader_parameter("orm_tex", src.orm_texture)
		sm.set_shader_parameter("use_orm", 1.0)
	sm.set_shader_parameter("roughness_value", src.roughness)
	sm.set_shader_parameter("metallic_value", src.metallic)
	return sm


static var _paint_shader: Shader

const _PAINT_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 paint_color : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_tex : filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform float use_normal = 0.0;
uniform float use_orm = 0.0;
uniform float roughness_value = 0.58;
uniform float metallic_value = 0.1;
uniform float dirt_amount = 0.7;
// 金属度倍率。涂装面是介质，钢件也不是裸金属：glTF 的 metallicFactor 在
// "贴图存在"时会被导出成 1.0，直接 mix 进来会让整车 45% 金属度，
// 于是天空反射把车体洗成一片浅灰。0.22 只给金属件留一点高光。
uniform float metal_scale = 1.0;
// 边缘光：环境光压低之后，车体与背景亮度接近，轮廓靠它挑出来。
// 用菲涅耳而不是再加一盏灯——每辆车都加光会在近战堆车时把帧率吃光。
// RIM_TINT 是 0..1 的混合量（0=白，1=反照率），不是颜色。
uniform float rim_strength = 0.42;
uniform float rim_tint_mix = 0.22;
// 可读性底光：与光照无关的最低亮度。做成 uniform 是因为十二张图的环境亮度
// 差了三倍以上，固定 0.035 在夜战图上不够用（实测敌车 45 m 处只剩 0.125，
// 判据 0.20）。敌人按地形取更高的值，玩家车保持 0.035。
uniform float readability = 0.035;
// 轮廓描边：只在掠射角（也就是车体剪影边缘）上加一层冷色。
// 这是给敌车"描边"用的，不是给整车打灯——见 fragment() 末尾。
uniform float edge_glow = 0.0;
uniform vec3 edge_color : source_color = vec3(0.58, 0.74, 0.94);

varying float world_h;
varying vec3 lpos;
varying vec3 lnrm;

void vertex() {
	world_h = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	lpos = VERTEX;
	lnrm = NORMAL;
}

void fragment() {
	vec2 uv = UV * uv_scale + uv_offset;
	vec3 base = texture(albedo_tex, uv).rgb * paint_color.rgb;

	// ---- 泥污：车体局部空间的三平面取样 ----
	//
	// 原来按 UV 拉流痕，污渍于是跟着贴图走：车体一转，脏的位置纹丝不动，
	// 而且换个车型（UV 布局不同）就是另一套污渍分布。改成在**车体局部坐标**
	// 里取三平面噪声之后，脏的位置长在车身上——停车、转向、绕圈都不变——
	// 也不再依赖每个模型的 UV。
	//
	// 高度仍取世界 Y：本作战场地面是平的（y = 0），世界 Y 就是离地高度；
	// 用局部 Y 会被炮塔、炮管各自节点的原点带偏，车顶反而判成车底。
	vec3 p = lpos * 0.62;
	vec3 wgt = pow(abs(normalize(lnrm)), vec3(4.0));
	wgt /= max(wgt.x + wgt.y + wgt.z, 0.001);
	float grime = texture(albedo_tex, p.yz + vec2(0.37, 0.11)).r * wgt.x
			+ texture(albedo_tex, p.xz + vec2(0.71, 0.43)).r * wgt.y
			+ texture(albedo_tex, p.xy + vec2(0.13, 0.83)).r * wgt.z;
	// 竖向流痕：横向频率远高于纵向，泥顺着装甲板往下淌
	float streak = texture(albedo_tex, vec2((lpos.x + lpos.z) * 0.9, world_h * 0.16)).r;
	float low = 1.0 - smoothstep(0.05, 1.35, world_h);
	float mud = clamp(low * dirt_amount * (0.35 + 1.05 * grime) * (0.72 + 0.55 * streak),
			0.0, 0.88);
	base = mix(base, vec3(0.135, 0.105, 0.074), mud);

	// 顶面积尘：朝上的面落一层灰。车顶不必和车底一样脏，但也不该像刚出厂。
	float dust = smoothstep(0.45, 0.95, normalize(lnrm).y) * (0.35 + 0.65 * grime);
	base = mix(base, vec3(0.285, 0.262, 0.225), dust * 0.16);

	// 顶点色是 Blender 烘的 dirt：它本来被当成 albedo 直接压暗，
	// 这里改当 AO 用，凹陷有阴影、凸边仍然受光。
	// 0.45 而不是 0.62：0.62 会把整车的入射光再打七折，45 米外的敌车
	// 在要塞/夜战图上就会掉到可读性下限以下（tools/vis_probe.gd 的 enemyLum）。
	float vao = mix(1.0, COLOR.r, 0.45);
	ALBEDO = base * vao;

	if (use_normal > 0.5) {
		NORMAL_MAP = texture(normal_tex, uv).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
	if (use_orm > 0.5) {
		vec3 orm = texture(orm_tex, uv).rgb;
		ROUGHNESS = mix(roughness_value, orm.g, 0.85) + mud * 0.10;
		METALLIC = mix(metallic_value, orm.b, 0.85) * (1.0 - mud * 0.6) * metal_scale;
	} else {
		ROUGHNESS = roughness_value + mud * 0.10;
		METALLIC = metallic_value * (1.0 - mud * 0.6) * metal_scale;
	}
	AO = vao;
	AO_LIGHT_AFFECT = 0.25;

	// 可读性底光：不是风格化自发光，而是给"背光面"一个与光照无关的最低亮度。
	// 没有它，夜战/回廊这类图的阴影面会整块压进背景，敌车只剩一个轮廓。
	EMISSION = base * readability;

	// 轮廓描边。用高次菲涅耳把亮度压到剪影边缘的 1~2 像素上：
	// 车体内部仍然是正常的涂装明度，边缘却比背景亮一档，敌车于是"被描出来"
	// 而不是"像一块灯箱"。
	//
	// power 不能低：低机位下整个车顶都是掠射面（cos ≈ 0.17），7 次幂会让
	// 车顶整片泛蓝，读成"金属漆"而不是"轮廓"。14 次幂把同一块顶面的贡献
	// 压到 1/4，而剪影处（cos → 0）仍然打满。
	float edge = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 14.0);
	EMISSION += edge_color * edge * edge_glow;

	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.2);
	RIM = rim_strength * fres;
	RIM_TINT = rim_tint_mix;
}
"""


## 给履带表面挂"滚动带纹"材质，返回需要每帧更新 scroll 的材质数组。
##
## 履带板在 Blender 里已经并进车体网格，不能单独平移；最低成本的修法是
## 让 shader 沿车身长度方向画周期性的带纹并滚动它。上支段与下支段
## 差一个负号，于是车往前走时两条带子朝相反方向跑，而不是整块黑条一起滑。
static func apply_track_shader(root: Node) -> Array:
	if _track_shader == null:
		_track_shader = Shader.new()
		_track_shader.code = _TRACK_SHADER
	var out: Array = []
	for mi in _all_meshes(root):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			var sign := 0.0
			if _is_mat(src, MAT_TRACK):
				sign = 1.0
			elif _is_mat(src, MAT_TRACK_LOW):
				sign = -1.0
			if sign == 0.0:
				continue
			var sm := ShaderMaterial.new()
			sm.shader = _track_shader
			sm.set_shader_parameter("track_color", src.albedo_color)
			sm.set_shader_parameter("scroll", 0.0)
			sm.set_meta("track_sign", sign)
			# 这一块履带在车体的哪一侧（-1 左 / +1 右 / 0 跨中线）。
			# 原地转向时左右履带反向滚动，没有这个标记就只能整车共用一个速度，
			# 于是"车在转、履带不动"——转向看起来像镜头在转而不是车在转。
			#
			# 履带件在 GLB 里已经被合并进 HullMesh，按节点位置分不出左右，
			# 所以按这一层表面的顶点质心取横向坐标。这个量只与几何有关，
			# 在加载时算一次就够（每辆车一次，几百个顶点）。
			var sx := mi.position.x
			var arr := mesh.surface_get_arrays(i)
			if arr.size() > Mesh.ARRAY_VERTEX:
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				if verts.size() > 0:
					var acc := 0.0
					for v in verts:
						acc += v.x
					sx += acc / float(verts.size())
			sm.set_meta("track_side", -1.0 if sx < -0.05 else (1.0 if sx > 0.05 else 0.0))
			out.append(sm)
			mi.set_surface_override_material(i, sm)
	return out


static var _track_shader: Shader

const _TRACK_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 track_color : source_color = vec4(0.05, 0.05, 0.055, 1.0);
uniform float scroll = 0.0;
uniform float pitch = 0.155;

varying float local_z;

void vertex() {
	local_z = VERTEX.z;
}

void fragment() {
	float f = fract((local_z + scroll) / pitch);
	// 履带板：中间平、两端有销孔暗缝。比 uniform 色条更像一条履带。
	float plate = smoothstep(0.02, 0.12, f) * (1.0 - smoothstep(0.80, 0.98, f));
	float pin = smoothstep(0.88, 0.97, f) * (1.0 - smoothstep(0.97, 1.0, f));
	vec3 col = track_color.rgb * (0.55 + 0.65 * plate);
	col += vec3(0.035, 0.032, 0.030) * pin;
	ALBEDO = col;
	ROUGHNESS = 0.90;
	METALLIC = 0.22;
}
"""


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
