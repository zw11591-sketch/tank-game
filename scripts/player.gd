class_name Player
extends Tank
## 玩家坦克：车体走动作映射（键盘/方向键/手柄通吃），炮塔跟随准星，
## 另有冲刺与烟雾弹两个战术技能，以及按车速变调的发动机循环音。
##
## 所有输入都在这里读取，不再由 main.gd 转发按键事件。
## tick() 跑在物理帧（120Hz），is_action_just_pressed 在物理帧同样只触发一次，
## 所以切弹/冲刺/烟雾这类"点一下"的动作不会连发。

const BOOST_TIME := 2.2
const BOOST_CD := 9.0
const BOOST_MULT := 1.75
const SMOKE_TIME := 7.0
const SMOKE_CD := 22.0
## 引擎过载增益的机动加成
const OVERDRIVE_MULT := 1.35
## 装填剩余不超过这个秒数时按下开火键，会被记住并在装填完成瞬间自动击发。
## 没有它的话，玩家必须精确等到进度环走满才按键，手感很"黏"。
##
## 现在它是"空击提示"的门槛，而不是击发的门槛：见下面 `_pending_shot`。
## 点击永远会被记住直到打出一发，所以"点一下 = 一定打出去一发"与装填时长无关。
const DRY_WAIT := 0.30
## 空击提示的最短间隔，避免狂点鼠标时提示音糊成一片
const DRY_CLICK_CD := 0.18
## 按住开火键不放时的连发间隔（秒）。
##
## 点击永远当帧击发，这一档只约束"按住"。装填压到 0.05~0.09 s 之后，
## `is_action_pressed("fire")` 会把按住读成 11~20 发/秒——一梭子清空整波敌人，
## 名册里"装填"这一条也彻底失去意义（每辆车都成了同一挺机枪）。
##
## 取 0.22 s（≈4.5 发/秒）：想让火力更猛就快点点，点击率是玩家的上限；
## 按住只是"稳定的持续火力"。两条通道都不会让"点了没反应"重新出现——
## 点击走 `_pending_shot`，与这个间隔无关。
const HOLD_FIRE_INTERVAL := 0.22
## 快速装填增益对"按住连发"间隔的缩放。0.22 x 0.55 ≈ 0.12 s（约 8 发/秒）。
## 增益的意义是"按住时火力密度真的上去了"，而不是改一个玩家点不出来也看不出的装填时间。
const RAPID_HOLD_SCALE := 0.55

## 近距离交战判定。三个近战辅助共用这一档距离：
##   * 压炮：把瞄准角收回到敌车车体中心（`_apply_close_assist`）
## 贴脸时玩家的操作是"甩过去就开火"，炮塔转完才是正解的话，那一发已经打在车侧了。
##
## 压炮的搜索半径取 80 m（整个战场对角 136 m 的一半），判据是**几何**而不是距离：
## 只要准星射线在敌车所在的位置上高度不超过看得见的塔顶（见 `AIM_PRESS_TOP_PAD`），
## 就算"玩家瞄的是这辆车"。距离本身不参与判定，所以不存在"到某个距离突然失效"的
## 边界——原来这一档是 18 m，辅助权重恰好在 18 m 处收到 0，于是 18 m 那一行
## 弹道以 +2.4° 抬着飞、爬升 20.8 m 仍打空（tools/close_aim_probe.gd）；
## 把边界改到 24 m，同样的失败就整体平移到 24 m 那一行。边界在哪儿都不对，
## 因为问题不是"太远了"，而是"准星明明压着车，弹道却从车上沿过去了"。
const CLOSE_AIM_RANGE := 80.0
## 炮塔回转加速与"扣扳机吃残差"的有效距离。
##
## 这两个眼神比压炮短得多：压炮只是把落点收到车体上（玩家看不出炮弹本来要飞哪），
## 而甩炮加速与吃残差是**手感外挂**——3~18 m 上玩家是"甩过去就打"，再远就该
## 老老实实让炮塔转完。炮塔转速是车型差异（歼击车还有射界），不能被整段推翻。
const CLOSE_TURRET_RANGE := 18.0
## 近距离炮塔回转倍率。只在这一帧的 aim_at_angles() 里生效，
## 远距离与倒计时预瞄仍是名册里的原值（炮塔转速是车型差异，不能被推翻）。
const CLOSE_TURRET_BOOST := 1.9
## 压炮的落点高度（离地）。车体命中体是 0~2.0 m 的圆柱，1.0 m 就是它的中心：
## 弹道只要指向它，就一定从正面落进车体，而不是从车顶或炮塔上沿擦过去。
const CLOSE_AIM_Y := 1.0
## 压炮的竖直余量（m，叠加在看得见的炮塔顶上）。
##
## 玩家把准星压在炮塔顶边缘时，画面上"压住了"，射线却从车顶上方几厘米处穿过——
## 命中体是圆柱，不可能严丝合缝地等于模型。留 0.45 m，于是"瞄在塔顶那块边缘上"
## 一律算作瞄在车上，弹道被压到车体中心。超过这个高度就是玩家真的要打天上去了，
## 那时一点都不介入（准星往车顶上方甩半米就能自由抬高）。
const AIM_PRESS_TOP_PAD := 0.45
## 横向收束的有效距离（m）。远射不动横向：那里准星与敌车的横向偏差就是提前量，
## 收它会和玩家自己算的提前量打架。压炮的竖直修正没有这个问题（AP 弹不吃重力，
## 也没有竖直提前量），所以两者的距离档位不一样。
const CLOSE_AIM_LATERAL_RANGE := 24.0
## 近战横向收束比例：落点从"车体轮廓之外"收进 `body_radius × CLOSE_AIM_SAFE` 以内。
##
## 车体命中圆半径 1.5 m，而车体看起来是一个 3.4 × 4.4 m 的方盒子——四角在命中圆之外。
## 近距离玩家瞄的恰好是正面靠角的那一块（那是画面里最大的一块轮廓），射线就从车侧
## 擦过去；而这一帧炮管是按正仰角抬着的，擦过去之后 AP 弹没有重力，6 秒能飞出一百多米，
## 屏幕上就是"瞄准了却打到天上"。0.8 倍半径留出 0.3 m 余量，擦边变成实打实的命中。
const CLOSE_AIM_SAFE := 0.80
## 横向收束的最大角度。收得动的前提是"准星本来就压在车上"，但近距离一辆车就有
## 3.4 m 宽，从正面左角收到车体里可以差二十多度——不封顶的话准星会被整段拽走。
const CLOSE_AIM_MAX_YAW := deg_to_rad(12.0)
## 备用判据的横向余量（m，叠加在车身半径上）。
##
## 车体看起来有 1.7 m 的半宽，而命中圆柱只有 1.5 m：准星压在正面靠角的那一块时，
## 射线本身什么都不碰（炮塔命中体半径更小），只能靠这条"水平方向上指着这辆车"兜住。
## 0.75 让 3 m 上完全够不到的两侧轮廓都落在判据内，同时不会把侧后方的另一辆车拽进来。
const CLOSE_AIM_GIRTH := 0.75
## 备用判据的角度上限。3 m 处一辆 3.4 m 宽的车，两侧轮廓就是 ±30°，
## 所以 35° 刚好覆盖"瞄准可见的车身"，再宽就会开始隔着空地吸别的车。
const CLOSE_AIM_MAX_ANGLE := deg_to_rad(35.0)
## 扣扳机时允许直接吃掉的最大炮塔残差。
## 超出这个角度说明炮塔压根还没转过来，那就该玩家自己等——这不是"点了没反应"，
## 而是"准星都还没压上去"。
const FIRE_SNAP_MAX := deg_to_rad(10.0)

