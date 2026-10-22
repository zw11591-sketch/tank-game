class_name CameraRig
extends Node3D
## 第三人称相机 + 瞄准方向。镜头锁在车体后方，鼠标只转炮塔。
##
## 本文件的核心是**两套独立朝向**，不要再把它们合并成一个值：
##   * yaw     —— 镜头朝向，平滑贴住车体朝向
##   * aim_yaw —— 炮塔瞄准朝向（世界系），由鼠标 / 右摇杆直接驱动
##
## 改造前两者是同一个 yaw：鼠标同时转镜头和炮塔，于是炮管永远精确指向屏幕正中，
## 在画面里完全看不出转动（"炮管不会动"的真正原因）。现在镜头跟车体、炮塔跟鼠标，
## 炮管会在画面里真的横扫；为了不让准星被甩出屏幕，瞄准角超出
## FOLLOW_DEADZONE 时镜头才会被拖着一起转。

const SENS := 0.0022
## 炮管俯仰单独一个增益：水平方向一整圈是 360°，俯仰总行程只有 24°
## （`[-18°, +6°]`，见 Tank.PITCH_MIN/MAX），用同一个增益必然"一碰就到顶"。
##
## 取值按"从水平推多少像素才够到上限"来定，这个量才有直觉：0.10 对应
## 约 476 px（= 0.013°/px）。原来是 0.45，只要 210 px——手一抖 5 px 就偏 0.28°，
## 100 m 外偏半米、200 m 外偏一米，准星动不动就从敌人头顶跳到天上，玩家的
## 感受就是"上下调节过大、一瞄就打到天上"。0.013°/px 下，手抖 10 px 只走 0.13°
## （验收上限 0.2°）；压到近距离目标所需的 -8°~-16° 大致对应 620~1240 px，
## 要故意往下拖才拖得到，而"把炮口抬到天上"要 476 px 的净上行。
## 注意摇杆走的是同一个系数：`STICK_RATE * PITCH_SENS` 即满舵 15°/s，
## 原来 67°/s 相当于全行程 0.3 秒，一样是过冲。
const PITCH_SENS := 0.10
## 右摇杆满舵的角速度（弧度/秒）
const STICK_RATE := 2.6

## 镜头俯仰不再由鼠标控制：常态取 PITCH_BASE，并随炮管仰角按 PITCH_FOLLOW 抬降。
##
## 18° 而不是原来的 26°：俯角越大，画面里看到的越是墙顶与地面，车体反而缩在下方。
## 收到 18° 之后视线更接近水平，3 m 砖墙会真正挡住画面，掩体才有"墙"的感觉，
## 而不是一块可以俯视的矮台。
const PITCH_MIN := deg_to_rad(-10.0)
const PITCH_MAX := deg_to_rad(34.0)
const PITCH_BASE := deg_to_rad(18.0)
## 取景位的"视线高度"只到炮塔顶盖下方，而不是车顶之上。
##
## 3.0 的俯视点让相机实际站在 5.6 m 高：3 m 砖墙只到画面下三分之一，
## 玩家一直在俯视墙顶；同时车尾离相机只有 5.8 m，履带正好压在画面下缘，
## 被 HUD 切掉。降到 2.35 之后相机约 4.3 m 高：墙重新成为挡视线的掩体，
## 车体在画面里从约 25% 提到 38%，而且履带完整可见。
const PIVOT_EYE_Y := 2.35
## 镜头俯仰跟随炮管仰角的比例。
##
## 原来是 0.9：炮管一抬，镜头几乎整段跟着抬（俯角 33.2° → 9.8°），画面里准星
## 钉在接近上缘的位置不动、地平线掉到屏幕中部，于是"上下瞄准"变成了"整幅画面
## 上下摇"，操作起来像在打高射炮。收到 0.5 之后镜头只走一半（30° → 20°），
## 准星在画面里真的上下移动——抬没抬炮管一眼就能看出来；代价是高仰角时准星更靠
## 画面上缘（仍在画面内，炮管上限收到 6° 之后离上缘还有约 15% 的屏幕高度）。
const PITCH_FOLLOW := 0.5

