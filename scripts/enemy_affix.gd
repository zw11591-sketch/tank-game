class_name EnemyAffix
## 敌人词缀：附加在单个敌人身上的强化标签。
##
## 设计原则（docs/design/04_combat_rules.md 第 4 节）：词缀优先改变**应对方式**，
## 而不是纯加血。玩家看到"重甲"就该绕侧，看到"狂热"就该拉开距离，
## 看到"易爆"就不能贴脸收人头。
##
## 所有数值在 Enemy.configure() 之后施加，因此与关卡成长、难度乘数、
## 合作血量加成叠加，互不覆盖。

const MAX_AFFIX := 3

const DEFS := {
	"armored": {
		"name": "重甲", "desc": "受伤 −28%，结构 +25%，机动 −10%",
		"color": Color(0.62, 0.68, 0.76),
	},
	"frenzied": {
		"name": "狂热", "desc": "装填 −35%，结构 −20%",
		"color": Color(0.92, 0.42, 0.32),
	},
	"volatile": {
		"name": "易爆", "desc": "被击毁时原地爆炸",
		"color": Color(1.0, 0.62, 0.2),
	},
	"shielded": {
		"name": "护盾", "desc": "出生自带 5 秒护盾",
		"color": Color(0.4, 0.86, 1.0),
	},
	"marksman": {
		"name": "神射", "desc": "瞄准散布 −40%",
		"color": Color(0.86, 0.72, 1.0),
	},
}

const ALL: Array[String] = ["armored", "frenzied", "volatile", "shielded", "marksman"]


static func name_of(id: String) -> String:
	return String(DEFS.get(id, {"name": id})["name"])


static func color_of(id: String) -> Color:
	return DEFS.get(id, {"color": Color(1, 1, 1)})["color"]


## 按关卡与修正决定这台敌人带哪些词缀。
##
## Boss 在同一关卡下保底多一条：它是关底，玩家有心理准备，
## 而词缀让"这一场 Boss 怎么打"每局都不同。
static func roll(rng: RandomNumberGenerator, stage: int, etype: int,
		mutators: Array) -> Array[String]:
	var count := 0
	if stage >= 3 and stage <= 5:
		if rng.randf() < 0.35:
			count = 1
	elif stage >= 6 and stage <= 8:
		if rng.randf() < 0.70:
			count = 1
		if rng.randf() < 0.25:
			count += 1
	elif stage >= 9:
		count = 1
		if rng.randf() < 0.40:
			count += 1

	if etype == 4:
		count = maxi(count, 2 if stage < 9 else 3)

	count += Mutators.int_bonus(mutators, "affix_bonus")
	count = mini(count, MAX_AFFIX)

	var out: Array[String] = []
	var pool := ALL.duplicate()
	while out.size() < count and pool.size() > 0:
		var i := rng.randi_range(0, pool.size() - 1)
		out.append(String(pool[i]))
		pool.remove_at(i)
	return out


## 把词缀的数值效果写进敌人。调用点：main._spawn_enemy()，在 configure 之后。
##
## 只改"乘数"与"标记"，不改绝对值：这样关卡成长、难度、合作加成的相对次序不变。
## 表现不在这里做——客户端只重播表现、不重算经济，两者必须能分开调用。
static func apply(e, affixes: Array) -> void:
	if e == null or affixes.is_empty():
		return
	e.affixes = affixes.duplicate()
	for id in affixes:
		match String(id):
			"armored":
				e.max_hp = int(round(float(e.max_hp) * 1.25))
				e.hp = e.max_hp
				e.armor_front *= 0.72
				e.armor_side *= 0.72
				e.armor_rear *= 0.72
				e.move_speed *= 0.90
			"frenzied":
				e.reload_time *= 0.65
				e.max_hp = int(round(float(e.max_hp) * 0.80))
				e.hp = e.max_hp
			"volatile":
				e.volatile_bomb = true
			"shielded":
				e.shield_t = maxf(float(e.shield_t), 5.0)
			"marksman":
				e.aim_spread_mult = 0.60
				e.react_bonus = 0.15


## 爆炸伤害：40 + 8% 最大结构。独立函数方便探针与以后调参。
static func volatile_damage(max_hp: int) -> int:
	return 40 + int(round(float(max_hp) * 0.08))


static func describe(affixes: Array) -> String:
	var parts: Array = []
	for id in affixes:
		parts.append(name_of(String(id)))
	return "·".join(parts)


# ---------------- 表现 ----------------
#
# 词缀必须"看得见"才成立：玩家看到重甲车才会想到绕侧、看到狂热车才会拉开距离。
# 只改数值不挂标记，等于把随机惩罚藏进不可读的血条里。
#
# 表现做两层，因为两层解决的是不同问题：
#   * 车底彩色环 —— 远处一眼分辨"这辆不一样"，颜色沿用 DEFS.color；
#   * 头顶名条    —— 近距离读出具体词缀。文字不依赖颜色，色盲玩家也能读。
# 不使用"整车重新涂装"：模型用的是 Assets.paint 的 ShaderMaterial，
# 改 albedo 会连迷彩与泥污一起洗掉，反而降低可读性。

## 挂上词缀表现。调用点在 add_child() 之后（此时模型与炮塔已建好）。
## 可重复调用：已经挂过就直接返回，避免联机重连时叠出两层名条。
static func apply_visuals(e) -> void:
	if e == null or not is_instance_valid(e):
		return
	if e.affixes.is_empty():
		return
	if e.has_node("AffixTag"):
		return
	var tint: Color = color_of(String(e.affixes[0]))
	_ring(e, tint)
	_tag(e, tint)


static func _ring(e, tint: Color) -> void:
	var mesh := TorusMesh.new()
	var r: float = maxf(float(e.body_radius), 0.8)
	mesh.inner_radius = r * 0.92
	mesh.outer_radius = r * 1.04
	mesh.rings = 24
	mesh.ring_segments = 6
	var mi := MeshInstance3D.new()
	mi.name = "AffixRing"
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 1.8
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.62
	mat.emission_energy_multiplier = 1.2
	mi.material_override = mat
	mi.position = Vector3(0, 0.10, 0)
	# 环不参与碰撞与射线：它只是地面上的一个读数标记。
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.add_child(mi)


static func _tag(e, tint: Color) -> void:
	var l := Label3D.new()
	l.name = "AffixTag"
	l.text = describe(e.affixes)
	l.font_size = 72
	l.pixel_size = 0.0040
	l.modulate = tint
	l.outline_size = 14
	l.outline_modulate = Color(0.03, 0.04, 0.06, 0.92)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.shaded = false
	# 车长 4~6 m，名条放到车顶上方 2 m 左右；Boss 更高，跟着 body_length 走。
	l.position = Vector3(0, float(e.body_length) * 0.35 + 2.2, 0)
	e.add_child(l)