## ---- 镜头相对驾驶的调参（Settings.drive_relative 打开时生效） ----
## 航向误差达到这个角度就给满舵；更小则按比例收舵，免得车头原地来回摆。
##
## 原来取 26°：最后 26° 要走一条指数曲线（时间常数 turn_speed/band ≈ 0.18 秒），
## 于是"按一下 A"要 1.0 秒才停稳，而前 45° 只用了 0.35 秒——尾巴拖得很长，
## 玩家的感受就是"转向不灵活"（tools/TurnProbe.tscn 的 rel_rest_A）。
## 收到 16° 后同一段收敛只要约 0.5 秒，整段 90° 从 1.0 秒压到 0.7 秒。
##
## 不能再往小里收：这一档同时是"行驶中贴着直线走时不抖"的滤波器。
## 转向是**一阶比例控制**（rotation 直接积分，没有角惯性），band 越小增益越高，
## 12° 以下时鼠标一动车头就会跟着抽一下。
const STEER_BAND := deg_to_rad(16.0)
## 航向误差小于这一档时油门不衰减。走廊里的小幅修正属于"贴着直行"，
## 让它掉速只会让窄通道里的手感变"黏"——那是纯损失，没有换来任何转向。
const ALIGN_FREE := deg_to_rad(0.0)
## 航向误差 90°（目标方向在正侧面）时油门收到这一档。
##
## 窄通道里过弯全靠它。原来是 0.5：车在半油门下一边转一边冲出 7.5 m/s，
## 而 4 m 宽的通道只给 0.5 m 侧向余量，于是车头还没转过来就已经顶上侧墙，
## 之后 heading 一直指着墙、油门一直顶着墙——实测 1 格宽走廊里过 90° 弯
## 会磨到 0.8 m/s 出不来（tools/squeeze_probe.gd 的 bent 一行）。
## 收到 0.15 之后同样的输入变成"刹住 + 原地转头 + 再走"，
## 这正是 drive() 里那条"先把头调过来，而不是画一个大圆弧甩出去"的本意。
const TURN_THROTTLE_FLOOR := 0.35
## 目标方向偏到车尾这一侧（超过该角度）就改用倒车贴近，而不是原地掉头 180°。
## 取值略大于 90°，于是按住 S 永远是干净的倒车、不会误触发掉头
const REVERSE_ARC := deg_to_rad(100.0)
## "沿墙滑行仍算在往目标方向走"的判据：滑行方向与目标方向的夹角上限（点积）。
## 0.87 ≈ 30°。取得比 STEER_BAND（26°）略宽，是因为滑行方向本身就滞后一帧、
## 又带着沿墙投影的偏折，卡太死会把正常的走廊内直线行驶也判成"没在往对的方向走"。
const SLIDE_ALIGN_DOT := 0.87
## 判"有没有在滑行"的最低速度（m/s）。低于它说明车基本停住了（顶在墙上或刚起步），
## 这时没有方向可言，一律收回那一脚免掉的折扣。
const SLIDE_MIN_SPEED := 2.0
## 方向键的死区：低于此值视为没推方向，车体不再自动找朝向
const DRIVE_DEADZONE := 0.08

## 残骸卡死自救。踩着油门连续这么久、位移仍不足阈值，就把最近的残骸提前塌掉。
## 2.5 s 足够排除"贴着墙蹭一下"，又不至于让玩家盯着残骸干等一整个燃烧期。
const STUCK_RESCUE_TIME := 2.5
## 判"没在动"的位移阈值（米）。正常行驶 2.5 s 至少走十几米；
## 被残骸顶住时只有碰撞解算带来的厘米级抖动。
const STUCK_MIN_MOVE := 0.6
## 自救只处理残骸：这个半径内没有还没塌的残骸就不动手。顶在砖墙上、
## 被友军挤住这类情况不该触发清场。
const STUCK_WRECK_RADIUS := 14.0

var rig: CameraRig

## 选定的车型 id（TankRoster.ORDER 里的一项）。必须在 add_child() 之前写入：
## Player._ready() 要按它装配碰撞体尺寸与全部属性，来不及之后再补。
var tank_id := TankRoster.DEFAULT_ID
## 本车的型号定义（TankRoster.spec 的副本），_ready 时填入
var spec: Dictionary = {}

var boost_t := 0.0
var boost_cd := 0.0
var smoke_t := 0.0
var smoke_cd := 0.0
## 本车的冲刺时长与两个技能的冷却上限。名册按车型给：侦察车靠短冷却活着，
## 重型车用长冷却平衡它的硬度。默认值即基准车的设定。
var boost_time := BOOST_TIME
var boost_cd_max := BOOST_CD
var smoke_cd_max := SMOKE_CD
## 引擎过载增益剩余时间（由道具写入）
var overdrive_t := 0.0
## 空击反馈：装填未完成时按下开火键会点亮它，HUD 据此把准星闪一下红
var dry_flash := 0.0
## 命中反馈：炮弹打到目标时由 main.on_shell_feedback 点亮，HUD 据此打一个命中标记
var hit_flash := 0.0
var hit_ricochet := false

