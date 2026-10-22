class_name PowerUp
extends Node3D
## 空投补给：敌人被击毁后随机掉落，玩家开过去即可拾取。
## 用悬浮旋转的发光箱体表示，箱体颜色与顶部标记对应不同增益。

enum Type { REPAIR, ARMOR, RAPID, SHIELD, AIRSTRIKE, FORTIFY, FIREPOWER, MULTISHOT, OVERDRIVE }

const LIFE := 22.0
## 定时空投的存在时间更长：它出现在场地深处，玩家需要时间绕过去
const FIELD_LIFE := 38.0
const PICK_RANGE := 3.4

var game: Node
var ptype := Type.REPAIR
## 定时空投（true）与击杀掉落（false）。只影响存在时间与落地提示的强度。
var from_field := false
## 联机 id：房主分配，客户端按它把"已拾取"事件对回这只箱子。
var uid := 0
## 客户端上的补给是纯表现：不能被本机拾取，消失由房主事件驱动。
var visual_only := false

var _t := 0.0
var _span := LIFE
var _mat: StandardMaterial3D
var _core: MeshInstance3D
var _light: OmniLight3D
var _beacon: MeshInstance3D


static func info(t: int) -> Dictionary:
	match t:
		Type.REPAIR:
			return {"name": "维修包", "desc": "恢复 45% 结构", "color": Color(0.35, 0.95, 0.45)}
		Type.ARMOR:
			return {"name": "附加装甲", "desc": "20 秒内受伤 -40%", "color": Color(0.55, 0.7, 1.0)}
		Type.RAPID:
			return {"name": "快速装填", "desc": "20 秒内装填提速 80%", "color": Color(1.0, 0.8, 0.25)}
		Type.SHIELD:
			return {"name": "能量护盾", "desc": "8 秒完全免伤", "color": Color(0.4, 0.9, 1.0)}
		Type.AIRSTRIKE:
			return {"name": "空中支援", "desc": "全场敌人受到重创", "color": Color(1.0, 0.4, 0.2)}
		Type.FORTIFY:
			return {"name": "基地加固", "desc": "25 秒钢制围墙", "color": Color(0.75, 0.78, 0.85)}
		Type.MULTISHOT:
			return {"name": "多弹装填", "desc": "22 秒内每次击发三连射", "color": Color(1.0, 0.6, 0.15)}
		Type.OVERDRIVE:
			return {"name": "引擎过载", "desc": "20 秒内机动 +35%", "color": Color(0.4, 1.0, 0.8)}
		_:
			return {"name": "火力强化", "desc": "本关伤害 +25%", "color": Color(1.0, 0.45, 0.75)}


func _ready() -> void:
	_span = FIELD_LIFE if from_field else LIFE
	var col: Color = info(ptype)["color"]
	# 颜色编码分两层：
	#   * 箱体本身是深橄榄绿的军用补给箱，靠金属与粗糙度读出体积；
	#   * 颜色只出现在一圈识别带、顶部信标和贴地光环上。
	# 原来整只箱子都是 2.2 自发光的纯色，三个面亮度一样、没有明暗交界，
	# 远看就是一块悬空的发光卡片——正是"发光立方体像占位符"的来源。
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = col
	_mat.emission_enabled = true
	_mat.emission = col
	_mat.emission_energy_multiplier = 1.9
	_mat.metallic = 0.2
	_mat.roughness = 0.45

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.135, 0.145, 0.105)
	body_mat.metallic = 0.35
	body_mat.roughness = 0.62

	_core = MeshInstance3D.new()
	# 补给箱造型：箱体 + 两道钢带，而不是一个边长 1.5 m 的纯色立方体。
	# 发光交给材质与点光，形状仍然要是"军用补给箱"，远看才不像渲染 bug。
	var b := BoxMesh.new()
	b.size = Vector3(1.28, 0.96, 0.84)
	_core.mesh = b
	_core.material_override = body_mat
	_core.position = Vector3(0, 1.6, 0)
	add_child(_core)
	var strap_mat := StandardMaterial3D.new()
	strap_mat.albedo_color = Color(0.10, 0.10, 0.11)
	strap_mat.metallic = 0.7
	strap_mat.roughness = 0.45
	for sx in [-1, 1]:
		var strap := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.10, 1.02, 0.90)
		strap.mesh = sm
		strap.material_override = strap_mat
		strap.position = Vector3(sx * 0.36, 0, 0)
		_core.add_child(strap)
		var latch := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.16, 0.10, 0.06)
		latch.mesh = lm
		latch.material_override = strap_mat
		latch.position = Vector3(sx * 0.36, 0.20, 0.45)
		_core.add_child(latch)

	# 箱体中段的识别带：颜色编码集中在这一圈，箱体的受光/背光面仍然读得出体积
	var band := MeshInstance3D.new()
	var band_mesh := BoxMesh.new()
	band_mesh.size = Vector3(1.31, 0.20, 0.87)
	band.mesh = band_mesh
	band.material_override = _mat
	band.position = Vector3(0, 0.02, 0)
	_core.add_child(band)

	# 顶部信标：一颗小而亮的光点，远处先看到它，再看到箱子
	var strobe := MeshInstance3D.new()
	var stm := SphereMesh.new()
	stm.radius = 0.085
	stm.height = 0.17
	stm.radial_segments = 10
	stm.rings = 5
	strobe.mesh = stm
	strobe.material_override = _mat
	strobe.position = Vector3(0, 0.57, 0)
	_core.add_child(strobe)

	# 底部光环，远处也能看见掉落位置。
	# 用一张径向渐变贴地片而不是 TorusMesh：圆环在低机位下会被压成一条
	# 亮线，远看像画面上多了一道 UI 描边；径向片从中心向外连续衰减，
	# 才读得出"这里有一片光落在地上"。
	var ring := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(3.4, 3.4)
	ring.mesh = q
	ring.rotation.x = -PI * 0.5
	ring.position = Vector3(0, 0.06, 0)
	ring.material_override = _glow_material(col)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)

	_light = OmniLight3D.new()
	_light.light_color = col
	_light.light_energy = 2.5
	_light.omni_range = 10.0
	_light.position = Vector3(0, 2.0, 0)
	add_child(_light)

	# 空投补给加一道竖直光柱：它落在场地深处，没有光柱根本看不见。
	# 原来的实心自发光圆柱是硬边 + 均匀亮度，截图里像两根灯管；
	# 后来改成菲涅耳边缘发光，结果把柱心挖空了——只剩轮廓两侧的两条亮线，
	# 在低机位下细得像一道激光。这里按"视线穿过柱体的路径长度"来给不透明度：
	# 柱心最厚、轮廓最薄，柱体才是一只装光的容器，而不是一根线。
	if from_field:
		_beacon = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.50
		cm.bottom_radius = 1.15
		cm.height = 13.0
		cm.radial_segments = 28
		cm.rings = 6
		_beacon.mesh = cm
		_beacon.position = Vector3(0, 6.5, 0)
		_beacon.material_override = _beam_material(col)
		_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_beacon)