## 镜头贴车体的跟随速度；以及准星允许偏离镜头中轴的角度
## 42° 略小于半水平视场（约 53°），准星最多走到接近屏幕边缘就会带着镜头转
##
## 7 → 12：稳态滞后 ≈ 车体角速度 / 这个数。山猫原地转向 3.8 rad/s 时原来是 0.54 rad
## （31°）的滞后——车头已经转过去三分之一圈，画面还没跟上，玩家的感受就是
## "打舵之后车不跟手"（tools/_hull_clip_probe.gd 的 camLag）。收到 12 之后同样的
## 转向只剩约 18°，第三人称仍然保留一点"车体有重量"的拖尾，但不再像延迟。
const FOLLOW_RATE := 12.0
const FOLLOW_DEADZONE := deg_to_rad(42.0)

const AIM_RANGE := 300.0

## 第三人称视场。74° 是"垂直视场"，在 16:9 下水平接近 110°，广角会把 4.4 m 的
## 坦克压成画面里的一小块，并让边缘明显拉伸——这正是"桌面沙盘"读法的来源之一。
## 60° 相当于 16:9 下水平约 91°，坦克在同样距离下占屏高度从 24% 提到 40% 以上。
const FOV_NORMAL := 60.0
## 狙击镜两档。26° 是"看全一片"的宽镜，14° 是"只盯一个目标"的窄镜；
## 只有一档时玩家要么看不清周围、要么看不清装甲分区，两种需求被同一个焦距绑死。
## 滚轮切换，档位存在 sniper_zoom 里。
const FOV_SNIPER := 26.0
const FOV_SNIPER_NARROW := 14.0
## 第一人称视场比第三人称略宽，补偿"看不到车身两侧"带来的局促感
const FOV_FIRST := 70.0
## 常态臂长。12 m 时相机实际在离地 10 m 的空中，俯视整张图；
## 7.6 m + 2.35 m 俯视点约等于 WoT 那种"贴着炮塔后方"的机位。
const ARM_NORMAL := 7.6
## 常态视角抬得比砖墙(3.0)更低：视线与炮塔齐平，掩体才会挡住视线。
const PIVOT_NORMAL := Vector3(0, PIVOT_EYE_Y, 0)
## 狙击镜把镜头挪到炮口之前、与炮管同高，形成不被自车遮挡的炮手瞄具
const PIVOT_SNIPER := Vector3(0, 2.1, -4.3)
## 第一人称：车长塔位置。炮塔顶盖约在 2.53，取 2.78 刚好探出舱盖，
## 既不会被自己的炮塔挡住视线，又能在画面下缘看到自己的炮管。
const PIVOT_FIRST := Vector3(0, 2.78, -0.2)

## 自车护盾球会把第一人称镜头整个包住，于是护盾被放在这个独立视觉层上，
## 由第一人称相机单独剔除掉（第三人称仍然要看得见）。
const LAYER_OWN_SHIELD := 1 << 1
const CULL_ALL := 0xFFFFF

var target: Tank

## 镜头朝向（派生值，跟随车体，勿直接当瞄准用）
var yaw := 0.0
var pitch := PITCH_BASE

## 瞄准朝向（世界系）。炮塔追的是它，鼠标改的也是它。
var aim_yaw := 0.0
var aim_pitch := 0.0

var sniper := false
## 狙击镜档位：0 宽镜 / 1 窄镜。滚轮切换。
var sniper_zoom := 0
## 第一人称炮手视角（V 键切换）。镜头装在车长塔里、跟着炮塔转，
## 代价是看不见自己的车体朝向——所以 HullGuide 的地面导向箭头在这个视角下尤其重要。
var first_person := false

var arm: SpringArm3D
var cam: Camera3D