var _base_speed := 15.0
var _base_turn := 2.5
## 本下点击是否已经排上一发。**不设过期时间**：点一下就必须打出去一发，
## 装填还要 0.05 秒还是 5 秒只是"什么时候响"，不是"响不响"。
## 以前这里是一个 0.30 秒的缓冲窗口，窗口外的点击被丢掉——读起来就是"点击没反应"。
var _pending_shot := false
## 事件层锁存的开火按下。输入事件偶尔落在两个物理帧之间，只靠 tick() 轮询
## `is_action_just_pressed()` 会整下丢掉；`_unhandled_input()` 收到的事件不会丢。
var _fire_latch := false
var _dry_cd := 0.0
## 开火键已连续按住多久（秒）。松开即清零，于是"按住连发"按 HOLD_FIRE_INTERVAL 走，
## 而每一次新的按下都还是当帧击发。
var _hold_t := 0.0
## 本帧的舵是不是玩家用 A/D 亲自给的（见 _carry_aim_with_steer）。
## W 的自动对齐由准星驱动车头，不能反向补准星；只有 A/D 的转角要带着准星一起转。
var _steer_aim := false
## 卡死自救的计时与锚点（见 _check_stuck）
var _stuck_t := 0.0
var _stuck_anchor := Vector3.ZERO
var _engine: AudioStreamPlayer3D


## 开火键在事件层先锁存一道。
##
## `Input.is_action_just_pressed()` 的"按下"只在某一个物理帧里为真，而输入事件是按
## 渲染帧到达的：事件偶尔会落在两个物理帧之间，那个物理帧上既不"刚按下"也不
## "按住"，整下点击就消失了——玩家读到的就是"点了没反应"，然后不得不再点一次。
## 事件本身不会丢，所以把"按下"这个事实记在这里，由 tick() 消费。
##
## 只锁存按下、不锁存松开：排上的那一发不会因为松手被取消（点击就该打出去）。
func _unhandled_input(event: InputEvent) -> void:
	if not alive or not is_local:
		return
	if event.is_action_pressed("fire"):
		_fire_latch = true


func _ready() -> void:
	is_player = true
	display_name = "指挥官"
	_apply_roster()
	super._ready()
	# 出生即可开火。Tank._ready 里刻意留了 35% 的装填进度（那是为了"刚出生不能马上打"
	# 的旧手感），但玩家能开火时早就过了倒计时；留这 0.1~0.2 秒只会让"重生后第一下
	# 点鼠标没反应"。点击就该发射，从第一发开始。
	reload_t = 0.0
	_build_engine_audio()

	# 车头/车尾朝向标识。炮塔独立回转，光看炮管无法判断车头朝向，
	# 而车体本身前后几乎对称——没有这组标识就会"开起来不顺手"。
	var guide := HullGuide.new()
	add_child(guide)
	guide.setup(_hull_size, accent_color())
	# 自车护盾球会包住第一人称镜头，挪到独立视觉层交给相机剔除
	if _shield_mesh != null:
		_shield_mesh.layers = CameraRig.LAYER_OWN_SHIELD


## 按名册装配本车。必须在 super._ready() 之前调用：
## 碰撞体是 _ready() 里按 body_radius / body_length 建的，属性也是那时快照
## 到 hp 上的，晚一步就只能改到"下一辆车"去。
##
## 尺寸取自 TankRoster.DIMS，与 Blender 侧的建模尺寸表同源。
## 型号自己的车身宽度就是它的玩法代价：铁砧 3.8 米宽在单格通道里明显迟钝，
## 这不是调参失误，而是"正面近乎免疫"换来的。
func _apply_roster() -> void:
	spec = TankRoster.spec(tank_id)
	tank_id = String(spec["id"])
	var d := TankRoster.dims(model_key())
	body_radius = float(d["radius"])
	body_length = float(d["length"])
	_hull_size = d["hull"]
	aim_height = float(d["aim_y"])

	max_hp = int(spec["hp"])
	move_speed = float(spec["speed"])
	turn_speed = float(spec["turn"])
	turret_speed = float(spec["turret"])
	turret_snap = float(spec["snap"])
	reload_time = float(spec["reload"])
	damage = int(spec["damage"])
	armor_front = float(spec["af"])
	armor_side = float(spec["as"])
	armor_rear = float(spec["ar"])
	can_use_he = bool(spec["he"])
	he_mult = float(spec["he_mult"])
	he_splash = float(spec["he_splash"])
	turret_limit = float(spec["turret_limit"])

	boost_time = float(spec["boost_time"])
	boost_cd_max = float(spec["boost_cd"])
	smoke_cd_max = float(spec["smoke_cd"])

	_base_speed = move_speed
	_base_turn = turn_speed


func model_key() -> String:
	return String(spec.get("model", "tank_player"))


func hull_color() -> Color:
	var c: Color = spec.get("hull_color", Color(0.30, 0.52, 0.34))
	return c


func accent_color() -> Color:
	var c: Color = spec.get("accent_color", Color(0.95, 0.82, 0.25))
	return c


## HUD 用的短名（"山猫" / "游隼" / …）
func tank_name() -> String:
	return String(spec.get("name", "坦克"))


## 难度只做**乘性**调整，不做绝对值覆盖。
##
## 原来是硬写 600 / 400 与 0.8 / 1.15——那是按单一车型定的数，一旦玩家能选车，
## 同一组绝对值会把"选轻型"这件事直接抹平（轻型 330 血被改成 600 等于白选）。
## 乘性系数对基准车算出来与原来完全相同（480×1.25=600、0.95×0.842=0.80），
## 对其余车型则保留了名册内部的相对差距。
const DIFF_HP := [1.25, 1.0, 0.8333]
const DIFF_RELOAD := [0.8421, 1.0, 1.2105]


func apply_difficulty(diff: int) -> void:
	var d := clampi(diff, 0, 2)
	max_hp = int(round(max_hp * DIFF_HP[d]))
	reload_time = reload_time * DIFF_RELOAD[d]
	hp = max_hp


