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
## 纯表现炮弹：客户端上的炮弹只负责飞、命中、冒火花，不结算伤害也不拆墙。
## 真正的结算发生在房主那边，伤害由快照与事件回传。
var visual_only := false

var _life := 0.0
var _dead := false
## 发射这次击发的编号（见 Tank.claim_hit）。多弹装填的三发共用同一个编号。
var _shot_id := -1
## 联机击发编号（房主与客户端一致的 uid）。命中反馈按它去重。
var _shot_uid := 0
var _trail: MeshInstance3D
## 已经触发过视觉命中的道具（instance_id -> true）。见 _probe_blockers()。
var _touched: Dictionary = {}


func launch(g: Node, a: Arena, from: Tank, origin: Vector3, dir: Vector3, k: int,
		uid := 0) -> void:
	game = g
	arena = a
	shooter = from
	kind = k
	from_player = from != null and from.is_player
	_shot_id = from._shot_id if from != null else -1
	_shot_uid = uid
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


## 低抛弹道采样：从 origin 沿 dir 出发的 HE 飞行轨迹（世界坐标）。
##
## 供两处使用：狙击镜里的落点预览，以及 aim_reachable() 的抛物线路检。
## 步长按 0.05 s 固定（20 Hz），因为这里要的是"形状对"，不是逐帧精确——
## 真正的飞行仍由 _physics_process 按物理步长推进。
static func trajectory(origin: Vector3, dir: Vector3, steps := 60) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var p := origin
	var v := dir.normalized() * HE_SPEED
	var dt := 0.05
	pts.append(p)
	for i in steps:
		v.y -= HE_GRAVITY * dt
		p += v * dt
		pts.append(p)
		if p.y < 0.0:
			break
	return pts


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
	# 友好伤害关闭：玩家打出的炮弹不与任何玩家车体相交。直接把 RID 排除掉，
	# 比"打中了再退回伤害"更干净——队友之间不会出现火花、跳弹与命中提示。
	if from_player and game != null and game.has_method("human_rids"):
		q.exclude = game.human_rids()
	elif is_instance_valid(shooter):
		q.exclude = [shooter.get_rid()]
	else:
		q.exclude = []
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		# 主射线什么都没碰到，但这一段里可能有道具 / 残骸 / 水面：
		# 它们在第 4 层，不挡炮弹，却应该留下痕迹。
		_probe_blockers(from, to)
		return false

	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var collider = hit["collider"]

	# 视觉命中只查主命中点之前的这一段，免得炮弹穿过沙袋之后才在它身后冒烟
	_probe_blockers(from, point)

	if collider is Tank:
		_hit_tank(collider, point)
		return true
	if _hit_world(collider, point, normal):
		return true
	return false


## 只做视觉的道具命中：沙袋 / 路障 / 残骸 / 水面在第 4 层。
##
## 规则不变——"挡车不挡弹"——炮弹照样穿过去。但完全没有反馈的穿透
## 读起来像穿模：玩家看到炮弹从沙袋中间钻过去，会怀疑是不是碰撞错了。
## 出一个沙尘/水花就够了，伤害与弹道一点不动。
##
## 每个物体只触发一次：炮弹会在一根窄射线里跨好几个子步，不去重的话
## 同一堵沙袋会被连续打中四五次，冒出五团尘。
func _probe_blockers(from: Vector3, to: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, Tank.LAYER_BLOCKER)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	var c = hit["collider"]
	if not is_instance_valid(c):
		return
	var id: int = c.get_instance_id()
	if _touched.has(id):
		return
	_touched[id] = true
	var point: Vector3 = hit["position"]

	# 水面：格子类型能问 arena，比给每个水面块打 meta 更省
	if c.has_meta("cell"):
		var cell: Vector2i = c.get_meta("cell")
		var t: int = arena.cell(cell.x, cell.y)
		# 水面、沙袋与路障的碰撞体都刻意做得比可见网格高（防止坦克骑上去），
		# 所以射线交点会浮在表面上方一米多。反馈必须贴回可见表面，
		# 否则水柱会悬在半空、沙尘会在沙袋顶上飘。
		if t == Arena.WATER:
			point.y = Arena.WATER_H
			Fx.water_splash(game.fx_root, point)
			Audio.play_3d("water", point)
			return
		elif t == Arena.SAND:
			point.y = minf(point.y, Arena.SAND_H)
		elif t == Arena.BARRICADE:
			point.y = minf(point.y, Arena.BARRICADE_H)
	# 残骸 / 沙袋 / 路障 / 栅栏：都是"实心但不是钢"
	Fx.dirt_impact(game.fx_root, point, Vector3.UP, Color(0.42, 0.38, 0.30))
	Audio.play_3d("dirt", point)