var _trauma := 0.0
var _shake_t := 0.0
## 开火震屏单独的上限。开火是"每发一次"的脉冲，不该像受伤那样累加：
## 每发 +0.45、衰减 1.9/s，连点 6 次/秒时 1 秒内就顶到 1.0，画面在 ±0.35 m 上抖，
## 而这是一款"每一下点击都要打出去"的游戏——震屏把准星晃掉就是纯粹的惩罚。
## 0.35 单发仍然清晰可感，连点时稳定在这个水平不再往上叠。
const FIRE_TRAUMA_CAP := 0.35
## 开火后推量（0~1）。沿瞄准反方向把相机顶一下，读起来是"炮弹出膛"，
## 而随机抖只会读成"画面在抖"。
var _fire_push := 0.0
## 开火时的视场冲击：短促地把 FOV 推开一点再弹回，让"这一发已经打出去了"立刻可见
var _fov_punch := 0.0
var _fov_base := FOV_NORMAL
## 瞄准射线每帧只打一次：HUD 一帧里要问四五次准星状态
var _hit_frame := -1
var _hit_cache: Dictionary = {}
## 狙击镜景深。开镜时把焦点放在准星落点上，远处背景化开；
## 关镜时整帧清晰——街机节奏下不该让玩家在不开镜时看到虚化。
var _attrs: CameraAttributesPractical


func _ready() -> void:
	arm = SpringArm3D.new()
	arm.spring_length = ARM_NORMAL
	# 0.35 而不是 0.6：机位压低之后弹簧臂更容易顶到墙，margin 太大会把相机
	# 推到车身里面；留一点余量避免贴图穿帮即可。
	arm.margin = 0.35
	arm.collision_mask = 1
	arm.position = PIVOT_NORMAL
	add_child(arm)

	cam = Camera3D.new()
	cam.fov = FOV_NORMAL
	cam.far = 400.0
	cam.current = true
	_attrs = CameraAttributesPractical.new()
	_attrs.dof_blur_amount = 0.045
	_attrs.dof_blur_far_enabled = false
	cam.attributes = _attrs
	arm.add_child(cam)


## 换车 / 重生时把镜头与瞄准一起对齐到车头，避免开局镜头甩一圈
func reset_to(t: Tank) -> void:
	target = t
	var y: float = t.rotation.y if t != null else 0.0
	yaw = y
	aim_yaw = y
	aim_pitch = 0.0
	pitch = PITCH_BASE


# ---------------- 输入：只改瞄准方向 ----------------

func handle_mouse(rel: Vector2) -> void:
	var mult := (0.35 if sniper else 1.0) * Settings.mouse_sens
	var dy := rel.y * (-1.0 if Settings.invert_y else 1.0)
	_aim_by(rel.x * SENS * mult, dy * SENS * mult * PITCH_SENS)


## 右摇杆瞄准。与鼠标走不同通道：摇杆给的是角速度而非位移增量。
func handle_stick(v: Vector2, delta: float) -> void:
	var mult := (0.4 if sniper else 1.0) * Settings.gamepad_sens * STICK_RATE * delta
	var dy := v.y * (-1.0 if Settings.invert_y else 1.0)
	_aim_by(v.x * mult, dy * mult * PITCH_SENS)


## 鼠标下移 / 摇杆下压 = 压低炮管，所以俯仰取负号
func _aim_by(d_yaw: float, d_pitch: float) -> void:
	aim_yaw = wrapf(aim_yaw - d_yaw, -PI, PI)
	aim_pitch = clampf(aim_pitch - d_pitch, Tank.PITCH_MIN, Tank.PITCH_MAX)


func add_trauma(amount: float) -> void:
	_trauma = minf(1.0, _trauma + amount)


