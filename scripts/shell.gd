class_name Shell
extends Node3D
## 炮弹：分步射线检测飞行。
##
## AP 穿甲弹：高速平直、单体伤害高、命中倾斜正面装甲时可能跳弹。
## HE  高爆弹：低速抛物线、直击伤害低但有溅射，可成片摧毁砖墙。

enum Kind { AP, HE }

## 弹速决定"点下鼠标到看见结果"的延迟。原来 150 m/s 在 40 米外要飞近 0.27 秒，
## 开火与命中之间有一段明显的空档；提到 250 m/s 后同样距离只要 0.16 秒，
## 近距离基本是即时命中，手感从"投掷"变回"射击"。
## 敌人的提前量预瞄读的也是这两个常量，所以 AI 自动跟着一起校准。
const AP_SPEED := 250.0
const HE_SPEED := 112.0
const HE_GRAVITY := 34.0

## HE 弹道解算允许的最大发射仰角。这是**射程量**，与炮管的机械上限
## `Tank.PITCH_MAX`（手感量）分开——`lob_dir()` 拿到的目标是准星打中的那个点，
## 与炮管当下指向无关，所以炮管抬不到的角度弹道照样可以。
##
## 战场 96×96 m、最远对角 136 m，那里解出来的仰角是 10.44°，11° 即"HE 还能落在
## 全图任意准星上"的最小值。抬升量随距离的台阶（炮口 1.95 m、目标中心 1.1 m）：
##   r = 30 / 40 / 60 / 80 / 100 / 136 m  →  0.7° / 1.9° / 3.9° / 5.7° / 7.4° / 10.4°
## 炮管上限收到 6° 之后这个常量必须留着：80 m 以外解算都会被炮管卡住，退回平直
## 发射时 112 m/s 的弹在 100 m 处低掉 13.6 m——等于每一发都打在地上。
const HE_SOLVE_MAX := deg_to_rad(11.0)
const HE_RADIUS := 7.0
const MAX_LIFE := 6.0

var game: Node
var arena: Arena
var shooter: Tank

var kind := Kind.AP
var vel := Vector3.ZERO
var damage := 60
var from_player := false

var _life := 0.0
var _dead := false
var _trail: MeshInstance3D


func launch(g: Node, a: Arena, from: Tank, origin: Vector3, dir: Vector3, k: int) -> void:
	game = g
	arena = a
	shooter = from
	kind = k
	from_player = from.is_player
	position = origin

	var d := dir.normalized()
	if kind == Kind.HE:
		# 抬升量不在这里加：必须由 lob_dir() 按实际距离解出来，
		# 否则抛物线落点与准星无关，近距离必然整发飞过敌人头顶。
		# 伤害倍率取自车体（各车型的高爆弹威力不同：自行火炮是专精，侦察车是弱项）。
		vel = d * HE_SPEED
		damage = int(round(from.damage * from.he_mult * from.damage_mult))
	else:
		vel = d * AP_SPEED
		damage = int(round(from.damage * from.damage_mult))


## 低抛弹道解：求一个初速方向，使 HE 弹在重力作用下正好落在 target 上。
##
## 必须有这一步，否则"准星指哪"和"炮弹落哪"是两件事：
## HE 只有 112 m/s 又吃 34 m/s² 的重力，40 米外直瞄发射就会在落点处低掉 2.2 米，
## 而坦克只有 2 米高——于是每一发都从车底钻过去或从头顶飞过去。
##
## 解的是标准斜抛：tanθ = (v² - sqrt(v⁴ - g(g·r² + 2·y·v²))) / (g·r)。
## 取负号那一支即低抛弹道，弹道最平、飞行时间最短，也最接近玩家预期的"直接打过去"。
## 判别式为负表示超出射程（v²/g ≈ 369 米，实战不会遇到），此时退回直瞄方向：
## 打不到，但至少不会朝天乱飞。
static func lob_dir(origin: Vector3, target: Vector3, fallback: Vector3) -> Vector3:
	var to := target - origin
	var flat := Vector3(to.x, 0.0, to.z)
	var r := flat.length()
	if r < 0.5:
		return fallback
	var v2 := HE_SPEED * HE_SPEED
	var disc := v2 * v2 - HE_GRAVITY * (HE_GRAVITY * r * r + 2.0 * to.y * v2)
	if disc < 0.0:
		return fallback
	var tan_theta := (v2 - sqrt(disc)) / (HE_GRAVITY * r)
	return (flat / r + Vector3.UP * tan_theta).normalized()