func tick(delta: float) -> void:
	# 远端队友的车在房主 / 客户端两侧都只是快照复制品：不读输入、不推进物理。
	# 它们的位置与朝向由 Tank._apply_net_interp() 负责。
	if not is_local or not alive or rig == null:
		return

	boost_cd = maxf(0.0, boost_cd - delta)
	smoke_cd = maxf(0.0, smoke_cd - delta)
	boost_t = maxf(0.0, boost_t - delta)
	smoke_t = maxf(0.0, smoke_t - delta)
	overdrive_t = maxf(0.0, overdrive_t - delta)
	dry_flash = maxf(0.0, dry_flash - delta)
	hit_flash = maxf(0.0, hit_flash - delta)
	expose_t = maxf(0.0, expose_t - delta)
	_dry_cd = maxf(0.0, _dry_cd - delta)

	# 冲刺与引擎过载可以叠加：两个都在的时候机动性相当夸张，但代价是冷却与持续时间
	var mult := 1.0
	if boost_t > 0.0:
		mult *= BOOST_MULT
	if overdrive_t > 0.0:
		mult *= OVERDRIVE_MULT
	move_speed = _base_speed * mult
	turn_speed = _base_turn * (1.25 if overdrive_t > 0.0 else 1.0)

	# 鼠标在 ready / play / clear 三个状态都处于捕获状态，所以这三个状态都该有瞄准响应。
	# 其中只有开场倒计时(ready)刻意锁油门——肃清结算(clear)敌人已清空，没有锁的理由。
	var controllable: bool = game.state == "ready" or game.state == "play" or game.state == "clear"
	if not controllable:
		# 标题 / 选关 / 暂停 / 结束：松开油门，但保留惯性衰减
		_hold_t = 0.0
		_steer_aim = false
		drive(0.0, 0.0, delta)
		_update_engine_audio()
		return

	# ---- 车体：摇杆给模拟量，键盘给 ±1。开场倒计时期间油门锁死 ----
	var fwd := 0.0
	var right := 0.0
	if game.state != "ready":
		fwd = Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
		right = Input.get_action_strength("turn_right") - Input.get_action_strength("turn_left")
	# 车身这一帧实际转过的角度要补进准星方向（见 _carry_aim_with_steer）。
	# 必须取 drive() 前后的差：_limit_turn() 会按几何把转角削掉一部分。
	var yaw_before := rotation.y
	var cmd := _relative_drive(fwd, right) if Settings.drive_relative else Vector2(fwd, right)
	drive(cmd.x, cmd.y, delta)
	_carry_aim_with_steer(yaw_before)
	# 残骸卡死自救：必须放在 drive() 之后，读到的才是这一帧解算完的位置
	_check_stuck(delta, fwd)

	# ---- 转塔：右摇杆是鼠标之外的第二套瞄准 ----
	_look_with_stick(delta)

	# ---- 瞄准：鼠标给的是世界角度，炮塔按自身回转速度去追 ----
	# 俯仰**不做平滑**：aim_pitch 就是玩家给的角度，炮管当帧照做。
	# 曾经有一段 `_converge_pitch()`，在准星压住敌车时把炮管往敌车的 `aim_height`
	# （耳轴高度）拽。敌人的耳轴来自基类默认的 1.9 m，对耳轴只有 1.54 m 的歼击车
	# 是**向上**收——于是无论准星压在哪，炮管都被钉在 +5° 左右，鼠标往下拖 1200 px
	# 也压不下来（tools/aim_feel_probe.gd 的 reach 全部 >1200px）。
	# 那种"收敛"修的是错问题，已经删掉；下面那条只压不抬，方向是反的。
	#
	# 近距离再把炮塔回转临时加速一档。玩家的动作是"把准星甩到敌车身上就扣扳机"，
	# 而炮塔仍按 4.6 rad/s 去追：3 m 处残留 20° 就是约 1 m 横向偏差，正好把半径
	# 0.93 m 的炮塔命中体打空——弹道从车侧擦过去，屏幕上同样是"瞄准了却没打中"。
	# 只对 CLOSE_AIM_RANGE 以内的目标生效，远距离"先等炮塔转过去"的手感不变。
	#
	# 近战压炮要放在回转之前：它会把 rig.aim_pitch 压低，炮塔与准星射线都要按
	# 压低后的角度走，否则准星在顶上、炮管在下面，两边各说各话。
	_apply_close_assist()

	var slew := turret_speed
	if _close_target():
		turret_speed = slew * CLOSE_TURRET_BOOST
	aim_at_angles(rig.aim_yaw, rig.aim_pitch, delta)
	turret_speed = slew
	# 近战时炮口（车头前 3.8 m）可能已经越过对方车体，fire() 需要知道准星落在哪
	# 才能把出发点收回来。准星射线本来每帧就要打一次（HUD 要用），这里不额外花销。
	aim_point = rig.aim_point()

	# 视角切换在倒计时与结算阶段也该可用，所以放在开火判定之前
	if InputSetup.edge("toggle_view"):
		rig.toggle_first_person()

	if game.state != "play":
		# 倒计时与结算阶段可以环视、预瞄、挪车，但不能开火与放技能。
		# 同时清掉按住计时：否则倒计时期间按住 RT，开局第一帧就会被当成"已经按住很久"直接击发。
		_hold_t = 0.0
		_update_engine_audio()
		return

	# ---- 开火：点一下 = 打出一发 ----
	# 走 InputSetup.edge() 而不是 is_action_just_pressed()：后者在 120Hz 物理帧下
	# 会把一次左键读成两次，缓冲出第二发。见 InputSetup.edge() 的注释。
	#
	# 两条输入通道都算数：edge() 处理"物理帧上读到的按下"，`_fire_latch` 处理
	# "落在两个物理帧之间、轮询看不到的那一下"。后者是"点了没反应"的最后一个来源，
	# 所以按下本身在事件层就锁存（见 _unhandled_input）。
	rig.set_sniper(Input.is_action_pressed("aim_scope"))
	if InputSetup.edge("zoom_in"):
		rig.cycle_zoom(1)
	elif InputSetup.edge("zoom_out"):
		rig.cycle_zoom(-1)
	# 事件锁存优先：同一次按下在下一个物理帧还会被 is_action_just_pressed() 再报一次
	# （键鼠事件按渲染帧到达，120 Hz 物理会读两遍），所以消费锁存时要把 edge() 的
	# 时间锁一起推掉——否则"点一下"会排出两发，第二发看起来像凭空多出来的。
	if _fire_latch:
		_fire_latch = false
		InputSetup.suppress("fire")
		_pending_shot = true
	elif InputSetup.edge("fire"):
		_pending_shot = true
	# 装填还剩很久才给空膛提示：几发子弹的间隙里"咔"一声只会让人以为打空了。
	if _pending_shot and reload_t > DRY_WAIT:
		_dry_click()
	# 点击（含事件锁存）当帧就击发；按住则按 HOLD_FIRE_INTERVAL 的节奏连发，
	# 否则 0.05~0.09 s 的装填会把按住读成 11~20 发/秒的机枪。
	var held := Input.is_action_pressed("fire")
	_hold_t = _hold_t + delta if held else 0.0
	# 快速装填增益必须作用在"按住连发"这一档上：射速的真实上限不是装填时间
	# （0.06 s 已经被压到点击速度之下了），而是这个 0.22 s 的间隔。
	# 只改 reload_rate 时增益几乎看不出来——玩家点了半天才发现"好像快了点"。
	var hold_interval := HOLD_FIRE_INTERVAL * (RAPID_HOLD_SCALE if rapid_buff_t > 0.0 else 1.0)
	var want_shot := _pending_shot or (held and _hold_t >= hold_interval)
	if want_shot:
		# 准星已经压在敌车身上时，把最后几度的炮塔残差吃掉：点下去就该有结果
		_snap_turret_to_aim()
		if fire():
			_pending_shot = false
			_hold_t = 0.0
			dry_flash = 0.0
			rig.fire_kick(0.45)

	# ---- 技能与弹种 ----
	if InputSetup.edge("switch_shell"):
		toggle_shell()
	if InputSetup.edge("boost"):
		_start_boost()
	if InputSetup.edge("smoke"):
		_drop_smoke()

	_update_engine_audio()