func _hit_tank(t: Tank, point: Vector3) -> void:
	if visual_only:
		# 客户端上的炮弹只是表现：命中火花 + 音效，伤害与击毁由房主广播。
		Fx.hit_spark(game.fx_root, point)
		Audio.play_3d("steel", point)
		_die()
		return
	# 命中次数按击发记：同一发弹幕打到几辆车、HE 溅到几辆车，都只算一次。
	# 放在 take_hit 之前，于是跳弹与护盾这些"碰到了但没穿"也计入命中。
	# 只有本机玩家的命中才进本机统计；房主替队友结算时由 Net 把反馈发给射手。
	if from_player and is_instance_valid(shooter) and shooter.is_local:
		shooter.claim_hit(_shot_id)
	var out := [0, ""]
	# 记下谁打的：击毁结算在 Tank.destroy() 里，那里没有炮弹上下文。
	if is_instance_valid(shooter):
		t.last_shooter = shooter
	var res := t.take_hit(damage, global_position, kind, out, point)
	if res == "ricochet":
		# 跳弹：炮弹被弹开报废，不造成任何伤害
		Fx.ricochet(game.fx_root, point)
		_feedback("跳弹!", point, "bounce", 0, _etype_of(t))
		_die()
		return
	if res == "shield":
		Fx.ricochet(game.fx_root, point)
		_feedback("护盾吸收", point, "block", 0, _etype_of(t))
		_die()
		return
	if res != "none":
		var result := "kill" if res == "kill" else "pen"
		_feedback("%s %d" % [out[1], out[0]], point, result, int(out[0]), _etype_of(t))
	if kind == Kind.HE:
		# 把直击目标传给 _explode：它会照旧吃溅射伤害，但不再为同一发再飘一个数字。
		# 原来一颗 HE 直击会同时出"正面 57"和"溅射 41"、响两声命中提示，
		# 玩家数不清自己打了几发。
		_explode(t)
	else:
		_die()


## 命中反馈统一出口。房主本地玩家直接走 main.on_shell_feedback，
## 远端玩家的这一发由 main 转成 RPC 发给射手，别人的命中不会显示在房主 HUD 上。
func _feedback(text: String, point: Vector3, result: String, amount: int, etype: int) -> void:
	if not from_player or game == null:
		return
	if game.has_method("net_shell_feedback"):
		game.net_shell_feedback(shooter, _shot_uid, text, point, result, amount, etype)
	elif game.has_method("on_shell_feedback"):
		game.on_shell_feedback(text, point, true, result, amount, etype)


func _hit_world(collider: Object, point: Vector3, normal: Vector3) -> bool:
	if visual_only:
		if kind == Kind.HE:
			Fx.explosion(game.fx_root, point, 2.0)
			Audio.play_3d("boom", point)
		elif collider is StaticBody3D and collider.has_meta("cell"):
			Fx.ricochet(game.fx_root, point)
			Audio.play_3d("steel", point)
		else:
			Fx.dirt_impact(game.fx_root, point, normal, Color(0.42, 0.36, 0.27))
			Audio.play_3d("dirt", point)
		_die()
		return true
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
		# 地面：土溅 + 弹坑 + 泥土声。原来这里放的是钢板的"叮"，
		# 于是每一发打空的炮弹都在提醒玩家"地面是钢做的"。
		Fx.dirt_impact(game.fx_root, point, normal, Color(0.42, 0.36, 0.27))
		Audio.play_3d("dirt", point)
		# AP 打进土里会留一个小坑；HE 已经在 _explode 里留下更大的弹坑
		if kind == Kind.AP:
			arena.add_crater(point, 0.72)
	_die()
	return true


## direct 是直击命中的那辆车（HE 才有）。它的溅射伤害照常结算，
## 但不再额外飘一次字、响一声"叮"——那一段反馈已经由 _hit_tank() 给过了。
func _explode(direct: Tank = null) -> void:
	if _dead:
		return
	if visual_only:
		Fx.explosion(game.fx_root, global_position, 2.0)
		Audio.play_3d("boom", global_position)
		_die()
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
	var splash_landed := false
	for t in game.all_tanks():
		if not is_instance_valid(t) or not t.alive:
			continue
		if t == shooter:
			continue
		# 友好伤害关闭：玩家炮弹的溅射也不伤队友。
		if from_player and t.is_player:
			continue
		var d: float = t.global_position.distance_to(center)
		if d > radius:
			continue
		var falloff: float = 1.0 - d / radius
		var dmg := int(round(damage * 0.85 * falloff))
		if dmg <= 0:
			continue
		var out := [0, ""]
		if is_instance_valid(shooter):
			t.last_shooter = shooter
		var res: String = t.take_hit(dmg, center, kind, out)
		if res != "none" and res != "shield" and res != "ricochet":
			splash_landed = true
		# 直击目标不再重复提示：同一发炮弹只该有一个数字、一声提示
		if t == direct:
			continue
		if res == "none" or res == "shield" or res == "ricochet":
			continue
		_feedback("溅射 %d" % out[0], t.global_position,
				"kill" if res == "kill" else "pen", int(out[0]), _etype_of(t))
	# 落地溅射也算命中：HE 打进人堆时没有直击，但伤害确实造成了。
	# claim_hit 按击发去重，所以直击 + 溅射不会记成两次。
	if splash_landed and from_player and is_instance_valid(shooter) and shooter.is_local:
		shooter.claim_hit(_shot_id)
	_die()


## 敌车类型；玩家没有这个字段。
## 直接写 `t.etype` 会在玩家被击穿时抛 "Invalid access to property"——
## 而玩家恰恰是最常被打中的那个，于是每次中弹都刷一条脚本错误。
static func _etype_of(t: Tank) -> int:
	return (t as Enemy).etype if t is Enemy else -1


func _die() -> void:
	if _dead:
		return
	_dead = true
	queue_free()
