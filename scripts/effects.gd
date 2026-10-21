class_name Fx
## 运行时 3D 特效：爆炸、炮口焰、跳弹火花、碎片、烟幕与漂浮伤害数字。
##
## 全部用 GPUParticles3D + ParticleProcessMaterial 在代码中生成，不依赖任何外部美术资源。
## 关键取向有三条：
##   1. 烟雾与扬尘用径向渐变的软粒子公告板，而不是纯色立方体——烟才像烟；
##   2. 爆炸拆成火球 / 火星 / 冲击波环 / 飞散碎块四层叠加，层次来自叠加而不是单个大粒子；
##   3. 贴图与材质都做静态缓存，一局里反复触发也不会每次重建资源。

# ---------------- 贴图与材质缓存 ----------------

static var _tex_dot: Texture2D          ## 径向软点：烟雾、扬尘
static var _tex_spark: Texture2D        ## 纵向渐变：拉长的火花轨迹
static var _mesh_cache: Dictionary = {} ## 形状+颜色 -> Mesh
static var _curve_cache: Dictionary = {}## 名字 -> CurveTexture
static var _ramp_cache: Dictionary = {} ## 颜色键 -> GradientTexture1D
static var _warm := false               ## 是否已经预热过


## 径向渐变软点。烟雾粒子的全部"柔和感"都来自这张 64x64 的渐变。
static func soft_dot() -> Texture2D:
	if _tex_dot != null:
		return _tex_dot
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.5, Color(1, 1, 1, 0.6))
	var t := GradientTexture2D.new()
	t.width = 64
	t.height = 64
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	_tex_dot = t
	return t


## 纵向渐变：配合 BILLBOARD_PARTICLES 的速度拉伸，画出带尾迹的火花
static func spark_streak() -> Texture2D:
	if _tex_spark != null:
		return _tex_spark
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.42, Color(1, 1, 1, 1))
	var t := GradientTexture2D.new()
	t.width = 8
	t.height = 64
	t.gradient = g
	t.fill = GradientTexture2D.FILL_LINEAR
	t.fill_from = Vector2(0.5, 0.0)
	t.fill_to = Vector2(0.5, 1.0)
	_tex_spark = t
	return t


## 软粒子公告板：烟雾、尘土、冲击波都用它
static func _quad(col: Color, tex: Texture2D, unshaded: bool, stretch := 0.0) -> Mesh:
	var key := "q|%s|%s|%s|%.2f" % [col.to_html(), tex.get_instance_id(), unshaded, stretch]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if unshaded else BaseMaterial3D.BLEND_MODE_MIX
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.disable_receive_shadows = true
	m.shading_mode = (
		BaseMaterial3D.SHADING_MODE_UNSHADED if unshaded
		else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	)
	if stretch > 0.0:
		# 按速度拉伸：静止时是点，高速时是条，于是火花自带运动方向
		m.billboard_keep_scale = true
		m.particles_anim_h_frames = 1
		m.particles_anim_v_frames = 1
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	q.material = m
	_mesh_cache[key] = q
	return q


## 实心碎块：墙体与装甲崩下来的渣，需要受光才有体积感
static func _chunk(col: Color) -> Mesh:
	var key := "c|" + col.to_html()
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.9
	m.vertex_color_use_as_albedo = true
	var b := BoxMesh.new()
	b.size = Vector3(0.28, 0.28, 0.28)
	b.material = m
	_mesh_cache[key] = b
	return b


## 一次性粒子发射器。GPUParticles3D 的 one_shot + explosiveness=1 等价于"炸一下"。
static func _burst(parent: Node, pos: Vector3, amount: int, lifetime: float,
		mesh: Mesh, pm: ParticleProcessMaterial, aabb := 12.0) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.position = pos
	p.amount = maxi(1, amount)
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 1.0
	p.process_material = pm
	p.draw_pass_1 = mesh
	p.visibility_aabb = AABB(Vector3.ONE * -aabb, Vector3.ONE * aabb * 2.0)
	p.emitting = true
	parent.add_child(p)
	_autofree(p, lifetime * 1.6 + 0.2)
	return p