# ---------------- 驾驶 ----------------

## 残骸卡死自救。
##
## 残骸在燃烧期是真实的物理阻挡，而玩家推不动它、炮弹又不检测这一层
## （见 Tank._spawn_wreck）。如果它正好死在只有一条路的走廊里，玩家在燃烧期
## 内就是过不去——这一段给玩家一个不依赖地图几何的出口。
##
## 只在"踩着油门却几乎不动"时触发，并且只塌最近的残骸：顶在砖墙上、被友军
## 挤住这类情况不该触发清场。不直接把玩家传送走——传送会连镜头一起跳，
## 而且很容易把车塞进另一个几何死角。
func _check_stuck(delta: float, throttle: float) -> void:
	if game.state != "play" or absf(throttle) < 0.5:
		_stuck_t = 0.0
		_stuck_anchor = global_position
		return
	_stuck_t += delta
	if _stuck_t < STUCK_RESCUE_TIME:
		return
	# 这一段时间里真的挪开了，就重新计时
	if global_position.distance_to(_stuck_anchor) > STUCK_MIN_MOVE:
		_stuck_t = 0.0
		_stuck_anchor = global_position
		return
	if arena != null:
		arena.collapse_wreck_near(global_position, STUCK_WRECK_RADIUS)
	# 无论有没有找到残骸都重新计时：没有残骸时也要隔一段时间再试，
	# 而不是每帧都扫一遍残骸列表
	_stuck_t = 0.0
	_stuck_anchor = global_position