## 开火的瞬时反馈：后推 + 轻微抖动 + 视场冲击一起给。
##
## 震屏单独限幅（FIRE_TRAUMA_CAP），所以连点不会累积到"看不准"；
## 后推是定向的，衰减比抖动快，读起来是"炮弹出去了"而不是"画面在抖"。
func fire_kick(amount: float) -> void:
	# 只在不超过开火上限的前提下累加。不能直接取 min()：玩家刚被重炮打中
	# （trauma 0.8）时开一炮，min() 会把它压回 0.35——画面在一瞬间"安静下来"，
	# 读起来像震屏被打断了。开火只能把震屏推到自己那一档，不能收掉受伤的震屏。
	_trauma = maxf(_trauma, minf(FIRE_TRAUMA_CAP, _trauma + amount))
	_fire_push = minf(1.0, _fire_push + amount)
	_fov_punch = maxf(_fov_punch, 3.2)


func set_sniper(on: bool) -> void:
	sniper = on
	if on:
		sniper_zoom = 0


## 狙击镜换档。只在开镜时有效——没开镜时滚轮没有别的用途，但也没有理由让
## 玩家在不开镜时改到一个下次开镜才发现不一样的焦距。
func cycle_zoom(d: int) -> void:
	if not sniper:
		return
	sniper_zoom = clampi(sniper_zoom + d, 0, 1)
	Audio.play("switch")


func toggle_first_person() -> void:
	first_person = not first_person


## 镜头是否与炮塔对齐（炮手视角）。此时车体朝向不可见。
func gunner_view() -> bool:
	return sniper or first_person


# ---------------- 每帧：镜头跟车体 ----------------

func _process(delta: float) -> void:
	if target != null and is_instance_valid(target):
		global_position = global_position.lerp(target.global_position, minf(1.0, delta * 14.0))
	_follow(delta)

	rotation.y = yaw
	arm.rotation.x = -pitch
	var k := minf(1.0, delta * 9.0)
	arm.position = arm.position.lerp(_pivot(), k)
	arm.spring_length = lerpf(arm.spring_length, 0.0 if gunner_view() else ARM_NORMAL, k)
	_fov_base = lerpf(_fov_base, _fov(), k)
	_fov_punch = maxf(0.0, _fov_punch - delta * 22.0)
	cam.fov = _fov_base + _fov_punch
	cam.cull_mask = (CULL_ALL & ~LAYER_OWN_SHIELD) if first_person else CULL_ALL

	_trauma = maxf(0.0, _trauma - delta * 1.9)
	_fire_push = maxf(0.0, _fire_push - delta * 6.5)
	_shake_t += delta
	var s := _trauma * _trauma
	# 后推沿相机自身向上/向后各一点：单发一次，衰减 0.15 s 左右
	var kick := _fire_push * _fire_push * 0.9
	if s > 0.0:
		cam.h_offset = sin(_shake_t * 47.0) * 0.35 * s
		cam.v_offset = cos(_shake_t * 39.0) * 0.35 * s + kick
		arm.rotation.z = sin(_shake_t * 53.0) * 0.05 * s
	else:
		cam.h_offset = 0.0
		cam.v_offset = kick
		arm.rotation.z = 0.0

	# 狙击景深：焦点落在准星实际打中的那个点上，只有焦外才化开。
	# 用固定的"远处虚化"会把目标本身也糊掉——那正好是玩家最需要看清的地方。
	if _attrs != null:
		if sniper:
			var focus := 80.0
			if target != null and is_instance_valid(target):
				focus = cam.global_position.distance_to(aim_point())
			_attrs.dof_blur_far_enabled = true
			_attrs.dof_blur_far_distance = clampf(focus + 6.0, 12.0, 320.0)
			_attrs.dof_blur_far_transition = 35.0
		else:
			_attrs.dof_blur_far_enabled = false


## 三套取景位。狙击镜优先于第一人称：在车里也能举镜。
func _pivot() -> Vector3:
	if sniper:
		return PIVOT_SNIPER
	if first_person:
		return PIVOT_FIRST
	return PIVOT_NORMAL


func _fov() -> float:
	if sniper:
		return FOV_SNIPER_NARROW if sniper_zoom > 0 else FOV_SNIPER
	if first_person:
		return FOV_FIRST
	return FOV_NORMAL