static func _pm(dir: Vector3, spread: float, v0: float, v1: float,
		gravity: Vector3, s0: float, s1: float, col: Color) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir
	pm.spread = spread
	pm.initial_velocity_min = v0
	pm.initial_velocity_max = v1
	pm.gravity = gravity
	pm.scale_min = s0
	pm.scale_max = s1
	pm.color = col
	return pm


# ---------------- 爆炸 ----------------

## 四层叠加：火球 → 火星 → 扩张冲击波环 → 飞散碎块，最后补一团残烟。
static func explosion(parent: Node, pos: Vector3, size := 1.0) -> void:
	if parent == null:
		return

	# 1. 火球本体（带点光，照亮周围掩体）
	var b := Fireball.new()
	b.position = pos
	b.size_mult = size
	parent.add_child(b)

	# 2. 火星：高初速、重力拉拽、带拉伸尾迹
	var spark := _pm(Vector3.UP, 78.0, 8.0 * size, 24.0 * size,
		Vector3(0, -24.0, 0), 0.12 * size, 0.34 * size, Color(1.0, 0.72, 0.26))
	spark.damping_min = 2.0
	spark.damping_max = 6.0
	spark.scale_over_velocity_min = 0.4
	spark.color_ramp = _fade_ramp(Color(1.0, 0.95, 0.6), Color(0.9, 0.25, 0.05))
	_burst(parent, pos, int(30 * size), 0.85, _quad(Color(1.0, 0.72, 0.26),
		spark_streak(), true, 1.0), spark, 22.0 * size)

	# 3. 扩张冲击波环：贴地横向冲出去，是"这一下很重"最直接的读法
	var ring := Shockwave.new()
	ring.position = pos
	ring.size_mult = size
	parent.add_child(ring)

	# 4. 飞散碎块
	var chunk := _pm(Vector3.UP, 62.0, 5.0 * size, 15.0 * size,
		Vector3(0, -30.0, 0), 0.5 * size, 1.1 * size, Color(0.35, 0.3, 0.26))
	chunk.angular_velocity_min = -420.0
	chunk.angular_velocity_max = 420.0
	_burst(parent, pos, int(12 * size), 1.1, _chunk(Color(0.35, 0.3, 0.26)), chunk, 20.0 * size)

	smoke_puff(parent, pos + Vector3(0, 1.0, 0), size * 1.2)

	# 5. 贴地尘环：爆炸 1 秒后火球与火星都消失了，尘环还在往外推，
	#    把"这里刚刚炸过"这句话延长到两三秒。
	var dust := DustRing.new()
	dust.position = pos
	dust.size_mult = size
	parent.add_child(dust)

	# 6. 落地碎块：不再随粒子一起消失，而是真的躺在地上当战场垃圾。
	_settle_debris(parent, pos, size)


## 爆炸后留在原地的碎块。粒子系统里的碎块寿命一过就整批消失，
## 所以这里单独摆几块静态网格：它们有体积、投影、受光，几秒后随父节点回收。
static func _settle_debris(parent: Node, pos: Vector3, size: float) -> void:
	var root := Node3D.new()
	root.position = pos
	parent.add_child(root)
	var n := 4 + int(round(size * 2.0))
	for i in n:
		var a := randf_range(0.0, TAU)
		var r := randf_range(0.7, 2.6) * size
		var s := randf_range(0.14, 0.34) * maxf(0.8, size)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(s, s * randf_range(0.55, 0.9), s * randf_range(0.8, 1.2))
		mi.mesh = box
		var col := Color(0.24, 0.225, 0.20).lerp(Color(0.36, 0.31, 0.24), randf())
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.roughness = 0.95
		mi.material_override = mat
		mi.position = Vector3(cos(a) * r, s * 0.35, sin(a) * r)
		mi.rotation = Vector3(randf_range(-0.2, 0.2), randf_range(0.0, TAU),
				randf_range(-0.2, 0.2))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mi)
	_autofree(root, 24.0)