## 镜头相对驾驶：把"屏幕上想去的方向"换算成车体的油门与舵角。
##
## 车体前后几乎对称、炮塔又能独立回转，所以"按 W 到底会往哪走"一直要靠玩家
## 自己记住车头朝向——这就是操控不顺手的根源。这里改成以准星朝向为参照：
## W 往准星方向走、S 退向镜头，车体自己转过去对齐。
## 于是每个方向键都对应一个屏幕方向，车头在哪变得无关紧要。
##
## **A/D 是真正的转向输入**，不是"往屏幕左/右平移"：
##   * 只按 A/D —— 原地转向（下面的 early return），按住就一直在转；
##   * W/S + A/D —— 一边走一边转，转过去的朝向会留在准星上（`_carry_aim_with_steer`），
##     松手即沿新朝向直行，而不是转 45° 又被拉回去。
##
## 参照必须是准星（rig.aim_yaw）而不是相机（rig.yaw）——相机是**派生量**，
## 随时被拖向车体朝向，拿它当参照就是一个自洽的反馈回路，车体永远扳不回正轨。
## 详见下面 want_yaw 处的注释。
##
## 第一人称与狙击镜下镜头与炮塔对齐（CameraRig.gunner_view），此时两者一致，
## W 就是"朝炮口方向开"，同样自洽。
##
## 返回 Vector2(throttle, steer)，与 Tank.drive() 的两个入参一致。
func _relative_drive(fwd: float, right: float) -> Vector2:
	# A/D 是否真的给了输入。只有它能把车头转角补进准星（见 _carry_aim_with_steer）：
	# W 的自动对齐是"车头追准星"，不能反过来让准星跟着车头转。
	_steer_aim = absf(right) >= DRIVE_DEADZONE
	var mag := minf(Vector2(fwd, right).length(), 1.0)
	if mag < DRIVE_DEADZONE:
		return Vector2.ZERO

	# 只有 A/D：原地转向，车体不再横着走。
	#
	# 相对驾驶的代价是"失去原地转车"（见 settings.gd 的注释）。而这个代价比想象中
	# 贵：车体朝向就是装甲朝向，歼击车的炮塔只有 ±40° 射界——玩家按 A 的本意几乎
	# 总是"把车头转过去"，而不是"横着平移"。原来这里读到的是"目标航向 = 屏幕左方
	# 90°"，车一边以 35% 油门斜蹭一边转，转到 90° 就再没有转向输入了：玩家看到的
	# 是"按住 A 只转一下、之后就一直横着开"，在窄通道里更是只转到 49° 就被几何卡住
	# （tools/TurnProbe.tscn 的 rel_rest_A_wall）。
	#
	# 现在没有油门输入时舵角直接取 A/D：按住就一直在转，转多少由玩家自己松手决定。
	# 油门为 0 还顺带让 Tank.drive() 给满转向权限（那一档平时被车速插值压到 0.78，
	# 是防止"行驶中减速后仍然全速拧舵"的稳定措施，原地转向不需要它）。
	if absf(fwd) < DRIVE_DEADZONE and absf(right) >= DRIVE_DEADZONE:
		return Vector2(0.0, right)

	# 屏幕方向 -> 世界航向。参照系取**准星朝向**而不是相机朝向：
	# 相机的 _follow() 每帧都在把 yaw 拖向车体自身朝向（第三人称镜头要贴在车尾后面），
	# 于是"以 rig.yaw 为参照"等于"以车体自己为参照"——车头偏多少，参照就跟着偏多少，
	# 角度误差恒等于零，车体永远不会被扳回正轨。这不是转速不够，是反馈回路本身自洽，
	# 所以只会一直保持进场时的那点偏角往前蹭（tools/wedge_probe.gd 的 gate ang=±10：
	# 单格宽门口的 0.5 m 余量被这点偏角吃光，车头顶在门框上以 0.8 m/s 磨到永远）。
	#
	# rig.aim_yaw 是鼠标 / 右摇杆直接驱动的量，与车体朝向无因果关系，才是真正的参照。
	# 炮手视角（狙击镜 / 第一人称）下两者本来就一致，此改动无影响；
	# 第三人称下两者最多差 FOLLOW_DEADZONE（42°），而那正是"玩家在看哪里"。
	var want_yaw := wrapf(rig.aim_yaw + atan2(-right, fwd), -PI, PI)
	# err 是"要加到车体朝向上的角度"，与 drive() 里 rotation.y 的增量同号
	var err := angle_difference(rotation.y, want_yaw)

	var dir := 1.0
	if absf(err) > REVERSE_ARC:
		# 目标在车尾那侧：倒车贴过去比掉头快，也让按住 S 就是干净的倒车
		dir = -1.0
		err = angle_difference(rotation.y, wrapf(want_yaw + PI, -PI, PI))

	# drive() 里 rotation.y += -steer * ...，所以舵角取 err 的反号
	var steer := clampf(-err / STEER_BAND, -1.0, 1.0)
	# 偏差越大油门越小：让车先转头，避免高速下画出一个大圆弧。
	# ALIGN_FREE 以内不衰减（走廊里的直线微调不该掉速），之后一路收到
	# TURN_THROTTLE_FLOOR，于是窄通道里要拐弯时是"刹住、转头、再走"。
	var align := clampf(
			1.0 - (absf(err) - ALIGN_FREE) / (PI * 0.5 - ALIGN_FREE), 0.0, 1.0)
	# 但车体被窄通道的墙顶住、这一帧根本没转过去的时候，这一脚折扣不该收：
	# 转弯既然换不来，掉速就是纯损失。窄走廊里"车身贴着走廊轴滑行、等到路口再拐"
	# 正是靠这条成立的——否则车会被自己的减速逻辑按在 6 m/s 上。
	if turn_blocked:
		align = 1.0
	var throttle := dir * mag * lerpf(TURN_THROTTLE_FLOOR, 1.0, align)
	return Vector2(throttle, steer)


## A/D 是玩家亲自下的转向指令：车头这一帧转了多少，准星方向就跟着转多少。
##
## 不这么做的话，相对驾驶的两个输入通道会互相拆台（tools/steer_clip_probe.gd）：
##   * 按住 W+A 只是把目标航向摆到准星侧面 45°（`atan2(-right, fwd)`）。车头转到
##     45° 时偏差归零，继续按住 A 一点反应都没有——探针里 1.50s 到 +45.0°，
##     3.50s 还是 +45.0°；松开 A 之后 W 的自动对齐又把车头扳回准星，0.5 秒回到 0.0°。
##   * 原地按 A 能转过去，但准星还留在原方向。接着按 W，车头被拉回准星：探针里
##     转完 146.7° 再按 W，speed=-10.7、位移 (0.1, -6.6)——**倒着**开回原路。
##
## 补进去的是**实际**转角（drive() 前后取差），不是指令转角：`_limit_turn()`
## 在窄通道里只放行一部分，按指令补会让准星越飘越远，车头再也追不上。
## 补完之后 A/D 变成持续的舵，松手时车头与准星已经对齐，W 不会再把车拧回去；
## 炮塔也跟着车体一起转，玩家不需要再用鼠标补那 45°。
##
## 只在 A/D 真的给了输入时补。W 的自动对齐是"车头追准星"，不能反过来让准星
## 跟着车头转——那是正反馈，误差永远收不掉。
func _carry_aim_with_steer(yaw_before: float) -> void:
	if not Settings.drive_relative or not _steer_aim or rig == null:
		return
	rig.aim_yaw = wrapf(rig.aim_yaw + angle_difference(yaw_before, rotation.y), -PI, PI)


# ---------------- 近战瞄准 ----------------