func _ready() -> void:
	var mat := StandardMaterial3D.new()
	var col := Color(1.0, 0.85, 0.35) if kind == Kind.AP else Color(1.0, 0.45, 0.2)
	if not from_player:
		col = Color(1.0, 0.35, 0.3)
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.16
	cap.height = 0.8
	mi.mesh = cap
	mi.rotation_degrees = Vector3(90, 0, 0)
	mi.material_override = mat
	add_child(mi)

	# 曳光拖影。弹速提高后单帧位移变大，拖影随之拉长，高速下才不会看成一串断点
	_trail = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.1, 0.1, 8.0 if kind == Kind.AP else 4.0)
	_trail.mesh = bm
	_trail.position = Vector3(0, 0, bm.size.z * 0.52)
	var tmat := mat.duplicate()
	tmat.albedo_color = Color(col.r, col.g, col.b, 0.35)
	tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tmat.emission_energy_multiplier = 2.0
	_trail.material_override = tmat
	add_child(_trail)

	var light := OmniLight3D.new()
	light.light_color = col
	light.light_energy = 2.0
	light.omni_range = 6.0
	add_child(light)


func _physics_process(delta: float) -> void:
	if _dead:
		return
	_life += delta
	if _life > MAX_LIFE:
		_die()
		return

	if kind == Kind.HE:
		vel.y -= HE_GRAVITY * delta

	var step := vel * delta
	var n: int = maxi(1, int(ceil(step.length() / 1.2)))
	var seg := step / float(n)
	for i in n:
		var from := global_position
		var to := from + seg
		if _trace(from, to):
			return
		global_position = to

	if vel.length_squared() > 0.01:
		look_at(global_position + vel.normalized(), Vector3.UP)


func _trace(from: Vector3, to: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [shooter.get_rid()] if is_instance_valid(shooter) else []
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false

	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var collider = hit["collider"]

	if collider is Tank:
		_hit_tank(collider, point)
		return true
	if _hit_world(collider, point, normal):
		return true
	return false


func _hit_tank(t: Tank, point: Vector3) -> void:
	var out := [0, ""]
	var res := t.take_hit(damage, global_position, kind, out)
	if res == "ricochet":
		# 跳弹：炮弹被弹开报废，不造成任何伤害
		Fx.ricochet(game.fx_root, point)
		if game.has_method("on_shell_feedback"):
			game.on_shell_feedback("跳弹!", point, from_player)
		_die()
		return
	if res == "shield":
		Fx.ricochet(game.fx_root, point)
		_die()
		return
	if res != "none" and game.has_method("on_shell_feedback"):
		game.on_shell_feedback("%s %d" % [out[1], out[0]], point, from_player)
	if kind == Kind.HE:
		_explode()
	else:
		_die()


func _hit_world(collider: Object, point: Vector3, normal: Vector3) -> bool:
	if kind == Kind.HE:
		_explode()
		return true

	if collider is StaticBody3D and collider.has_meta("cell"):
		var c: Vector2i = collider.get_meta("cell")
		var r: String = arena.hit_cell(c, damage, false)
		match r:
			"brick", "brick_break":
				Fx.debris(game.fx_root, point, normal, Color(0.6, 0.3, 0.18))
				Audio.play_3d("brick", point)
			"steel":
				Fx.ricochet(game.fx_root, point)
				Audio.play_3d("steel", point)
			"base":
				Fx.explosion(game.fx_root, point, 0.9)
				Audio.play_3d("boom", point)
	else:
		Fx.debris(game.fx_root, point, normal, Color(0.45, 0.42, 0.35))
		Audio.play_3d("steel", point)
	_die()
	return true


func _explode() -> void:
	if _dead:
		return
	var center := global_position
	# 溅射半径按射手车型缩放：自行火炮一发能整片铲平砖墙，侦察车只有一小圈
	var radius := HE_RADIUS
	if is_instance_valid(shooter):
		radius *= shooter.he_splash
	Fx.explosion(game.fx_root, center, 2.0 * clampf(radius / HE_RADIUS, 0.8, 1.6))
	Audio.play_3d("boom", center)
	arena.splash_cells(center, radius, damage)
	# 战场痕迹：HE 弹坑留在地上，一局打下来地面会慢慢被犁一遍
	if center.y < 4.0:
		arena.add_crater(center, 1.0)

	# 溅射伤害按距离衰减
	for t in game.all_tanks():
		if not is_instance_valid(t) or not t.alive:
			continue
		if t == shooter:
			continue
		var d: float = t.global_position.distance_to(center)
		if d > radius:
			continue
		var falloff: float = 1.0 - d / radius
		var dmg := int(round(damage * 0.85 * falloff))
		if dmg <= 0:
			continue
		var out := [0, ""]
		var res: String = t.take_hit(dmg, center, kind, out)
		if res != "none" and res != "shield" and game.has_method("on_shell_feedback"):
			game.on_shell_feedback("溅射 %d" % out[0], t.global_position, from_player)
	_die()


func _die() -> void:
	if _dead:
		return
	_dead = true
	queue_free()