## 炮口焰：锥形闪光 + 瞬时点光 + 一缕残烟
static func muzzle_flash(parent: Node, pos: Vector3, dir: Vector3) -> void:
	if parent == null:
		return
	var m := Flash.new()
	m.position = pos
	m.look_at_dir = dir
	parent.add_child(m)

	var pm := _pm(dir, 22.0, 6.0, 16.0, Vector3(0, -2.0, 0), 0.08, 0.2,
		Color(1.0, 0.86, 0.45))
	pm.damping_min = 8.0
	pm.damping_max = 16.0
	pm.color_ramp = _fade_ramp(Color(1.0, 0.95, 0.7), Color(0.9, 0.4, 0.1))
	_burst(parent, pos, 14, 0.3,
		_quad(Color(1.0, 0.86, 0.45), spark_streak(), true, 1.0), pm, 8.0)

	# 残烟：顺着炮管方向飘出去，慢慢散开
	var sm := _pm(dir, 35.0, 1.5, 4.5, Vector3(0, 1.0, 0), 0.6, 1.5,
		Color(0.4, 0.38, 0.36, 0.45))
	sm.damping_min = 2.0
	sm.damping_max = 4.0
	sm.scale_curve = _grow_curve()
	sm.color_ramp = _smoke_ramp(Color(0.52, 0.5, 0.48, 0.5))
	_burst(parent, pos + dir * 1.2, 8, 1.3,
		_quad(Color(1, 1, 1, 1), soft_dot(), false), sm, 10.0)


## 跳弹：扁平扇形的拉长火花，方向沿表面擦出去
static func ricochet(parent: Node, pos: Vector3) -> void:
	if parent == null:
		return
	var pm := _pm(Vector3.UP, 180.0, 10.0, 26.0, Vector3(0, -32.0, 0), 0.08, 0.18,
		Color(1.0, 0.95, 0.6))
	pm.damping_min = 1.0
	pm.damping_max = 4.0
	pm.scale_over_velocity_min = 0.3
	pm.color_ramp = _fade_ramp(Color(1.0, 1.0, 0.85), Color(1.0, 0.45, 0.1))
	_burst(parent, pos, 20, 0.5,
		_quad(Color(1.0, 0.95, 0.6), spark_streak(), true, 1.0), pm, 14.0)


## 命中闪光：小一号的火球，不带碎块与冲击波
static func hit_spark(parent: Node, pos: Vector3) -> void:
	if parent == null:
		return
	var s := Fireball.new()
	s.position = pos
	s.size_mult = 0.45
	s.duration = 0.22
	parent.add_child(s)

	var pm := _pm(Vector3.UP, 150.0, 6.0, 16.0, Vector3(0, -26.0, 0), 0.06, 0.14,
		Color(1.0, 0.9, 0.55))
	pm.scale_over_velocity_min = 0.3
	_burst(parent, pos, 10, 0.35,
		_quad(Color(1.0, 0.9, 0.55), spark_streak(), true, 1.0), pm, 8.0)


## 碎片：沿命中法线崩出去的实心小块
static func debris(parent: Node, pos: Vector3, normal: Vector3, col: Color) -> void:
	if parent == null:
		return
	var n := normal if normal.length() > 0.01 else Vector3.UP
	var pm := _pm(n, 58.0, 5.0, 15.0, Vector3(0, -28.0, 0), 0.5, 1.2, col)
	pm.angular_velocity_min = -500.0
	pm.angular_velocity_max = 500.0
	_burst(parent, pos, 14, 0.9, _chunk(col), pm, 14.0)

	# 碎砖带起的灰
	var dust := _pm(n, 60.0, 1.0, 3.5, Vector3(0, 0.8, 0), 0.5, 1.4,
		Color(col.r, col.g, col.b, 0.35))
	dust.damping_min = 2.0
	dust.damping_max = 5.0
	dust.scale_curve = _grow_curve()
	_burst(parent, pos, 8, 1.1, _quad(Color(1, 1, 1, 1), soft_dot(), false), dust, 10.0)