## 准星（水平面上）压着的最近一辆敌车；没有则返回 null。
##
## 判据分两层，**射线上真的打中的那辆优先**：
##
##   1. `rig.aim_target()`——准星射线当前命中的坦克。这是玩家眼睛里看到的东西：
##      炮塔顶、车体四角都在命中圆柱之外，任何"到轴线的距离"都可能漏掉它们，
##      而"射线打中了谁"不会漏。近战里准星压在敌车轮廓上的那一帧，走的就是这条。
##   2. 水平方向指着这辆车（到车身轴线的最短距离 ≤ 车身半径 + `CLOSE_AIM_GIRTH`，
##      且角度 ≤ `CLOSE_AIM_MAX_ANGLE`）。射线从轮廓外擦过去时（瞄炮塔角、
##      瞄正面靠边的那一块）兜住它。
##
## 第二层只取**水平方向**，不看俯仰。近战里玩家瞄的是敌车轮廓，炮塔顶、车体上沿
## 都会让准星高出车体中心 0.5~1.5 m——纵向偏差正是要修的那个量，不能拿它来判
## "有没有瞄上这辆车"，否则永远判成没瞄上。
##
## 横向判据取"准星射线到**车身轴线**的最短距离"，而不是到车体中心的距离。
## 近距离瞄的是敌车正面靠边的那块轮廓：从炮塔轴心看过去，车体中心与准星的横差
## 会被 3~5 m 的短距离放大到 1.7~2.1 m，比"车身半径 + 余量"还远——于是整个近战
## 辅助在**最需要它的那一帧**失效，炮弹正好从车侧擦过去。轴线是斜着横在射线前面
## 的，量它到射线的最短距离，才真正对得上"准星压没压住这辆车"。
##
## 横向判据用固定米数（车身半径 + `CLOSE_AIM_GIRTH`）而不是角度：3 m 处偏半米
## 仍然"压在这辆车上"，30 m 处偏半米已经瞄到隔壁去了。距离越近，同样的米数偏差
## 对应的角度越大，这条恰好与"近战容易甩过头"的实际手感一致。角度上限则防住
## 另一头：贴到 3 m 时车身半宽就是 ±30°，但再往外就该算"瞄的是旁边"了。
##
## `max_range` 由调用方给：压炮用 `CLOSE_AIM_RANGE`（80 m，判据本质是竖直方向上的
## "准星压没压在车上"），甩炮加速与吃残差用 `CLOSE_TURRET_RANGE`（18 m）。
## 两档不是同一个量——前者是"落点收到车体上"，后者是"替玩家把炮塔残差吃掉"，
## 后者越远越像外挂。
func _assist_target(max_range: float = CLOSE_AIM_RANGE) -> Tank:
	if not alive or game == null or rig == null or barrel == null:
		return null
	var from := barrel.global_position

	# 主判据：准星射线真的命中的那辆车
	var on := rig.aim_target()
	if on != null and on != self and is_instance_valid(on) and on.alive:
		var rel0 := Vector2(on.global_position.x - from.x, on.global_position.z - from.z)
		if rel0.length() <= max_range:
			return on

	# 备用判据：准星从命中体旁边擦过去，但水平方向仍然指着这辆车
	var fwd := Vector2(-sin(rig.aim_yaw), -cos(rig.aim_yaw))
	var best: Tank = null
	var best_d := 1.0e9
	for t in game.all_tanks():
		if t == self or not is_instance_valid(t) or not t.alive:
			continue
		var rel := Vector2(t.global_position.x - from.x, t.global_position.z - from.z)
		var along := rel.dot(fwd)
		if along <= 0.0 or along > max_range or along >= best_d:
			continue
		var gap := _spine_gap(t, from, fwd)
		if gap > t.body_radius + CLOSE_AIM_GIRTH:
			continue
		if atan2(gap, along) > CLOSE_AIM_MAX_ANGLE:
			continue
		best_d = along
		best = t
	return best


## 准星射线到敌车车身轴线的最短水平距离（m）。
##
## 只量车头 / 车尾两个端点到射线的垂直距离：段内任意一点到射线的距离都不会比
## 两端更远（线段到射线的最短距离必然落在端点或交点上），所以取 min 就够用，
## 不必再解线段-射线求交。
func _spine_gap(t: Tank, from: Vector3, fwd: Vector2) -> float:
	var right := Vector2(-fwd.y, fwd.x)
	var gap := 1.0e9
	for e in t.spine():
		var v: Vector3 = e
		gap = minf(gap, absf(Vector2(v.x - from.x, v.z - from.z).dot(right)))
	return gap


## 准星上是否压着一辆 CLOSE_TURRET_RANGE 以内的敌车（甩炮加速与吃残差的总开关）。
func _close_target() -> bool:
	return _assist_target(CLOSE_TURRET_RANGE) != null


## 近战压炮：准星压住敌车时，把瞄准收回到"一定能打中车体"的那条线上。
##
## 为什么需要它：两台车贴近时，敌车炮塔是画面上最大的一块，玩家的准星自然压在
## 炮塔顶上。炮塔顶比炮口高（炮口 1.5~2.2 m，塔顶 2.4~3.3 m），指向它需要的是
## **正仰角**：3 m 处 +9°、6 m 处 +5°。炮管一抬，弹道就贴着车顶上沿飞过去；
## 只要横向还差一点（近战甩枪就是十几度），那一发就一路爬升飞进天空——AP 弹
## 没有重力，6 秒能爬出 150 米。
##
## 实测（tools/close_aim_probe.gd，准星压在敌车可见轮廓上）：不压炮时五款车在
## 3~18 m 上 150 发里有 72 发打空，其中大量行的弹道爬升超过 40 m。
##
## 所以这里做两件事：
##   * 纵向：把瞄准角**压低**到车体中心（离地 `CLOSE_AIM_Y`）。只压不抬：
##     准星本来就压在中心以下时原样保留；是否介入只看"准星射线在敌车处的高度
##     有没有超过看得见的塔顶"（`_line_height_at`），与距离无关。
##   * 横向：把落点从车体轮廓之外收进 `body_radius × CLOSE_AIM_SAFE` 以内，
##     只在 `CLOSE_AIM_LATERAL_RANGE` 以内生效（远处的横向偏差就是提前量）。
##     车体命中圆只有 1.5 m，而车体看起来是 3.4 × 4.4 m 的方盒子，四角在命中圆
##     之外——近距离瞄正面靠角是最自然的瞄法，却恰好从车侧擦过去。收幅封顶
##     `CLOSE_AIM_MAX_YAW`，免得瞄车侧边时准星被整段拽走。
##   * 两者都写回 `rig.aim_*` 而不是只改炮管——准星画的就是这个角的落点，炮管偷偷
##     改方向只会变成"准星在天上、炮弹打在地上"，比打空更难理解。
func _apply_close_assist() -> void:
	# 鼠标事件在渲染帧里改过 aim_*，而准星射线按渲染帧缓存：先作废一次，
	# 下面的"射线打到谁"与收束后的重打都必须按这一帧的角度算。
	rig.invalidate_aim()
	var t := _assist_target(CLOSE_AIM_RANGE)
	if t == null:
		return
	var from := barrel.global_position
	var rel := Vector2(t.global_position.x - from.x, t.global_position.z - from.z)
	var flat := rel.length()
	if flat < 0.6:
		return

	# ---- 横向：把落点收进车体命中圆（只在近战距离收） ----
	var fwd := Vector2(-sin(rig.aim_yaw), -cos(rig.aim_yaw))
	var right := Vector2(-fwd.y, fwd.x)
	var along := rel.dot(fwd)
	var side := rel.dot(right)
	if flat <= CLOSE_AIM_LATERAL_RANGE:
		var safe := t.body_radius * CLOSE_AIM_SAFE
		if along > 0.1 and absf(side) > safe:
			var cur := atan2(side, along)
			var aimed := atan2(signf(side) * safe, along)
			var delta := clampf(aimed - cur, -CLOSE_AIM_MAX_YAW, CLOSE_AIM_MAX_YAW)
			rig.aim_yaw = wrapf(rig.aim_yaw + delta, -PI, PI)

	# ---- 纵向：只压不抬 ----
	#
	# 判据是"准星射线在这一刻的高度，是否还在看得见的炮塔顶以下"：
	# 在以下 = 玩家瞄的是这辆车（哪怕射线从命中体旁边几厘米处穿过去了），
	# 把落点压到车体中心；在以上 = 玩家瞄的是车顶上方的天空，一点都不碰。
	# 这条与距离无关，所以不会出现"到某个距离突然失效"的边界。
	var top := t.global_position.y + t.aim_height + Tank.TURRET_TOP_RISE + AIM_PRESS_TOP_PAD
	var want_pitch := atan2(t.global_position.y + CLOSE_AIM_Y - from.y, maxf(flat, 0.5))
	if along > 0.1 and rig.aim_pitch > want_pitch \
			and _line_height_at(from, along) <= top:
		rig.aim_pitch = want_pitch
	# 准星射线是按旧角度缓存的，收完之后必须重打一次，HUD 与 aim_point 才跟得上
	rig.invalidate_aim()


