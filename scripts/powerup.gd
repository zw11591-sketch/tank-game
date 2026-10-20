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
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = col
	_mat.emission_enabled = true
	_mat.emission = col
	_mat.emission_energy_multiplier = 2.2
	_mat.metallic = 0.4
	_mat.roughness = 0.3

	_core = MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(1.5, 1.5, 1.5)
	_core.mesh = b
	_core.material_override = _mat
	_core.position = Vector3(0, 1.6, 0)
	add_child(_core)

	# 底部光环，远处也能看见掉落位置
	var ring := MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = 1.5
	t.outer_radius = 1.9
	ring.mesh = t
	ring.position = Vector3(0, 0.15, 0)
	ring.material_override = _mat
	add_child(ring)

	_light = OmniLight3D.new()
	_light.light_color = col
	_light.light_energy = 2.5
	_light.omni_range = 10.0
	_light.position = Vector3(0, 2.0, 0)
	add_child(_light)

	# 空投补给加一道竖直光柱：它落在场地深处，没有光柱根本看不见
	if from_field:
		_beacon = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.55
		cm.bottom_radius = 0.9
		cm.height = 26.0
		_beacon.mesh = cm
		_beacon.position = Vector3(0, 13.0, 0)
		var bm := StandardMaterial3D.new()
		bm.albedo_color = Color(col.r, col.g, col.b, 0.14)
		bm.emission_enabled = true
		bm.emission = col
		bm.emission_energy_multiplier = 1.2
		bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		_beacon.material_override = bm
		_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_beacon)


func _process(delta: float) -> void:
	_t += delta
	_core.rotation.y += delta * 2.0
	_core.rotation.x = sin(_t * 1.3) * 0.35
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
	if p != null and is_instance_valid(p) and p.alive:
		if p.global_position.distance_to(global_position) < PICK_RANGE:
			game.apply_powerup(ptype)
			queue_free()