## 光柱材质：加法混合、不写深度、只画正面。
## 双面加法会让前后两层叠加，在轮廓处叠出一条硬边，所以必须单面。
static func _beam_material(col: Color) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;

uniform vec4 beam_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float intensity = 1.0;

void fragment() {
	float v = UV.y;
	// 上下两端都要落到 0：柱底不能在地面上切出一刀，柱顶不能凭空断掉
	float fade = smoothstep(0.0, 0.12, v) * (1.0 - smoothstep(0.52, 1.0, v));
	// 圆柱法线与视线的夹角在轴线处最小（N 与 V 同向），在轮廓处最大。
	// 视线穿过的柱体厚度正比于 |N·V|，所以用它当"体积密度"：
	// 柱心明亮、边缘透明，平视时是一条柔和的锥形光带。
	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float body = pow(ndv, 1.5);
	// 缓慢向上流动的明暗，避免它看起来是一根静止的塑料棒
	float flow = 0.88 + 0.12 * sin(TIME * 1.4 - v * 6.0);
	float pulse = 0.94 + 0.06 * sin(TIME * 2.3);
	ALBEDO = beam_color.rgb * (0.55 + 0.70 * body);
	ALPHA = fade * (0.012 + 0.30 * body) * intensity * flow * pulse;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("beam_color", col)
	m.set_shader_parameter("intensity", 1.0)
	return m


## 贴地光斑：径向渐变的加法面片。比圆环更适合低机位——
## 圆环被透视压扁后只剩一条亮线，径向光斑仍有面积感。
func _glow_material(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_texture = _radial_tex()
	m.albedo_color = Color(col.r, col.g, col.b, 0.85)
	m.disable_receive_shadows = true
	return m


static func _radial_tex() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.42), Color(1, 1, 1, 0.0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 128
	t.height = 128
	return t


func _process(delta: float) -> void:
	_t += delta
	_core.rotation.y += delta * 2.0
	# 只轻微俯仰：0.35 rad 的翻滚会让箱体在任何一帧都倾斜着，加上识别带之后
	# 反而看不清"这是一只箱子"；0.10 rad 足够让它像悬浮着，又不破坏轮廓。
	_core.rotation.x = sin(_t * 1.3) * 0.10
	_core.position.y = 1.6 + sin(_t * 2.4) * 0.28

	# 最后 5 秒开始闪烁提醒
	var left := _span - _t
	if left < 5.0:
		var on := fmod(_t, 0.26) < 0.15
		_core.visible = on
		_light.light_energy = 2.5 if on else 0.4
		if _beacon != null:
			_beacon.visible = on
	if left <= 0.0:
		queue_free()
		return

	var p = game.player
	if visual_only or Net.is_client():
		return
	# 合作模式：任何一名存活玩家开过都能捡。拾取结算统一走 main.pickup_powerup，
	# 由房主决定谁拿到了什么，再广播给所有人。
	var list: Array = game.players if game.get("players") != null else []
	if list.is_empty() and p != null and is_instance_valid(p):
		list = [p]
	for t in list:
		if not is_instance_valid(t) or not t.alive:
			continue
		if t.global_position.distance_to(global_position) < PICK_RANGE:
			game.pickup_powerup(self, t)
			return