## 一团散开的烟：爆炸余烟、排气、尘土共用
static func smoke_puff(parent: Node, pos: Vector3, size := 1.0) -> void:
	if parent == null:
		return
	var pm := _pm(Vector3.UP, 42.0, 1.5, 5.0 * size, Vector3(0, 1.4, 0),
		1.0 * size, 2.6 * size, Color(1, 1, 1, 1))
	pm.damping_min = 2.0
	pm.damping_max = 4.5
	pm.angular_velocity_min = -40.0
	pm.angular_velocity_max = 40.0
	pm.scale_curve = _grow_curve()
	pm.color_ramp = _smoke_ramp(Color(0.34, 0.33, 0.32, 0.55))
	_burst(parent, pos, int(14 * size), 1.8,
		_quad(Color(1, 1, 1, 1), soft_dot(), false), pm, 16.0 * size)


## 持续燃烧的烟幕墙：遮蔽视野的战术道具。
## 5 个发射器摆成环，中间留空，于是从侧面看是一道墙而不是一个球。
static func smoke_screen(parent: Node, pos: Vector3, duration: float) -> Node3D:
	var root := Node3D.new()
	root.position = pos
	parent.add_child(root)
	for i in 5:
		var ang := TAU * i / 5.0
		var pm := _pm(Vector3.UP, 55.0, 1.0, 3.0, Vector3(0, 0.7, 0), 2.0, 4.5,
			Color(1, 1, 1, 1))
		pm.damping_min = 1.0
		pm.damping_max = 2.5
		pm.angular_velocity_min = -25.0
		pm.angular_velocity_max = 25.0
		pm.scale_curve = _grow_curve()
		pm.color_ramp = _smoke_ramp(Color(0.56, 0.57, 0.58, 0.5))

		var p := GPUParticles3D.new()
		p.position = Vector3(cos(ang) * 3.2, 0.4, sin(ang) * 3.2)
		p.amount = 34
		p.lifetime = 2.8
		p.preprocess = 0.5
		p.process_material = pm
		p.draw_pass_1 = _quad(Color(1, 1, 1, 1), soft_dot(), false)
		p.visibility_aabb = AABB(Vector3(-10, -2, -10), Vector3(20, 16, 20))
		p.emitting = true
		root.add_child(p)
	_autofree(root, duration)
	return root


static func damage_number(parent: Node, pos: Vector3, text: String, col: Color) -> void:
	if parent == null:
		return
	var l := Label3D.new()
	l.text = text
	l.position = pos + Vector3(randf_range(-0.6, 0.6), 1.6, randf_range(-0.6, 0.6))
	l.font_size = 96
	l.pixel_size = 0.012
	l.modulate = col
	l.outline_size = 24
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.render_priority = 10
	parent.add_child(l)
	var f := Floater.new()
	l.add_child(f)


# ---------------- 曲线与渐变 ----------------
#
# 这三个函数全部走缓存。每一次调用都会 new 一张 CurveTexture / GradientTexture1D，
# 而贴图是要上传到 GPU 的——开一炮就新建三张（炮口焰的火花渐变、残烟渐变、
# 膨胀曲线），连射时每一发都要重来一遍，表现就是"点下鼠标，画面先顿一下"。
# 内容只取决于入参颜色，所以缓存起来既安全，又把开火的那一帧成本压到接近零。

## 粒子随寿命膨胀：烟雾散开靠它，不靠一开始就给大尺寸
static func _grow_curve() -> CurveTexture:
	if _curve_cache.has("grow"):
		return _curve_cache["grow"]
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.35))
	c.add_point(Vector2(0.35, 0.85))
	c.add_point(Vector2(1.0, 1.0))
	var t := CurveTexture.new()
	t.curve = c
	_curve_cache["grow"] = t
	return t


