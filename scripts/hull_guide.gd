class_name HullGuide
extends Node3D
## 车体朝向标识，只挂在玩家车上：解决"分不清车头车尾"。
##
## 炮塔能独立回转，所以"炮管指向"根本不能用来判断车头在哪；而原来的车体上
## 唯一的朝向线索是一块前倾的首下装甲斜板，从后方或俯视角几乎看不出来。
## 这里补三组**互相冗余**的线索，任意视角至少能看到一组：
##   1. 车头白灯 —— 装在首下装甲之前，任何角度都能看见
##   2. 车尾红灯 —— 第三人称默认从车后上方看，红灯是最醒目的"这头是尾巴"
##   3. 车头前方地面的导向箭头 —— 顺便提示"踩油门会往哪走"
##
## 几何位置取自 tools/blender/dims.py 的车体尺寸：车头是 -Z，
## 首下斜板最前端约 z = -(长/2) - 0.33，尾板最后端约 z = +(长/2) + 0.13，
## 所以灯具放在 ±(长/2 + 0.35) 之外就不会被车体自身的部件埋掉。

## 地面导向标离地高度：履带印等 Decal 在 y = 0.02，要压在它们之上
const GROUND_Y := 0.06

const LAMP_WARM := Color(1.0, 0.95, 0.75)
const LAMP_RED := Color(1.0, 0.16, 0.12)


## hull 为车体尺寸 (宽, 高, 长)，与 Tank._hull_size 同一约定
func setup(hull: Vector3, accent: Color) -> void:
	var half_l := hull.z * 0.5
	var deck := 0.35 + hull.y
	_lamps(half_l, hull.x * 0.5, deck)
	_ground_arrow(half_l, accent)


# ---------------- 车头灯 / 车尾灯 ----------------

func _lamps(half_l: float, half_w: float, deck: float) -> void:
	var white := _glow_mat(LAMP_WARM, 3.0)
	var red := _glow_mat(LAMP_RED, 2.8)
	var y := deck - 0.2
	for sx in [-1.0, 1.0]:
		# 车头灯：比首下斜板最前端再探出一点，避免被斜板挡住
		_box(Vector3(0.36, 0.3, 0.14),
				Vector3(sx * (half_w * 0.82), y, -half_l - 0.36), 0.0, white)
		# 车尾灯：比尾板更靠后，红色是"尾巴"的通用语言
		_box(Vector3(0.34, 0.26, 0.12),
				Vector3(sx * (half_w * 0.72), y - 0.14, half_l + 0.22), 0.0, red)


# ---------------- 地面导向箭头 ----------------

## 车头正前方的贴地箭头：一个实心三角。
## 用实心面而不是几根细条——12m 开外的第三人称视距上，细条会糊成几根散落的棍子。
## 刻意只伸出约 1.6m：伸太长会在狭窄巷道里穿进墙里。
func _ground_arrow(half_l: float, accent: Color) -> void:
	var mat := _flat_mat(accent.lerp(Color.WHITE, 0.3), 0.62)
	var head := MeshInstance3D.new()
	var pm := PrismMesh.new()
	# PrismMesh 的三角形在 XY 平面、尖端朝 +Y，绕 X 转 -90° 后尖端指向 -Z（车头）
	pm.size = Vector3(1.95, 1.45, 0.05)
	head.mesh = pm
	head.rotation.x = -PI * 0.5
	head.position = Vector3(0, GROUND_Y, -half_l - 0.95)
	head.material_override = mat
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(head)


# ---------------- 构件 ----------------

func _box(size: Vector3, pos: Vector3, rot_y: float, mat: Material) -> void:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	m.position = pos
	m.rotation.y = rot_y
	m.material_override = mat
	# 朝向标是给玩家看的提示，不该参与光照计算与阴影投射
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(m)


## 自发光材质：灯具在阴影里也要亮
func _glow_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.3
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


## 贴地标记材质：无光照 + 半透明，避免在车体阴影里变成一团黑
func _flat_mat(col: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m