## 准星射线在"横向距离 along 处"的高度（世界 y）。
##
## 压炮用它区分"准星压在车身上"与"准星抬到了车顶上方"：射线方向取自 rig 的瞄准角，
## 起点就是炮塔耳轴（与 CameraRig 的准星射线同源），所以这个高度与 HUD 画出来的
## 准星落点是同一个量，不会出现"准星看着在车上、判定说在天上"。
func _line_height_at(from: Vector3, along: float) -> float:
	return from.y + tan(rig.aim_pitch) * maxf(along, 0.01)


## 扣扳机的那一帧，把炮塔残差直接吃掉。
##
## 炮塔回转速度是玩法（歼击车还有射界），平时照常按 `turret_speed` 去追。但
## "准星已经压在敌车身上、炮塔还差最后几度"的那一瞬，打出去就是一次纯空放：
## 3 m 处 8° 就是 0.4 m，正好从车侧擦过去，炮弹随后一路爬升飞进天空。
## 开火是玩家唯一"现在就要结果"的动作，所以只在这一帧把残差吃掉；超过
## `FIRE_SNAP_MAX` 说明炮塔还没转过来，那该玩家自己等——这不是"点了没反应"。
func _snap_turret_to_aim() -> void:
	if turret == null or not _close_target():
		return
	var want := wrapf(rig.aim_yaw - rotation.y, -PI, PI)
	if turret_limit > 0.0 and absf(want) > turret_limit:
		return
	if absf(angle_difference(turret.rotation.y, want)) > FIRE_SNAP_MAX:
		return
	turret.rotation.y = want

## 右摇杆瞄准：鼠标之外的第二套瞄准通道。摇杆给的是角速度，所以需要 delta。
func _look_with_stick(delta: float) -> void:
	var look := Vector2(
		Input.get_action_strength("look_right") - Input.get_action_strength("look_left"),
		Input.get_action_strength("look_down") - Input.get_action_strength("look_up"),
	)
	if look.length_squared() > 0.0001:
		rig.handle_stick(look, delta)


# ---------------- 发动机音 ----------------

func _build_engine_audio() -> void:
	var st := Audio.engine_stream()
	if st == null:
		return
	_engine = AudioStreamPlayer3D.new()
	_engine.stream = st
	_engine.unit_size = 14.0
	_engine.max_distance = 70.0
	_engine.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_engine.bus = Audio.BUS_ENGINE
	_engine.volume_db = -14.0
	_engine.position = Vector3(0, 0.8, 1.6)
	add_child(_engine)
	_engine.play()


## 怠速到全速之间插值音调与音量，冲刺时再加一档，于是油门有听觉反馈
func _update_engine_audio() -> void:
	if _engine == null:
		return
	var r := clampf(absf(speed()) / maxf(_base_speed, 0.01), 0.0, 1.6)
	_engine.pitch_scale = clampf(0.72 + r * 0.85, 0.5, 2.2)
	_engine.volume_db = lerpf(-20.0, -8.0, minf(r, 1.0))


# ---------------- 技能 ----------------

func _start_boost() -> void:
	if boost_cd > 0.0 or not alive:
		return
	boost_t = boost_time
	boost_cd = boost_cd_max
	Audio.play("boost")
	Fx.smoke_puff(game.fx_root, global_position + global_transform.basis.z * 2.5, 0.6)


func _drop_smoke() -> void:
	if smoke_cd > 0.0 or not alive:
		return
	smoke_t = SMOKE_TIME
	smoke_cd = smoke_cd_max
	Audio.play("smoke")
	# 本地立刻生成一团，手感不依赖网络往返；联机时房主还需要知道，
	# 因为敌人的视线判定在房主那边（Net.request_smoke 会在房主侧再广播给其他人）。
	var owner_id := Net.local_pid() if Net.is_client() else 0
	game.deploy_smoke(global_position, SMOKE_TIME, owner_id)
	if Net.is_client():
		Net.request_smoke(global_position, SMOKE_TIME)


func is_smoked() -> bool:
	# 烟幕只在云团范围内生效。原来这里读的是"自己丢过烟"的计时，
	# 于是玩家开出烟团之后仍然隐身——烟雾变成了一张会跟着车走的纸。
	if game != null and game.has_method("smoke_at"):
		return game.smoke_at(global_position)
	return smoke_t > 0.0


## 站在灌木 / 芦苇里，且没有刚刚开火。敌人中远距离看不见（见 Enemy._can_see）。
func is_concealed() -> bool:
	if expose_t > 0.0:
		return false
	return arena != null and arena.is_concealed(global_position)


## 空击：炮还没装好就按了开火键。给一声空膛"咔"与一次准星红闪，
## 于是"点了没反应"永远不会发生——要么打出去，要么明确告诉玩家还要等。
func _dry_click() -> void:
	if _dry_cd > 0.0:
		return
	_dry_cd = DRY_CLICK_CD
	dry_flash = 0.22
	Audio.play("dryfire", -6.0)