## 火花从白热烧到暗红再熄灭
static func _fade_ramp(hot: Color, cold: Color) -> GradientTexture1D:
	var key := "f|%s|%s" % [hot.to_html(), cold.to_html()]
	if _ramp_cache.has(key):
		return _ramp_cache[key]
	var g := Gradient.new()
	g.set_color(0, hot)
	g.set_color(1, Color(cold.r, cold.g, cold.b, 0.0))
	g.add_point(0.35, cold)
	var t := GradientTexture1D.new()
	t.gradient = g
	_ramp_cache[key] = t
	return t


## 烟从半透明浮上来再淡出
static func _smoke_ramp(body: Color) -> GradientTexture1D:
	var key := "s|" + body.to_html()
	if _ramp_cache.has(key):
		return _ramp_cache[key]
	var g := Gradient.new()
	g.set_color(0, Color(body.r, body.g, body.b, 0.0))
	g.set_color(1, Color(body.r * 0.7, body.g * 0.7, body.b * 0.7, 0.0))
	g.add_point(0.18, body)
	g.add_point(0.6, Color(body.r, body.g, body.b, body.a * 0.7))
	var t := GradientTexture1D.new()
	t.gradient = g
	_ramp_cache[key] = t
	return t


## 预热：在战场之外先把开火、命中、爆炸会用到的材质、贴图与粒子着色器跑一遍。
##
## GPU 粒子的着色器与材质是第一次用到时才编译上传的，没有这一步，
## 开局第一次开火必然掉几帧——而那恰好是玩家判断"反馈快不快"最敏感的一刻。
## 全部放在地面以下 400 米，所以没有任何一帧会被看见。
static func prewarm(parent: Node) -> void:
	if parent == null or _warm:
		return
	_warm = true
	var far := Vector3(0, -400.0, 0)
	muzzle_flash(parent, far, Vector3.FORWARD)
	hit_spark(parent, far)
	ricochet(parent, far)
	debris(parent, far, Vector3.UP, Color(0.6, 0.3, 0.18))
	explosion(parent, far, 0.5)


static func _autofree(n: Node, after: float) -> void:
	var t := Timer.new()
	t.wait_time = after
	t.one_shot = true
	t.autostart = true
	n.add_child(t)
	t.timeout.connect(n.queue_free)


# ---------------- 内部节点 ----------------

## 火球：膨胀的自发光球 + 同步衰减的点光。点光是爆炸"照亮战场"的关键。
class Fireball extends Node3D:
	var t := 0.0
	var duration := 0.55
	var size_mult := 1.0
	var _mi: MeshInstance3D
	var _light: OmniLight3D
	var _mat: StandardMaterial3D

	func _ready() -> void:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(1.0, 0.75, 0.3, 0.9)
		_mat.emission_enabled = true
		_mat.emission = Color(1.0, 0.6, 0.2)
		_mat.emission_energy_multiplier = 6.0
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD

		_mi = MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 1.0
		s.height = 2.0
		s.radial_segments = 16
		s.rings = 8
		_mi.mesh = s
		_mi.material_override = _mat
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)

		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.6, 0.25)
		_light.omni_range = 22.0 * size_mult
		add_child(_light)

	func _process(delta: float) -> void:
		t += delta
		var k := clampf(t / duration, 0.0, 1.0)
		if k >= 1.0:
			queue_free()
			return
		_mi.scale = Vector3.ONE * (0.6 + 3.4 * k) * size_mult
		_mat.albedo_color.a = (1.0 - k) * 0.9
		_mat.emission_energy_multiplier = 6.0 * (1.0 - k)
		_light.light_energy = 9.0 * (1.0 - k) * size_mult