## 镜头朝向的归属：
##   * 炮手视角（狙击镜 / 第一人称）—— 直接与炮管对齐
##   * 第三人称 —— 贴住车体后方；只有准星顶到死区边缘才把镜头拖走
func _follow(delta: float) -> void:
	if gunner_view():
		var w := minf(1.0, delta * 12.0)
		yaw = _approach(yaw, aim_yaw, w)
		pitch = lerpf(pitch, -aim_pitch, w)
		return

	if target != null and is_instance_valid(target):
		yaw = _approach(yaw, target.rotation.y, minf(1.0, delta * FOLLOW_RATE))
	var off := angle_difference(yaw, aim_yaw)
	if absf(off) > FOLLOW_DEADZONE:
		yaw = wrapf(yaw + off - signf(off) * FOLLOW_DEADZONE, -PI, PI)

	var want := clampf(PITCH_BASE - aim_pitch * PITCH_FOLLOW, PITCH_MIN, PITCH_MAX)
	pitch = lerpf(pitch, want, minf(1.0, delta * 6.0))


## 按最短弧线靠近目标角度
func _approach(from: float, to: float, weight: float) -> float:
	return wrapf(from + angle_difference(from, to) * weight, -PI, PI)


# ---------------- 瞄准射线 ----------------

## 瞄准方向的单位向量（世界系）
func aim_vector() -> Vector3:
	var cp := cos(aim_pitch)
	return Vector3(-sin(aim_yaw) * cp, sin(aim_pitch), -cos(aim_yaw) * cp)


## 射线起点取炮管的回转轴心：炮塔回转与炮管俯仰都不会挪动它，
## 所以准星不会因为炮塔还在追瞄而自己抖。
func _aim_origin() -> Vector3:
	if target != null and is_instance_valid(target) and target.barrel != null:
		return target.barrel.global_position
	return global_position + Vector3(0, 1.95, 0)