## 贴地扩张的冲击波环。扁平的圆环网格 + 横向放大，读起来就是"气浪推出去"。
class Shockwave extends Node3D:
	var t := 0.0
	var duration := 0.42
	var size_mult := 1.0
	var _mi: MeshInstance3D
	var _mat: StandardMaterial3D

	func _ready() -> void:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(1.0, 0.85, 0.6, 0.55)
		_mat.emission_enabled = true
		_mat.emission = Color(1.0, 0.7, 0.35)
		_mat.emission_energy_multiplier = 2.5
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

		var tm := TorusMesh.new()
		tm.inner_radius = 0.72
		tm.outer_radius = 1.0
		tm.rings = 24
		tm.ring_segments = 5
		_mi = MeshInstance3D.new()
		_mi.mesh = tm
		_mi.material_override = _mat
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)
		position.y += 0.25

	func _process(delta: float) -> void:
		t += delta
		var k := clampf(t / duration, 0.0, 1.0)
		if k >= 1.0:
			queue_free()
			return
		var r := (1.0 + 7.0 * k) * size_mult
		# 环越张越薄：竖向压扁模拟气浪贴地铺开
		_mi.scale = Vector3(r, maxf(0.12, 0.6 - k * 0.5) * size_mult, r)
		_mat.albedo_color.a = (1.0 - k) * 0.55
		_mat.emission_energy_multiplier = 2.5 * (1.0 - k)


## 贴地扩张的尘环：比 Shockwave 慢、比它大、比它久，颜色是土而不是光。
## 冲击波负责"这一下很重"，尘环负责"这一下刚刚发生过"。
class DustRing extends Node3D:
	var t := 0.0
	var duration := 2.6
	var size_mult := 1.0
	var _mi: MeshInstance3D
	var _mat: StandardMaterial3D

	func _ready() -> void:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(0.43, 0.39, 0.32, 0.34)
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat.disable_receive_shadows = true

		var tm := TorusMesh.new()
		tm.inner_radius = 0.62
		tm.outer_radius = 1.0
		tm.rings = 28
		tm.ring_segments = 5
		_mi = MeshInstance3D.new()
		_mi.mesh = tm
		_mi.material_override = _mat
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)
		position.y += 0.12

	func _process(delta: float) -> void:
		t += delta
		var k := clampf(t / duration, 0.0, 1.0)
		if k >= 1.0:
			queue_free()
			return
		# 前 15% 快速铺开，之后几乎停住慢慢淡掉：尘土是被推出去的，不是自己飞的
		var r := (1.1 + 7.4 * pow(k, 0.55)) * size_mult
		_mi.scale = Vector3(r, maxf(0.06, 0.5 - k * 0.42) * size_mult, r)
		_mat.albedo_color.a = 0.34 * (1.0 - k) * (1.0 - k)


## 炮口焰：锥形闪光，瞬时亮一下就收
class Flash extends Node3D:
	var t := 0.0
	var look_at_dir := Vector3.FORWARD
	var _mi: MeshInstance3D
	var _light: OmniLight3D
	var _mat: StandardMaterial3D

	func _ready() -> void:
		if look_at_dir.length() > 0.01:
			look_at(global_position + look_at_dir, Vector3.UP)
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(1.0, 0.9, 0.55, 0.95)
		_mat.emission_enabled = true
		_mat.emission = Color(1.0, 0.85, 0.4)
		_mat.emission_energy_multiplier = 8.0
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD

		_mi = MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = 0.9
		c.bottom_radius = 0.05
		c.height = 2.6
		c.radial_segments = 12
		_mi.mesh = c
		_mi.rotation_degrees = Vector3(-90, 0, 0)
		_mi.position = Vector3(0, 0, -1.3)
		_mi.material_override = _mat
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)

		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.85, 0.45)
		_light.omni_range = 14.0
		add_child(_light)

	func _process(delta: float) -> void:
		t += delta
		var k := clampf(t / 0.09, 0.0, 1.0)
		if k >= 1.0:
			queue_free()
			return
		_mi.scale = Vector3.ONE * (1.0 - k * 0.5)
		_mat.albedo_color.a = 1.0 - k
		_light.light_energy = 7.0 * (1.0 - k)


class Floater extends Node:
	var t := 0.0

	func _process(delta: float) -> void:
		t += delta
		var l := get_parent() as Label3D
		if l == null:
			return
		l.position.y += delta * 2.2
		l.modulate.a = clampf(1.0 - t / 1.1, 0.0, 1.0)
		if t > 1.1:
			l.queue_free()