func _aim_hit() -> Dictionary:
	var f := Engine.get_process_frames()
	if f == _hit_frame:
		return _hit_cache
	_hit_frame = f
	_hit_cache = {}
	if cam == null:
		return _hit_cache
	var from := _aim_origin()
	var q := PhysicsRayQueryParameters3D.create(
			from, from + aim_vector() * AIM_RANGE, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	if target != null and is_instance_valid(target):
		q.exclude = [target.get_rid()]
	_hit_cache = cam.get_world_3d().direct_space_state.intersect_ray(q)
	return _hit_cache


## 准星射向世界的瞄准点：优先取实际命中点，未命中则取远处一点
func aim_point() -> Vector3:
	var hit := _aim_hit()
	if hit.is_empty():
		return _aim_origin() + aim_vector() * AIM_RANGE
	return hit["position"]


## 准星射线的起点（炮管回转轴心）。近战压炮要拿它算准星与敌车的水平关系。
func aim_origin() -> Vector3:
	return _aim_origin()


## 瞄准方向被外部改写过（近战压炮会写 aim_pitch）之后，本帧缓存的准星射线就过期了。
## 清掉缓存，下一次 aim_point() / aim_target() 按新角度重打一次。
## 每帧最多多打一条射线，而 HUD 一帧要问四五次，所以缓存本身仍然必须留着。
func invalidate_aim() -> void:
	_hit_frame = -1
	_hit_cache = {}


## 准星在屏幕上的位置。镜头锁车体之后它不再固定于屏幕中心。
## 返回 Vector2.INF 表示瞄准点在相机背后，不该画。
func aim_screen_point() -> Vector2:
	var w := aim_point()
	if cam == null or cam.is_position_behind(w):
		return Vector2.INF
	return cam.unproject_position(w)


## 准星下方的坦克（用于准星变色提示）
func aim_target() -> Tank:
	var hit := _aim_hit()
	if hit.is_empty():
		return null
	var c = hit["collider"]
	# 命中结果按"渲染帧"缓存，而坦克可能在同一个渲染帧里被击毁并 queue_free
	# （炮弹命中发生在物理帧）。直接对已释放实例做 `is` 判断会抛错，还会把 HUD 的
	# 整个 _draw 打断，所以先验一遍有效性。
	if not is_instance_valid(c):
		return null
	return c if c is Tank else null


## 准星是否真能打到：炮管俯仰够不着、或炮口到准星之间被挡住都算不可达。
## HUD 据此把准星变灰，避免"明明按了开火却打在墙根"。
func aim_reachable() -> bool:
	if target == null or not is_instance_valid(target) or not target.alive:
		return false
	var pt := aim_point()

	var from: Vector3 = target.muzzle_pos()
	# HE 走抛物线：用直线去判"打不到"会把一票其实能吊进去的落点判成灰色。
	# 炮管抬角对 HE 也不是限制——发射方向由 lob_dir() 解出来，与机械上限无关。
	if target.shell_kind == Shell.Kind.HE and target.can_use_he:
		return _he_reachable(from, pt)
	if not target.can_elevate_to(pt):
		return false

	var d := pt - from
	var dist := d.length()
	if dist < 1.0:
		return true
	var space := cam.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + d, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [target.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	# 命中点明显早于准星落点，说明中途有掩体挡着
	var hit_dist: float = (hit["position"] as Vector3 - from).length()
	return hit_dist > dist * 0.92


## HE 能不能吊到准星上：先看弹道仰角是否在解算范围内，
## 再沿抛物线分段做射线检测，确认中途没有掩体。
func _he_reachable(from: Vector3, pt: Vector3) -> bool:
	var lob := Shell.lob_dir(from, pt, Vector3.ZERO)
	if lob == Vector3.ZERO:
		return false
	if asin(clampf(lob.y, -1.0, 1.0)) > Shell.HE_SOLVE_MAX:
		return false
	var pts := Shell.trajectory(from, lob, 60)
	if pts.size() < 2:
		return true
	var space := cam.get_world_3d().direct_space_state
	for i in range(1, pts.size()):
		var q := PhysicsRayQueryParameters3D.create(pts[i - 1], pts[i],
				Tank.LAYER_WORLD | Tank.LAYER_TANK)
		q.exclude = [target.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		# 打在目标身上（落点附近）算命中，打在中途算被挡
		return (hit["position"] as Vector3).distance_to(pt) < 3.0
	return true


## HE 落点预览：当前弹种是 HE 时返回抛物线的采样点（世界坐标），否则空数组。
## 抛物线从炮口出发、终点对准准星打中的那个点，所以它画出来的就是"这一发会怎么飞"。
## 没有它，HE 的抬升量只能靠试射去猜。
func he_preview() -> PackedVector3Array:
	if target == null or not is_instance_valid(target) or not target.alive:
		return PackedVector3Array()
	if not target.can_use_he or target.shell_kind != Shell.Kind.HE:
		return PackedVector3Array()
	var from: Vector3 = target.muzzle_pos()
	var pt := aim_point()
	var lob := Shell.lob_dir(from, pt, Vector3.ZERO)
	if lob == Vector3.ZERO:
		return PackedVector3Array()
	if asin(clampf(lob.y, -1.0, 1.0)) > Shell.HE_SOLVE_MAX:
		return PackedVector3Array()
	return Shell.trajectory(from, lob, 60)


## 炮管实际指向在屏幕上的位置。与准星重合时，即"已对准"。
## 返回 Vector2.INF 表示该点在相机背后，不该画。
func muzzle_screen_point() -> Vector2:
	if target == null or not is_instance_valid(target) or not target.alive:
		return Vector2.INF
	var from := target.muzzle_pos()
	var dir := target.aim_dir()
	var to := from + dir * AIM_RANGE

	var space := cam.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [target.get_rid()]
	var hit := space.intersect_ray(q)
	var world: Vector3 = hit["position"] if not hit.is_empty() else to
	if cam.is_position_behind(world):
		return Vector2.INF
	return cam.unproject_position(world)
