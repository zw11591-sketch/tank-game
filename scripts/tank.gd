class_name Tank
extends CharacterBody3D
## 3D 坦克基类：车体驱动、炮塔独立回转、装填计时、装甲朝向减伤与跳弹判定。
##
## 车体 (self) 负责移动与朝向；turret 为子节点独立回转；barrel 挂在炮塔上负责俯仰。
## 伤害按命中点相对车体正面的夹角分为正面/ 侧面 / 背面三档。
const LAYER_WORLD := 1
const LAYER_TANK := 2
const LAYER_BLOCKER := 4

## 炮管俯仰的机械范围。
##
## 这个范围是*炮管机械行程**，不是*弹道射程**——两者已经在代码里分开了：
##   * 炮管能抬多高 / 能压多低，决定准星会不会跑到地平线以上、压不到近处的敌车，
##     就是这里的`PITCH_MIN / PITCH_MAX`（
##   * HE 的弹道解能抬多高，决定炮弹能不能落在准星上，那是 `Shell.HE_SOLVE_MAX`。
## 解算取的是准是*打中的那个点**，与炮管当下指向无关，所以两者不必是同一个数
## （见 `he_dir()`）。
##
## 上限 6° 是*手感量*：交战双方都在平地上，炮口与敌车中心几乎等高，直射要的
## 仰角基本是0°、6° 已经够到 30 m 处4.4 m 的钢墙墙顶（4.7°），再往上纯属浪负
## ——镜头俯角按 `PITCH_BASE - aim_pitch * PITCH_FOLLOW` 走，仰角越大准星越往画面
## 上缘爬（+12° 时距上缘只剩约10% 屏幕高度，HUD 险些要把它钳住），
## 玩家的原话是"炮管上下的角度还是太大，容易打到天上压。
##
## 下限 -18° 是*几何量*，它必须盖住近距离交战的整个需求区间：
## 炮口高1.95 m、敌车中心1.1 m，指向车体中心所需的俯角随距离急剧变大——
##   9 m →-3.8°   6 m →-7.9°   5 m →-9.6°   4 m →-12.2°   3 m →-16.1°
## 原来下限是-8°，于是5 m 以内炮管根本压不到目标上：准星压在敌车身上，炮管半
## 停在 -8° 这个"平视"姿态，炮弹从车体上沿擦过去、一路爬升，一飞飞出上百米。
## 这就是两台车贴近时炮台抬得太高、炮弹打到天上最常见的一种。
## 3 m 是两辆车（车身半径各 1.5 m）能靠到的极限，-18° 留了约2° 余量。
## 判据解tools/near_probe.gd：.5~9 m × 瞄准车体 / 瞄准炮塔，每一行都必须命中。
const PITCH_MIN := deg_to_rad(-18.0)
const PITCH_MAX := deg_to_rad(6.0)

## 车体命中圆柱的高度（离地 0 ~ 2.0 m）。炮塔命中体必须与它**接上**，见
## `_build_turret_hitbox()`：两者之间只要留一条竖直缝，近战的准星射线就会从缝重
## 穿过去——画面上正对着炮塔，炮弹却从车顶与炮塔之间飞走。
const HULL_HIT_H := 2.0

## 炮塔命中体的顶面在炮管耳轴之上多少米。
##
## 这个量必须盖体*看得见的炮塔顶*：模型里塔体楔形顶在炮塔原点之上 0.80 m）
## 而舱相/ 车长塔那一圈到 1.17 m（tools/blender/gen_tanks.py 的`_turret`）。
## 耳轴在炮塔原点之与0.34~0.70 m，所以塔顶"落在耳轴上方 0.47~0.83 m。
##
## 原来取0.62，恰好卡在区间中间：山猫与雷锤（耳轴高0.45 / 0.50）的舱盖顶在
## 耳轴上方 0.72 / 0.67 m——命中体比看得见的塔顶矮 5~10 cm。准星压在塔顶那一小块个
## 就是"指着空气"：射线什么都不碰，炮弹顺着 +2.4° 的炮管一路爬半
## （tools/close_aim_probe.gd 的18 m × 2.4 m 行，爬升 20.8 m 仍打空）。
##
## 只0.75 让五款车的塔顶都落进命中体（最矮的歼击车会高出画面 0.2 m 左右（
## 那是刻意的：宁可炮弹在塔顶上新0.2 m 处消失，也不要从看得见的塔顶穿过去）。
const TURRET_TOP_RISE := 0.75

## HE 解算弹道时，沿炮管方向最远探到多少米。超出这个距离的目标本来也看不清，
## 而弹道解需要一个确定的落点才能算出抬升量。
const LOB_RANGE := 220.0

## 直瞄弹的发射方向最多偏离炮管多少度。
##
## `aim_solution()` 让炮弹飞后*准星打中的那个点**，而不是炮管的姿态——炮管俯仰被
## 机械行程钳在 [-18°, +6°]，而近距离瞄炮塔顶要+12°、瞄车体侧下沿要 -26°，
## 留在炮管上的差额就是"准星压在车上、炮弹却从车顶飞过去"的全部来源。
##
## 但方向不能无限偏离炮管：偏得太多说明炮塔还在追瞄（玩家刚甩过鼠标），这时按
## 准星方向发射，炮弹会从炮管侧边横着飞出去，画面上完全说不通、8° 覆盖于
## 3 m 处炮塔顶的俯仰差额（线12°）与炮塔残差的常见范围，再多就该等炮塔转过去。
const AIM_SOLVE_CONE := deg_to_rad(18.0)
## 参与"按准星落点发射的最远距离。战场对角线 136 m，取 200 m 是为了把
## 「准星什么都没打到」时 `aim_point` 的300 m 兜底点排除在外：
## 那种情况下炮口指向天空是玩家自己选的，炮弹应该顺着炮管走。
const AIM_SOLVE_MAX := 200.0

var game: Node
var arena: Arena

var alive := true
var is_player := false
var display_name := "坦克"

# --- 机动 ---
var move_speed := 12.0
var reverse_ratio := 0.55
var turn_speed := 2.2
var turret_speed := 2.4
var body_radius := 1.5
## 车体长度（m），与tools/blender/dims.py 里hull 的Y 一致。
##
## 碰撞不能只是一个圆柱：车长 4.4 米、半径却只有 1.5 米，车头车尾各有 0.7 米
## 完全没有碰撞体——开到墙根下，车鼻就这么插进砖墙里，这正是穿越障碍片
## 最直接的来源。现在沿车身轴额外挂两个小圆柱（车鼻 / 车尾），
## 实心轮廓因此贴合车体，而不再是一个比车还短的圆。
var body_length := 4.4
## 起步加速度与刹车减速度（m/s^2）。刹车快于加速，松油门与反向输入都走刹车曲线，
## 这样既有坦克的沉重惯性，又不会让急停拖沓。
var accel := 14.0
var brake_decel := 26.0
## 带油门行驶时保留的转向权限比例：1.0 = 转向速率与车速解耦，任何速度都是满舵。
##
## 原来是0.78，理由是"贴住墙的车不许继续全速拧舵，否则会把车身拧进侧墙"。
## 那条理由成立的前提是碰撞轮廓比车身小一圈（1.5 × 2.2 的写死矩形），
## `_limit_turn()` 看不出车角已经压进墙里，只能面低速少给舵"间接收敛。
##
## 现在轮廓按模型实测（观_init_hull_outline）、`_limit_turn()` 逐帧用*真实矩形**
## 判可行性，这个间接手段就成了纯损失：它让刚起步的车（speed_ratio 小）在最需要
## 跟手的时候只机78% 的舵，而几何保护已经在另一条路上把"拧进墙堵死了。
## 实测（tools/_HullClipProbe.tscn 的wallturn）：贴墙同时给油门与舵，
## 0.78 时300 帧只转过 40.6°，.0 时转这69.7°，两者车体压进墙的深度都是0.00。
var neutral_turn_ratio := 1.0
## 炮塔追瞄加速：角度误差越大回转越快。 表示恒速（敌人沿用原手感）
var turret_snap := 0.0
## 炮塔射界（弧度，相对车体）、 表示全向 360°。
##
## 这是名册里那台歼击车的*行为**特性：射界之外必须用车体指向目标，
## 于是"用方向盘瞄准"重新变成一件需要练习的事，而不是免费的全向炮塔。
## 限位只在 aim_at_angles() 里落实，不碰任何碰撞体或装甲判定。
var turret_limit := 0.0
## 上一帧目标是否落在射界之外。HUD 据此提示"转到车体上去"，而不是让玩家
## 对着一个永远转不过去的方向反复推鼠标。
var turret_blocked := false
## 瞄准解算的参考高度（炮管耳轴离地）。can_elevate_to 一aim_at 都用它；
## 低矮的歼击车与火炮车的耳轴比主战坦克低 0.4 米以上，用错高度会让
## "准星可达"的判定在远处系统性偏移。
var aim_height := 1.9
## 本帧准星落在的世界坐标点。玩家由 CameraRig 每帧写入，敌人由 aim_at() 写入。
## fire() 只用它决定炮弹从炮管轴的哪一点出发（解shot_origin）。
var aim_point := Vector3.INF

# --- 火力 ---
var reload_time := 2.4
var reload_t := 0.0
## 累计击发次数。只给验收探针用：装填已经压分0.05 s，从 `reload_t` 反推
## "这一下点出去几发"时，一帧的推移就足以越过判据（见tools/click_probe.gd），
## 计数没有这个问题。
var shot_count := 0
## 累计被命中次数（**含跳弹与护盾这类零伤害的结果**）。同样只给验收探针用：
## close_aim_probe 必须区分"弹道确实落在车上，只是被跳弹挡掉"与从车边飞过去"，
## 后者才是玩家说的瞄准了却打到天上"。只真hp 会把 30% 的跳弹算成打空。
var hit_count := 0
var damage := 60
var shell_kind := Shell.Kind.AP
var can_use_he := false
## HE 弹的伤害倍率（相对damage）与溅射半径倍率。自行火炮的"高爆专精"就是这两个量。
var he_mult := 0.72
var he_splash := 1.0

# --- 生存 ---
var max_hp := 300
var hp := 300
## 各朝向的入射伤害倍率：正面挨打吃亏少，背后是弱点
var armor_front := 0.55
var armor_side := 1.0
var armor_rear := 1.75

# --- 增益状态（秒） ---
var shield_t := 0.0
var emp_t := 0.0
var armor_buff_t := 0.0
var rapid_buff_t := 0.0
## 多弹装填：一次击发同时打出三发带散布的炮弹
var multi_t := 0.0
var damage_mult := 1.0

var turret: Node3D
var barrel: Node3D
var muzzle: Node3D
var _hull_mesh: MeshInstance3D
var _shield_mesh: MeshInstance3D
var _tread_l: MeshInstance3D
var _tread_r: MeshInstance3D
var _tread_phase := 0.0
var _recoil := 0.0
var _hull_size := Vector3(3.4, 1.0, 4.4)
## 当前沿车头轴的速度，带符号（正 = 前进）。惯性模型的唯一状态量。
var _speed := 0.0
## 上一物理帧的**实际**水平速度（m/s），由真实位移算出，见 `_track_motion()`。
## 它与 `_speed` 只在"顶住掩体"时不同：那时 `_speed` 报指令速度，这个量归零。
var _moved := 0.0
## Blender 模型的根节点（走图元回退时为 null）
var _model: Node3D
## 可滚动的负重轮。模型里的Wheel_L*/Wheel_R* 节点，已烘掉摆放旋转。
var _wheels: Array[Node3D] = []
var _wheel_radius := 0.45
## 炮管节点的静止局部坐标。后坐动画是在它之上叠加偏移，而不是直接写死坐标。
var _barrel_base := Vector3.ZERO
var _hull_base_y := 0.85
## 自上一枚履带印以来行驶的距离（米）
var _track_dist := 0.0
## 自上一声履带响以来行驶的距离（米）。与贴花分开计数：
## 两者的合适间距不同，共用一个计数器就只能牺牲一边。
var _track_snd := 0.0
## 上一个确认在实心格之外的位置。车体万一陷进掩体，脱出方向以它为准，
## 于是永远是从进来的那一侧退出去"，而不是从墙的另一面弹出去。
var _safe_pos := Vector3.ZERO
## 车体在网格上的碰撞轮廓：跟着朝向一起转的矩形（半宽 / 半长）。
##
## 原来这里是车体在+ 车鼻/车尾两个小圆"：三个圆在车头中线上刚好贴住车鼻，
## 何*车角差了整整一米*。主战车镜4.4、宽 3.4，四角离最近的圆心有两米，
## 而圆的半径只最0.82。于是斜着贴墙、在窄通道里转身时，画面上看得见的车角
## 就切进砖墙里——实测（tools/_turn_clip_probe.gd）单格走廊里转到 56°。
## 车角压进墙1.04 米；贴着墙给舵46°、压这0.97 米。玩家看到的"穿墙"就是它。
##
## 而且这个近似是两头不讨好的：车角能陷进去一米，车鼻中线那条假想圆却又比
## 真实车头更早抵住墙——窄通道里的转向因此既穿模又发死。
##
## 网格是规则矩形，旋转矩形与它的分离在二维上有精确解（SAT，见 _obb_mtv），
## 所以这里直接取车体**可见**轮廓，不再用圆去近似。于是看得见的车体"就是碰撞轮廓：
## 穿墙与视角误差一起消失。
##
## 轮廓在_ready() 里按模型包围直*实测**（见 _init_hull_outline），不抄名册：
## 名册的hull 只是 Blender 的主箱体，首下斜来/ 拖钩 / 排气发/ 驻锄都伸在它之外。
var _hull_half_w := 1.5
var _hull_half_l := 2.2
## 车头（Z， 车尾（Z）各自的半长。车体前后并不对称，必须分开量：
## 火炮车的尾部驻锄比首下斜板多会0.63 m，用对称半长会一头留空档、一头照样穿模。
var _hull_half_f := 2.2
var _hull_half_b := 2.2
## 车鼻 / 车尾辅助圆（只喂物理碰撞体，不参与网格解交）。
var _nose_r := 0.8
var _nose_f := 1.2
## 上一物理帧的转向是否被几何挡住了（给了舵，车体轮廓却转不过去），见_limit_turn()。
## player.gd 据此取消"先转头再走的那一脚油门折扣：车根本没在转，压油门只是白掉速。
var turn_blocked := false
## 车体任何时候允许和掩体重叠的最大深度（m）。
##
## 这是**看得见**的量：车体轮廓取自模型包围盒，所以这个数就是玩家眼里车角切进
## 砖墙的厘米数。原来这里是一套"压进去再由 _settle() 推出来"的余地（6 cm，停住
## 时放宽到 18 cm），本意是让贴墙的车还能拧舵，实际结果是车角真的挂在墙里——
## 单格走廊里每一帧都压 18 cm，玩家看到的就是"坦克穿墙"。
##
## 现在改为 3 cm（约车宽 1%，贴边几乎看不出），并且转向不再靠"先压进去"换转向
## 角度：判据改成**转过去之后 _settle() 推不推得出来**（见 `_resolved_depth()`）。
## 单侧墙时推得出来，照转；两侧夹住推不出来，就少给转角。于是"能转多少"与
## "画面上压进多少"是同一件事，不再互相拆台。
const HULL_SCRAPE := 0.03
## 碰撞轮廓相对可见轮廓留的余量（m）。贴死到 0 会让浮点误差把"刚好擦过"判成重叠。
const HULL_PAD := 0.02


func setup(g: Node, a: Arena, pos: Vector3) -> void:
	game = g
	arena = a
	position = pos


func _ready() -> void:
	hp = max_hp
	reload_t = reload_time * 0.35
	collision_layer = LAYER_TANK
	collision_mask = LAYER_WORLD | LAYER_TANK | LAYER_BLOCKER
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	# 默认 0.001 的安全边距太薄，高速擦墙时会先嵌进去再被弹开；
	# 放宽判6cm 计move_and_slide 提前停住，视觉上也不再有"陷进墙里"的那一帧
	safe_margin = 0.06
	_safe_pos = position

	# 碰撞轮廓取*模型实际的可见轮廓*，而不是body_radius / body_length 这两一
	# "玩法参数"（后者为了窄通道的通过性被刻意调小过），也不是名册里的 hull
	# （那只是 Blender 的主箱体）。细节见 _init_hull_outline()。
	_build_body()
	_init_hull_outline()

	# 车体在+ 车鼻 + 车尾：物理引擎这一侧仍用圆柱近似车身（网格解交生
	# _settle() 的精确矩形负责）。move_and_slide 与坦克之间的互撞因此看的
	# 都是整条车身，而不只是车体中段。
	#
	# 车鼻 / 车尾圆柱要顶刻*可见轮廓**，而不是名册主箱体：否分move_and_slide
	# 会让车鼻先插进墙 0.4 m，再用_settle() 在一帧里推回来——那一下是可见的回弹。
	# 圆柱半径与横向位置都不变，所以不改变任何侧向通过性。
	_nose_r = clampf(body_radius * 0.55, 0.45, 1.5)
	var nose_front := maxf(_hull_half_f - _nose_r, 0.0)
	var nose_back := maxf(_hull_half_b - _nose_r, 0.0)
	_nose_f = nose_front
	_add_cylinder(body_radius, HULL_HIT_H, Vector3(0, HULL_HIT_H * 0.5, 0))
	if nose_front > 0.05:
		_add_cylinder(_nose_r, 1.8, Vector3(0, 1.0, -nose_front))
	if nose_back > 0.05:
		_add_cylinder(_nose_r, 1.8, Vector3(0, 1.0, nose_back))

	_build_turret_hitbox()


func _add_cylinder(r: float, h: float, pos: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = r
	cyl.height = h
	shape.shape = cyl
	shape.position = pos
	add_child(shape)


## 子类通过覆写这两个方法决定外观
func hull_color() -> Color:
	return Color(0.35, 0.55, 0.3)


func accent_color() -> Color:
	return Color(0.85, 0.75, 0.35)


## 识别色块的自发光强度。玩家车不发光——自车位置永远不是信息缺口；
## 敌车发光，于是场上还有调在任何地形、任何光照下都读得出来（见Enemy）。
func accent_glow() -> float:
	return 0.0


## Blender 模型键（assets/models/<key>.glb）。覆写它即换车型外观。
func model_key() -> String:
	return "tank_player"


## 优先用Blender 生成的模型，拿不到再退回图元拼装。
## 两条路径产出的turret / barrel / muzzle 局部坐标完全一致——
## 这是 tools/blender/dims.py 当尺寸真值表的意义，换皮不影响任何判定。
func _build_body() -> void:
	if not _build_model_body():
		_build_primitive_body()
	_build_shield()


## 碰撞轮廓 = 车体**可见轮廓**（半宽/ 车头半长 / 车尾半长）。
##
## 名册里的 hull 只是 Blender 的*主箱体*尺寸，首下斜板、首上折角、拖钩、排气口。
## 驻锄都伸在它之外。实测（tools/_hull_probe.gd）整车可见长度与主箱体差出半米到
## 一米多（
##
##   车型              主箱体长    可见镜   车头多出   车尾多出
##   tank_player        4.40      5.21      0.39       0.41
##   tank_scout         3.90      4.61      0.45       0.36
##   tank_heavy         4.90      5.71      0.39       0.41
##   tank_artillery     4.60      6.03      0.40       1.03
##   tank_destroyer     5.00      5.80      0.39       0.40
##   tank_boss          6.00      6.89      0.40       0.49
##
## 拿主箱体当碰撞轮廓，车鼻顶到墙根时那一截就整段没进砖墙——玩家看到的就是
## "坦克穿墙"。实测（tools/_hull_clip_probe.gd，游隼）：正面撞墙时可见车鼻压进
## 墙里 0.38 m、贴墙给舵时车角压进 0.38 m，两者都是纯视觉错位，物理判定早已停住。
##
## 所以这里按模型包围盒实测。车处/ 车尾分开量：合成一个对称半长的话，长的那一外
## 决定轮廓、短的那一头就会留出一条看得见的空档（火炮车1.03 m 的驻键vs 0.40 m
## 的首下斜板，左0.63 m——车头会停在墙外半米多）。
##
## 量不到模型（图元回退 / 坏资源）时退回名册，名册也没有才退回玩法参数：
## 宁可碰撞体稍小，也不要让碰撞消失。
func _init_hull_outline() -> void:
	var m := _measure_hull()
	if m.y > 0.05 and m.z > 0.05:
		_hull_half_w = m.x + HULL_PAD
		_hull_half_f = m.y + HULL_PAD
		_hull_half_b = m.z + HULL_PAD
	else:
		var hull: Vector3 = TankRoster.dims(model_key()).get("hull", Vector3.ZERO)
		if hull.z > 0.05:
			_hull_half_w = maxf(hull.x * 0.5, 0.4)
			_hull_half_f = maxf(hull.z * 0.5, 0.4)
		else:
			_hull_half_w = maxf(body_radius, 0.4)
			_hull_half_f = maxf(body_length * 0.5, 0.4)
		_hull_half_b = _hull_half_f
	_hull_half_l = (_hull_half_f + _hull_half_b) * 0.5


## 模型的车体包围盒，换算成"相对车体原点的半宽/ 车头半长 / 车尾半长"。
## 量不到（没有模型 / 模型没有网格）时返回 Vector3.ZERO。
##
## 炮塔与炮管整棵子树都排除：它们会转、会俯仰，炮管本来就会伸进掩体里
## （世界里的坦克游戏都这么做），拿它们当车体轮廓会把车体撑到五米宽。
func _measure_hull() -> Vector3:
	if _model == null:
		return Vector3.ZERO
	var box := AABB()
	var first := true
	for mi in _hull_meshes(_model):
		var a: AABB = _xf_under(self, mi) * mi.get_aabb()
		if first:
			box = a
			first = false
		else:
			box = box.merge(a)
	if first:
		return Vector3.ZERO
	return Vector3(
			maxf(-box.position.x, box.position.x + box.size.x),
			maxf(-box.position.z, 0.0),
			maxf(box.position.z + box.size.z, 0.0))


func _hull_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and n.mesh != null and not _under_gun(n) \
			and _counts_as_hull(n):
		out.append(n)
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		out.append_array(_hull_meshes(c))
	return out


## 只有**车体本身**才算轮廓，其余三样必须排除：
##
##   * 护盾球（SphereMesh，半得max(body_radius*1.9, 2.6)，游随2.85 m）：
##     拿它当轮廓会把车体撑或5.7 米见方的方块，`_settle()` 于是把车从任体
##     走廊里推出去、`_limit_turn()` 把每一次打舵都否决——车"哪儿都进不去。
##     转不动就是这么来的。它是特效，不是车身。
##   * 地面导向箭头（HullGuide 的Guide* 子节点）：只挂在玩家车上，是 UI 提示。
##   * 不可见网格：同理，看不见的东西不该参与碰撞。
##
## 模型里的网格永远可见且不会是球体，所以这三条不会误伤任何真实车体。
func _counts_as_hull(mi: MeshInstance3D) -> bool:
	if not mi.visible or mi.mesh is SphereMesh:
		return false
	var p: Node = mi
	while p != null and p != self:
		var s := String(p.name)
		if s.begins_with("Shield") or s.begins_with("Guide"):
			return false
		p = p.get_parent()
	return true


func _under_gun(n: Node) -> bool:
	var p: Node = n
	while p != null and p != self:
		var s := String(p.name)
		if s.begins_with("Turret") or s.begins_with("Barrel") or s.begins_with("Muzzle"):
			return true
		p = p.get_parent()
	return false


## node 相对 root 的*局都*变换（不含root 自己的transform；glTF 的平移挂地
## 模型根上，必须逐级乘下来）。
func _xf_under(root: Node, node: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## 炮塔顶部的命中体。
##
## 车体碰撞圆只朝2.0 m 高（0~2.0），而炮塔从 1.9 m 一直长到2.5 m 左右。
## 于是"准星压在炮塔上开火是一条*打不一*的弹道：炮弹全程在2.0 m 以上（
## 从车体命中体头顶掠过、继续爬升，一路飞出上百米。而这恰好是近距离交战无
## 玩家最自然的瞄准点——远处的车只看得见一个轮廓，贴到 5~9 m 时炮塔是画面里
## 最大的一块。实测（tools/near_probe.gd： m 瞄炮塔爬单49.8 m、 m 瞄炮塔爬单
## 114.9 m，两行都是MISS，就是玩家说的炮台抬得太高、炮弹打到天上。
##
## 所以命中体必须覆盖到炮塔顶：高度取炮管耳轴（各车型 1.54~2.15 m）往与0.2~1.0 m）
## 半径比车体窄（炮塔本身比车体窄一圈）。
##
## **下端必须压进车体命中体里**，不能只贴住炮塔顶。这两个圆柱一旦各管各的，
## 中间就留下一来0.2~0.4 m 的竖直缝：准星从 2.6 m 处压在Boss 的炮塔上时，射线
## 到达炮塔正面时高度约 2.1 m——高于车体命中体顶（2.0）又低于炮塔命中体底
## （.55 - 0.18 = 2.37），于是什么都不碰，炮弹从车顶与炮塔之间飞上去。
## 实测（tools/aim_probe.gd 的falcon × boss × 2.6 m）就是`on=none / MISS`。
## 现在下端固定只`HULL_HIT_H - 0.25`，两个圆柱始终重只0.25 m，这条缝不存在。
##
## 它跟着**车体**而不是炮塔节点：形状是圆的，炮塔转多少度都一样；挂到炮塔节点上
## 则要额外给它单独一层，否则炮塔转动会参与车与车之间的挤压，那是另一套机制。
## 竖直方向加高不影响任何水平判定：撞墙、车与车分离看的都是横向半径。
##
## 半径只0.80 倍车体半径（原0.62）。炮塔在模型里是 0.72 倍车宽，也就是0.816 值
## 车体半径；原松0.62 让命中体比看得见的炮塔窄了整敌0.3 m——准星压在炮塔侧静
## 那条边上，射线却从命中体外擦过去。远距离，8 m）这时只左0.2°，炮弹却因为
## 仰角仍在爬升而飞出一百多米、.80 既覆盖了炮塔的可见宽度，又仍小于车体半径（
## 所以不会改变任何撞墙/ 车与车分离的判定。
func _build_turret_hitbox() -> void:
	if turret == null or barrel == null:
		return
	var gun_y := turret.position.y + _barrel_base.y
	var top := gun_y + TURRET_TOP_RISE
	var bot := minf(HULL_HIT_H - 0.25, top - 0.25)
	_add_cylinder(
			clampf(body_radius * 0.80, 0.75, 1.85), top - bot,
			Vector3(0, (top + bot) * 0.5, 0.0))


func _build_model_body() -> bool:
	_model = Assets.instantiate(model_key())
	if _model == null:
		return false
	add_child(_model)
	Assets.paint(_model, hull_color(), accent_color(), accent_glow())

	turret = Assets.find_node(_model, "Turret")
	barrel = Assets.find_node(_model, "Barrel")
	muzzle = Assets.find_node(_model, "Muzzle")
	if turret == null or barrel == null or muzzle == null:
		# 模型节点契约被破坏（改名或导出漏了控制节点），宁可退回图元也不要半残
		push_warning("模型 %s 缺少 Turret/Barrel/Muzzle 节点，回退到图元车体" % model_key())
		_model.queue_free()
		_model = null
		turret = null
		barrel = null
		muzzle = null
		return false

	_barrel_base = barrel.position
	_wheels = Assets.find_all(_model, "Wheel_")
	# 轮径只影响滚动速度的观感，与任何判定无关；数值取自名册的尺寸真值表
	# （它又与 tools/blender/gen_tanks.py 的_running_gear 一一对应（
	_wheel_radius = float(TankRoster.dims(model_key())["wheel"])
	_hull_base_y = 0.0
	return true


func _build_shield() -> void:
	_shield_mesh = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = maxf(body_radius * 1.9, 2.6)
	sm.height = sm.radius * 2.0
	_shield_mesh.mesh = sm
	_shield_mesh.position = Vector3(0, 1.4, 0)
	var shmat := _mat(Color(0.4, 0.85, 1.0, 0.25), 0.2, 0.0)
	shmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shmat.emission_enabled = true
	shmat.emission = Color(0.4, 0.85, 1.0)
	shmat.emission_energy_multiplier = 1.5
	shmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_shield_mesh.material_override = shmat
	_shield_mesh.visible = false
	add_child(_shield_mesh)


## 图元回退车体：删掉assets/models 之后游戏仍然能正常开局，只是观感回到改造前
func _build_primitive_body() -> void:
	var body_mat := _mat(hull_color(), 0.62, 0.25)
	var dark_mat := _mat(hull_color() * 0.45, 0.85, 0.1)
	var accent_mat := _mat(accent_color(), 0.5, 0.5)
	# 图元车体走的是同一条可读性规则：识别色块该发光就发光
	if accent_glow() > 0.0:
		accent_mat.emission_enabled = true
		accent_mat.emission = accent_color()
		accent_mat.emission_energy_multiplier = accent_glow()

	# 车体
	_hull_mesh = MeshInstance3D.new()
	var hb := BoxMesh.new()
	hb.size = _hull_size
	_hull_mesh.mesh = hb
	_hull_mesh.position = Vector3(0, 0.85, 0)
	_hull_mesh.material_override = body_mat
	add_child(_hull_mesh)

	# 前装甲斜板：视觉上强调正面更硬"
	var glacis := MeshInstance3D.new()
	var gb := BoxMesh.new()
	gb.size = Vector3(_hull_size.x * 0.96, 0.9, 1.4)
	glacis.mesh = gb
	glacis.position = Vector3(0, 1.05, -_hull_size.z * 0.5 + 0.5)
	glacis.rotation_degrees = Vector3(-32.0, 0, 0)
	glacis.material_override = body_mat
	add_child(glacis)

	# 履带
	_tread_l = _make_tread(dark_mat, -_hull_size.x * 0.5 - 0.28)
	_tread_r = _make_tread(dark_mat, _hull_size.x * 0.5 + 0.28)

	# 炮塔
	turret = Node3D.new()
	turret.position = Vector3(0, 1.4, 0.15)
	add_child(turret)

	var tm := MeshInstance3D.new()
	var tc := CylinderMesh.new()
	tc.top_radius = 1.0
	tc.bottom_radius = 1.25
	tc.height = 0.95
	tm.mesh = tc
	tm.position = Vector3(0, 0.48, 0)
	tm.material_override = body_mat
	turret.add_child(tm)

	# 炮塔顶部识别色块
	var cap := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(0.9, 0.22, 0.9)
	cap.mesh = cb
	cap.position = Vector3(0, 1.02, 0)
	cap.material_override = accent_mat
	turret.add_child(cap)

	barrel = Node3D.new()
	barrel.position = Vector3(0, 0.55, 0)
	turret.add_child(barrel)

	var gun := MeshInstance3D.new()
	var gc := CylinderMesh.new()
	gc.top_radius = 0.17
	gc.bottom_radius = 0.22
	gc.height = 3.6
	gun.mesh = gc
	gun.rotation_degrees = Vector3(-90.0, 0, 0)
	gun.position = Vector3(0, 0, -1.8)
	gun.material_override = dark_mat
	barrel.add_child(gun)

	var brake := MeshInstance3D.new()
	var bc := CylinderMesh.new()
	bc.top_radius = 0.3
	bc.bottom_radius = 0.3
	bc.height = 0.5
	brake.mesh = bc
	brake.rotation_degrees = Vector3(-90.0, 0, 0)
	brake.position = Vector3(0, 0, -3.4)
	brake.material_override = accent_mat
	barrel.add_child(brake)

	muzzle = Node3D.new()
	muzzle.position = Vector3(0, 0, -3.8)
	barrel.add_child(muzzle)

	_barrel_base = barrel.position
	_hull_base_y = 0.85


func _make_tread(mat: Material, x: float) -> MeshInstance3D:
	var t := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(0.72, 0.85, _hull_size.z + 0.5)
	t.mesh = b
	t.position = Vector3(x, 0.45, 0)
	t.material_override = mat
	add_child(t)
	return t


func _mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


# ---------------- 每帧 ----------------

func _physics_process(delta: float) -> void:
	if not alive:
		return
	# turret_blocked 用aim_at_angles() 每帧置位，而它在标预暂停这类状态下不会被调用。
	# 先清掉，HUD 就不会拿着上一帧的"射界太提示一直挂在屏幕上。
	turret_blocked = false
	reload_t = maxf(0.0, reload_t - delta * reload_rate())
	shield_t = maxf(0.0, shield_t - delta)
	emp_t = maxf(0.0, emp_t - delta)
	armor_buff_t = maxf(0.0, armor_buff_t - delta)
	rapid_buff_t = maxf(0.0, rapid_buff_t - delta)
	multi_t = maxf(0.0, multi_t - delta)
	_recoil = maxf(0.0, _recoil - delta * 5.0)
	# 后坐沿炮管轴向（局部+Z 即炮尾方向）叠加在静止坐标之上
	barrel.position = _barrel_base + Vector3(0, 0, _recoil * 0.9)

	if _shield_mesh != null:
		_shield_mesh.visible = shield_t > 0.0
		if shield_t > 0.0:
			_shield_mesh.scale = Vector3.ONE * (1.0 + sin(Time.get_ticks_msec() * 0.006) * 0.04)

	tick(delta)


func tick(_delta: float) -> void:
	pass


func reload_rate() -> float:
	return 1.8 if rapid_buff_t > 0.0 else 1.0


func reload_ratio() -> float:
	return 1.0 - clampf(reload_t / maxf(reload_time, 0.01), 0.0, 1.0)


func is_emp() -> bool:
	return emp_t > 0.0


# ---------------- 机动 ----------------

## throttle: -1..1 前进/后退；steer: -1..1 车体左右转。
## 两者都接受模拟量（手柄摇杆），键盘传±1。
##
## 速度不再瞬时赋值，而是经加速度/刹车推向目标速度，于是有了起步、滑行与刹停；
## 转向权限随车速插值；撞上掩体时按入射角削减动能，避免贴墙还在满速推进。
func drive(throttle: float, steer: float, delta: float) -> void:
	throttle = clampf(throttle, -1.0, 1.0)
	steer = clampf(steer, -1.0, 1.0)
	var pos_before := global_position

	if is_emp():
		_speed = move_toward(_speed, 0.0, brake_decel * delta)
		var depth_now := _hull_depth(rotation.y)
		velocity = -global_transform.basis.z * _speed
		move_and_slide()
		_settle()
		_undo_unresolved_move(pos_before, depth_now)
		_track_motion(pos_before, delta)
		return

	var target := move_speed * throttle
	if throttle < 0.0:
		target = move_speed * reverse_ratio * throttle

	# 收油门或反打方向时走刹车减速度，其余情况走加速度
	var rate := accel
	if absf(target) < absf(_speed) or signf(target) * signf(_speed) < 0.0:
		rate = brake_decel
	_speed = move_toward(_speed, target, rate * delta)

	var speed_ratio := clampf(absf(_speed) / maxf(move_speed, 0.01), 0.0, 1.0)
	var authority := lerpf(neutral_turn_ratio, 1.0, speed_ratio)
	# 原地转向（油门正好为 0）同样是满舵：拧舵只改朝向，没有把车身塞进墙里的动能，
	# 而原地转车恰恰是最需要跟手的动作（调整装甲正面、歼击车用车体找目标）。
	if is_zero_approx(throttle):
		authority = 1.0
	turn_blocked = false
	var yaw_before := rotation.y
	# 转向前的压入深度：后面复查朝向时以它为准（见 _undo_unresolved_turn）
	var depth_before := _hull_depth(yaw_before)
	rotation.y += _limit_turn(-steer * turn_speed * authority * delta)

	# 旋完先解交，再前进。顺序很关键：贴单侧墙时，旋转会让一侧车角先压进去，
	# 这时立刻 _settle() 是把整台车朝空地推开——车于是"抵着墙蹭开、接着转"，
	# 而不是带着压进去的车角去撞 move_and_slide（那会把车判成顶死、原地不动）。
	# 后面的位移复查以**推完之后的位姿**为基准，不会拿旋转前的深度去否决位移。
	_settle()
	var pos_after_turn := global_position
	var depth_after_turn := _hull_depth(rotation.y)

	velocity = -global_transform.basis.z * _speed
	move_and_slide()
	_settle()
	# 先管位移：两侧都顶住时 _settle() 推不出来，这一帧的位移会把车角插进砖墙。
	_undo_unresolved_move(pos_after_turn, depth_after_turn)
	# 再管朝向：位移之后车身可能已经抵到墙上，把"推不出来"的那部分转角收回去。
	_undo_unresolved_turn(yaw_before, depth_before)

	_bleed_on_impact(delta)
	_animate_tracks(delta)
	_lay_tracks()
	_track_noise(delta)
	_track_motion(pos_before, delta)


## 记录"这一帧实际走了多过"，供驾驶手感与脱困判断使用。
##
## `_speed` 是*控制量*，不是观测值：车顶着墙角时它照样报着 19.5 m/s，而位移是零。
## 需要"车到底动没动"的地方一律看这个量。
func _track_motion(from: Vector3, delta: float) -> void:
	_moved = Vector2(global_position.x - from.x, global_position.z - from.z).length() \
			/ maxf(delta, 0.0001)


## 每次移动后的收尾：压回地面高度，再用网格硬约束把整条车身推出任何实心格。
##
## move_and_slide() 只保证这一步不穿过去，被另一辆坦克挤压、或在刚被加固还原的
## 格子上重生时仍可能嵌进掩体——这一步把它兜住，所以穿墙不再是概率问题。
##
## 解交对象是*整块车体矩形**（四个角都算进轮廓），而不是几个圆：圆拼出来的
## 轮廓在车角处比车体窄一米，斜着贴墙时车角就留在墙里（见 _hull_half_w 的注释）。
func _settle() -> void:
	position.y = 0.0
	if arena == null:
		return
	# 两趟：第一趟把最深的那处解开，第二趟收掉因平移而新产生的浅层重叠
	for _pass in 2:
		var off := _depen_offset()
		if off.length_squared() < 1e-8:
			break
		global_position += off
	position.y = 0.0
	# 只有整条车身都站在空地上才更新安全点，否则下一次脱出会拿一个墙里的坐标当来向"
	if _spine_clear():
		_safe_pos = global_position


## 逐格汇车体矩形与这格的最小分离平移量"，再合成一个整车平移量。
## 只平移、不改朝向，所以不会出玩被墙拧着车的诡异手感。
func _depen_offset() -> Vector3:
	return _depen_offset_at(global_position, rotation.y)


## 给定位姿下的解交平移量。`_limit_turn()` 要拿它试算"转过去之后推不推得出来"，
## 所以位置与朝向必须能从外面传进来——直接读 global_position 就试算不了别的位姿。
func _depen_offset_at(pos: Vector3, yaw: float) -> Vector3:
	# 车头 / 车尾伸出长度不同，矩形中心因此不在整车原点上：SAT 必须从*轮廓中心**
	# 为基准量 delta，否则车头长的那 0.4 m 会被算成"已经分离"。
	var base := _hull_center(pos, yaw)
	var rx := cos(yaw)
	var rz := -sin(yaw)
	var fx := -sin(yaw)
	var fz := -cos(yaw)
	var half := Arena.CELL * 0.5
	# 只查可能碰到的那一圈格子：车体对角约+ 轮廓中心的偏移+ 半格
	var off_len := absf(_hull_half_f - _hull_half_b) * 0.5
	var reach := sqrt(_hull_half_w * _hull_half_w + _hull_half_l * _hull_half_l) \
			+ half + off_len
	var span := int(ceil(reach / Arena.CELL))
	var c0 := Arena.to_cell(base)

	var off := Vector3.ZERO
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var cx: int = c0.x + dx
			var cy: int = c0.y + dy
			if not arena.blocks_tank(cx, cy):
				continue
			var c := Arena.cell_center(cx, cy)
			var delta := Vector2(base.x - c.x, base.z - c.z)
			if absf(delta.x) > reach or absf(delta.y) > reach:
				continue
			var p: Vector2
			if absf(delta.x) < half and absf(delta.y) < half:
				# 车体中心已经落在这一格里：按来向沿主轴退出去，
				# 否则最近的那条边可能是墙的另一侧（一次传送式的穿墙）
				p = _eject_hull(c, delta, yaw)
			else:
				p = _obb_mtv(delta, rx, rz, fx, fz)
			off.x = _merge_push(off.x, p.x)
			off.z = _merge_push(off.z, p.y)
	off.y = 0.0
	# 封顶：实在解不开时（夹在两墙之间）退回安全点的那一下不该是一次传送
	if off.length() > 1.0:
		off = off.normalized() * 1.0
	return off


## 车体轮廓中心（世界坐标）。车头/ 车尾伸出长度不同，矩形中心沿车头方向
## 偏移 (车头半长 - 车尾半长) / 2；对称的车（图元回退）偏移为 0。
func _hull_center(pos: Vector3, yaw: float) -> Vector3:
	var off := (_hull_half_f - _hull_half_b) * 0.5
	if is_zero_approx(off):
		return pos
	return pos + Vector3(-sin(yaw), 0.0, -cos(yaw)) * off


## 车体中心已经陷进某格时的脱出方向：沿来向的主轴退到格子外面。
## delta 是*轮廓中心**相对格心的偏移（角_depen_offset），所以出格位移直接用
## delta 反推，不必再关心整车原点与轮廓中心的那点偏移。
func _eject_hull(c: Vector3, delta: Vector2, yaw: float) -> Vector2:
	var safe := _hull_center(_safe_pos, yaw)
	var back := Vector2(safe.x - c.x, safe.z - c.z)
	var half := Arena.CELL * 0.5
	# 用最长的半轴做退距，保证整条轮廓都退出去
	var out := maxf(maxf(_hull_half_f, _hull_half_b), _hull_half_w)
	if back.length_squared() > 1e-6:
		if absf(back.x) >= absf(back.y):
			return Vector2(signf(back.x) * (half + out) - delta.x, 0.0)
		return Vector2(0.0, signf(back.y) * (half + out) - delta.y)
	# 连来向都没有：朝当前中心的反方向接
	return Vector2(-delta.x, -delta.y)


## 旋转矩形（车体）与一个格子（轴对齐方格）的最小分离平移量。
## 返回 Vector2.ZERO 表示两者没有重叠。
##
## 二维 SAT：四条分离轴（格存X / 格子 Z / 车体右轴 / 车体前轴）上各自算重叠，
## 取最小的那条轴作为推出方向。车体自身的两条轴不能省——车角顶进墙角时，
## 最小推出方向正是车身的斜向，只测格子的两条轴会推出一来斜着穿墙"的假位移。
func _obb_mtv(delta: Vector2, rx: float, rz: float, fx: float, fz: float) -> Vector2:
	var half := Arena.CELL * 0.5
	var best := INF
	var axis := Vector2.ZERO
	var sgn := 1.0

	# 格子 X 车
	var ro := absf(rx) * _hull_half_w + absf(fx) * _hull_half_l
	var ov := ro + half - absf(delta.x)
	if ov <= 0.0:
		return Vector2.ZERO
	if ov < best:
		best = ov
		axis = Vector2(1.0, 0.0)
		sgn = signf(delta.x)

	# 格子 Z 车
	ro = absf(rz) * _hull_half_w + absf(fz) * _hull_half_l
	ov = ro + half - absf(delta.y)
	if ov <= 0.0:
		return Vector2.ZERO
	if ov < best:
		best = ov
		axis = Vector2(0.0, 1.0)
		sgn = signf(delta.y)

	# 车体右轴（车体在这条轴上的投影半径就是半宽）
	ov = _hull_half_w + half * (absf(rx) + absf(rz)) - absf(delta.x * rx + delta.y * rz)
	if ov <= 0.0:
		return Vector2.ZERO
	if ov < best:
		best = ov
		axis = Vector2(rx, rz)
		sgn = signf(delta.x * rx + delta.y * rz)

	# 车体前轴
	ov = _hull_half_l + half * (absf(fx) + absf(fz)) - absf(delta.x * fx + delta.y * fz)
	if ov <= 0.0:
		return Vector2.ZERO
	if ov < best:
		best = ov
		axis = Vector2(fx, fz)
		sgn = signf(delta.x * fx + delta.y * fz)

	if sgn == 0.0:
		sgn = 1.0
	return axis * (best * sgn)


## 同向取最深的一份、反向才相加。
## 车头车尾各被推0.3 米就平移 0.6 米的话，解交会把车直接弹出去；
## 而一前一后被反向顶住时必须相互抵消，车体才会停在走廊中线上。
static func _merge_push(a: float, b: float) -> float:
	if a * b < 0.0:
		return a + b
	return a if absf(a) >= absf(b) else b


## 整条车身是否都在空地上
func _spine_clear() -> bool:
	return _hull_depth(rotation.y) <= 0.001


## 本帧实际允许加进 rotation.y 的朝向增量。
##
## 判据不是"转过去会不会碰到墙"，而是"转过去之后 `_settle()` 推不推得出来"：
## 只看原始重叠会把贴单侧墙的车判死——车角必然先压进墙一点，可是把整台车朝
## 空地推开就解决了。真正的死局只有两侧同时顶住（单格走廊、车角楔进墙角），
## 那时推量互相抵消，残余压入才会留下来。
##
## 于是贴墙给舵时车是"抵着墙、被挤开、接着转"，而不是"舵被整段否决"；而
## 残余压入超过 `HULL_SCRAPE` 的转角一律不给，车角不会挂进砖墙。
##
## 已经在墙里的朝向以**当前位姿能解到多少**为基准（`resolved_cur`），于是
## 被另一辆车挤进掩体、或重生在刚还原的加固格上之后，仍然能自己转出来，
## 且不会转得更深。
##
## 关键是*不许整段否决**：超限时二分求"这一帧还能转多少"，转向始终连续——
## 停下来是因为几何到头了，而不是因为这一帧的舵被整个丢掉。
func _limit_turn(yaw_delta: float) -> float:
	if is_zero_approx(yaw_delta) or arena == null:
		return yaw_delta
	var gate := maxf(_scrape_gate(), _resolved_depth(global_position, rotation.y))
	var deep := _resolved_depth(global_position, rotation.y + yaw_delta)
	# 整段转得过去（含解交之后），或者本来就压在墙里（此时只要求"不许更深"）
	if deep <= gate:
		return yaw_delta
	turn_blocked = true
	# 二分求这一帧还能转多少。可行性对转角并非严格单调（车头压深时车尾在变浅），
	# 但二分只会**少给**，不会多给：多给的那一侧已经被上面那条挡掉了。
	var lo := 0.0
	var hi := 1.0
	for _i in 7:
		var mid := (lo + hi) * 0.5
		if _resolved_depth(global_position, rotation.y + yaw_delta * mid) <= gate:
			lo = mid
		else:
			hi = mid
	return yaw_delta * lo


## 在给定位姿下，先按 `_settle()` 的方式把车体推出墙，再量剩下的压入深度。
##
## 这是"转得过去"的真正定义：`_settle()` 推得出来（残余 ≤ HULL_SCRAPE）就算
## 可行。它把"转向"和"解交"绑成同一套判据，于是不会出现"判据说能转、推完
## 还挂在墙里"的错位——那正是之前车角切进砖墙的来源。
func _resolved_depth(pos: Vector3, yaw: float) -> float:
	var off := _depen_offset_at(pos, yaw)
	return _hull_depth_at(pos + off, yaw)


## 这一帧转过去之后，_settle() 有没有把车体推回空地。
##
## 单格走廊里两侧墙同时顶住，推不出来——此时宁可把转角收回到最后能站住的那一档，
## 也不能让画面上看得见的车角切进砖墙。贴着单侧墙时 _settle() 能把车挤开，
## 这里就什么都不做，转向照常继续（这就是抵着墙还能转"的来源）。
func _undo_unresolved_turn(yaw_before: float, depth_before: float) -> void:
	if arena == null:
		return
	var total := angle_difference(yaw_before, rotation.y)
	if absf(total) < 1e-5:
		return
	# 门槛取"擦墙余量"与"这一帧开始时的压入深度"的较大者。
	#
	# 只取 _scrape_gate() 是不够的：车被另一辆车挤进掩体、或从窄口里被推进来的
	# 时候，起始深度本来就大于门槛，于是一个"没有转得更深"的合法转角也会被
	# 整段收回去——转向几何上完全可行，玩家按 A/D 却是零反应。这与 _limit_turn()
	# 的基准必须同宽，否则两处判定互相拆台，车就死在墙角里。
	var gate := maxf(_scrape_gate(), depth_before)
	if _hull_depth(rotation.y) <= gate:
		return
	# 以肯定能站位有这一帧想转的角度"二分，取最大的可行比例
	var lo := 0.0
	var hi := 1.0
	for _i in 6:
		var mid := (lo + hi) * 0.5
		if _hull_depth(yaw_before + total * mid) <= gate:
			lo = mid
		else:
			hi = mid
	rotation.y = yaw_before + total * lo
	if lo < 1.0:
		turn_blocked = true
	_settle()


## 这一帧的位移有没有把车体更深的塞进掩体。
##
## `_settle()` 只能做*解交*：单侧有墙时它把整台车推开，两侧同时顶住（单格走廊、
## 车头楔进墙角）时两边的推量相互抵消，车体就带着车角留在墙里继续往前开——
## 这就是玩家看到的那种"坦克半截穿进砖墙还在走"（tools/_drive_clip_probe.gd 的
## corr 15 / corr 25 两行：压进 0.20 / 0.60 m，300 帧里 300 帧都在墙里）。
##
## 所以位移也要有和转向一样的复查：**不许比这一帧开始时更深**。二分退回能站住的
## 最大比例，于是走廊里斜着顶墙时车会真的刹住、而不是穿过墙继续滑行；
## 反向倒车（变浅）不受任何影响。
func _undo_unresolved_move(from: Vector3, depth_before: float) -> void:
	if arena == null:
		return
	var gate := maxf(HULL_SCRAPE, depth_before)
	if _hull_depth(rotation.y) <= gate + 1e-4:
		return
	var to := global_position
	if from.is_equal_approx(to):
		return
	var lo := 0.0
	var hi := 1.0
	for _i in 7:
		var mid := (lo + hi) * 0.5
		global_position = from.lerp(to, mid)
		if _hull_depth(rotation.y) <= gate + 1e-4:
			lo = mid
		else:
			hi = mid
	global_position = from.lerp(to, lo)
	_settle()


## 转向后允许残留的压入深度（m）。
##
## 现在只有一个来源：`HULL_SCRAPE`。原来那套"停住的车放宽到 18 cm"已经删掉——
## 它换来的转向角度不到 10°，代价却是车角明明白白挂在墙里（玩家看到的就是穿墙）。
## 贴墙转向改由 `_limit_turn()` 的"转过去推不推得出来"判据负责：单侧墙推得出来，
## 照转，不需要靠压进墙换角度。
func _scrape_gate() -> float:
	return HULL_SCRAPE


## 车体矩形压进实心格的最大深度（m），完全没压到时为0。
func _hull_depth(yaw: float) -> float:
	return _hull_depth_at(global_position, yaw)


## 给定位姿下压进实心格的最大深度（m）。
func _hull_depth_at(pos: Vector3, yaw: float) -> float:
	var base := _hull_center(pos, yaw)
	var rx := cos(yaw)
	var rz := -sin(yaw)
	var fx := -sin(yaw)
	var fz := -cos(yaw)
	var half := Arena.CELL * 0.5
	var off_len := absf(_hull_half_f - _hull_half_b) * 0.5
	var reach := sqrt(_hull_half_w * _hull_half_w + _hull_half_l * _hull_half_l) \
			+ half + off_len
	var span := int(ceil(reach / Arena.CELL))
	var c0 := Arena.to_cell(base)
	var deep := 0.0
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var cx: int = c0.x + dx
			var cy: int = c0.y + dy
			if not arena.blocks_tank(cx, cy):
				continue
			var c := Arena.cell_center(cx, cy)
			var delta := Vector2(base.x - c.x, base.z - c.z)
			if absf(delta.x) > reach or absf(delta.y) > reach:
				continue
			deep = maxf(deep, _obb_mtv(delta, rx, rz, fx, fz).length())
	return deep


## 分离判定用的车身轴线半长（m）。坦克是 4~6 米长的长方体，
## 拖中心路< 两个半径之和"判断有没有叠在一起，会漏掉最常见的两种工况：
## 丁字相撞与首尾相接——那时两个中心离得很远，车体却实实在在压在一起。
func spine_half() -> float:
	return maxf(body_length * 0.5 - body_radius, 0.05)


## 车身轴线在世界坐标里的两个端点（车头侧、车尾侧）
func spine() -> Array:
	var fwd := -global_transform.basis.z
	var h := spine_half()
	return [global_position + fwd * h, global_position - fwd * h]


## 被其它坦克推开。CharacterBody3D 之间不会互相推挤，两辆车一旦重叠就谁也动不了，
## 所以分离位移由 main 每物理帧算好后推到这里，推完立刻过一遍网格约束，
## 免得"解开叠车"反而把谁挤进了墙里。
##
## 返回实际挪动的位移：想推的方向可能被墙吃掉，调用方据此把剩下的量转给对方，
## 否则"一辆车贴着墙、另一辆顶着它会永久僵住。
func nudge(offset: Vector3) -> Vector3:
	if not alive:
		return Vector3.ZERO
	var before := global_position
	var yaw := rotation.y
	# 这一帧允许的最大压入深度：不比现在更深。门槛与 drive() 的
	# _undo_unresolved_move 同源，于是"被顶开"与"自己开"两条路径不会互相拆台。
	var gate := maxf(HULL_SCRAPE, _hull_depth(yaw)) + 1e-4

	global_position += Vector3(offset.x, 0.0, offset.z)
	_settle()
	# 推不进去（另一辆车正把本车朝墙里按）时，二分退回"不加深"的最大比例。
	#
	# 不能只依赖 _settle()：解交是把整台车朝空地推开，两侧同时顶住时两边的推量
	# 相互抵消，于是 3~4 m 的一步会留下 0.65~1.65 m 的车身挂在墙里
	# （tools/_PushThroughProbe.tscn 的 push=3/4 两行）——那就是玩家看到的穿墙。
	# 二分只会**少给**：推得动的时候一步都不少推，推不动的时候宁可这一帧不推，
	# 让 main 把欠的那份转给另一辆车（它本来就有这条回路）。
	if _hull_depth(yaw) > gate:
		var want := global_position - before
		var lo := 0.0
		var hi := 1.0
		for _i in 6:
			var mid := (lo + hi) * 0.5
			if _resolved_depth(before + want * mid, yaw) <= gate:
				lo = mid
			else:
				hi = mid
		global_position = before + want * lo
		_settle()
	# 被顶开时按实际位移量掉一点动能。
	# 原来是每次调用固定乘 0.86——而这个函数在接触期间每物理帧都会被调用，
	# 120Hz 下等于一碰上就瞬间刹停，这是"两辆车叠在一起动不了"的另一半原因。
	var moved := (global_position - before).length()
	if moved > 0.0:
		_speed = move_toward(_speed, 0.0, moved * 0.8)
	return global_position - before


## 每行驶2.2 米投一枚履带印贴花。按距离而非时间触发，所以快车慢车留下的间距一致。
func _lay_tracks() -> void:
	if arena == null:
		return
	_track_dist += absf(_speed) * get_physics_process_delta_time()
	if _track_dist < 2.2:
		return
	_track_dist = 0.0
	arena.add_track(global_position - global_transform.basis.z * 0.8, rotation.y)


## 履带链节撞击声，每行驶3.4 米一下。
##
## 现实里坦克是先被听见再被看见的，而听见的是履带而不是发动机——
## 所以这一声是"听声辨位"成立的前提：绕过掩体的敌人在出现之前就有声音。
## 按距离触发（而不是按时间）于是节奏自然跟着车速变快变慢，不必额外调。
## 可听半径压到 55 米：七辆车同时跑，这是不把28 路语音位挤爆的关键。
func _track_noise(delta: float) -> void:
	var sp := absf(_speed)
	if sp < 1.0:
		_track_snd = 0.0
		return
	_track_snd += sp * delta
	if _track_snd < 3.4:
		return
	_track_snd = 0.0
	# 慢速挪动是闷响，全速冲刺才哗啦作响
	var r := clampf(sp / maxf(move_speed, 0.01), 0.0, 1.0)
	Audio.play_3d("track", global_position, lerpf(-19.0, -9.0, r), 55.0)


## 正面撞上障碍时按夹角吃掉动能；擦着墙滑行几乎不掉。
##
## 量必须按"每秒"给，不能按每帧"给一个固定比例。原来的写法是每帧
## `_speed *= (1 - bite * 0.55)`，在 120 Hz 下等于一碰上就瞬间刹停：车头以12° 蹭到
## 单格宽走廊的侧墙（bite 0.21）时，速度在0.3 秒里以15 m/s 掉到 1 m/s，之后*一直*
## 以1 m/s 爬行——因为每帧加递一每帧掉递正好在这个速度上打平
## ，4/120 = v * 0.21 * 0.55，解出v ≤1.0）。玩家看到的就是"窄通道里车会卡住，
## 反打方向也走不出来。实测拐点恰好落在asin(0.2) ≈11.5°，0° 入射全程 15 m/s
## 无损，2° 就到 0.9 m/s、5° 到0.7 m/s、5° 到0.4 m/s
## （tools/corridor_probe.gd 的biteTrace 一行）。
##
## 曲线取(bite - 0.35)³，速率上限 16/秒：30° 以内的擦碰几乎不计——走廊里贴着墙
## 开过去本来就该无损，几何上的损失已经由 move_and_slide 沿墙投影吃掉了；
## 越接近正面掉得越狠，于是"正面撞墙顿一下的手感保留，
## "擦墙滑行几乎不掉"（验收清单）成立。取立方而不是平方，是为了让拐点足够靠右：
## 25° 蹭墙（bite 0.42）只掉2%/秒，45° 掉2.6/秒，正面 16/秒——三者拉得开，
## 中间没有"半死不活"的速度区间。
##
## 多个接触面只按最深的那个算一次，而不是逐面各扣一次：夹在两墙之间时，
## 逐面累加的扣量按接触面数量翻倍，走廊里正好会被两侧墙一起扣。
const IMPACT_BLEED_MAX := 16.0
func _bleed_on_impact(delta: float) -> void:
	if absf(_speed) < 0.1:
		return
	var head := (-global_transform.basis.z * signf(_speed)).normalized()
	var bite := 0.0
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		n.y = 0.0
		if n.length_squared() < 0.001:
			continue
		bite = maxf(bite, clampf(-head.dot(n.normalized()), 0.0, 1.0))
	# 法线竖直的接触是地面，上面已经被 n.y = 0 过滤掉了，不会进到这里
	var t := clampf((bite - 0.35) / 0.65, 0.0, 1.0)
	if t <= 0.0:
		return
	_speed = move_toward(_speed, 0.0, absf(_speed) * IMPACT_BLEED_MAX * t * t * t * delta)


func _animate_tracks(delta: float) -> void:
	var sr := _speed / maxf(move_speed, 0.01)
	_tread_phase += sr * delta * 6.0
	# 车体随行进起伏：模型路径动整棵子树，图元路径只动车体网格
	var bob := sin(_tread_phase * 3.0) * 0.035 * absf(sr)
	if _model != null:
		_model.position.y = _hull_base_y + bob
		# 负重轮按真实线速度滚动，轮子已在Blender 侧烘掉摆放旋转，直接写rotation.x
		var spin := _speed * delta / maxf(_wheel_radius, 0.05)
		for w in _wheels:
			w.rotation.x += spin
		return
	if _hull_mesh != null:
		_hull_mesh.position.y = _hull_base_y + bob
	if _tread_l != null:
		_tread_l.position.y = 0.45 - bob * 0.5
	if _tread_r != null:
		_tread_r.position.y = 0.45 - bob * 0.5


## 当前车速（m/s，带符号）
func speed() -> float:
	return _speed


## 仪表用：km/h 绝对值
func speed_kmh() -> float:
	return absf(_speed) * 3.6


## 挡位提示： 前进 / 0 空挡 / -1 倒车
func gear() -> int:
	if _speed > 0.3:
		return 1
	if _speed < -0.3:
		return -1
	return 0


## 把炮塔与炮管转向世界坐标目标点，返回是否已基本对准
func aim_at(target: Vector3, delta: float) -> bool:
	if turret == null:
		return false
	aim_point = target
	var local := to_local(target)
	var flat := Vector2(local.x, local.z).length()
	return aim_at_angles(
			rotation.y + atan2(-local.x, -local.z),
			atan2(local.y - aim_height, maxf(flat, 0.5)),
			delta)


## 直接按世界角度回转炮塔。玩家走这条路：鼠标给的本来就是角度，
## 不必再绕一个世界坐标点，近距离瞄墙时也不会因为落点抖动而歪。
##
## turret_limit > 0 时按射界夹住目标角，并置 turret_blocked——注意这里是
## **夹住而不是否写*：炮塔照常以自身回转速度走到限位，玩家看到的是炮塔到边了，
## 而不是鼠标没反度。
func aim_at_angles(world_yaw: float, want_pitch: float, delta: float) -> bool:
	if turret == null:
		return false
	var want := wrapf(world_yaw - rotation.y, -PI, PI)
	turret_blocked = false
	if turret_limit > 0.0 and absf(want) > turret_limit:
		want = signf(want) * turret_limit
		turret_blocked = true
	var rate := 0.0 if is_emp() else turret_speed
	var dy := angle_difference(turret.rotation.y, want)
	# 误差越大回转越快：大角度甩炮迅速，临门微调仍然稳
	if rate > 0.0 and turret_snap > 0.0:
		rate *= 1.0 + clampf(absf(dy) / PI, 0.0, 1.0) * turret_snap
	turret.rotation.y = wrapf(turret.rotation.y + clampf(dy, -rate * delta, rate * delta), -PI, PI)

	# 俯仰**不做平滑**，直接跟住瞄准角。
	#
	# 原来按`delta * 6` 插值（时间常数约0.17 秒）：准星已经压到6 米外的敌车中心，
	# 炮管还停在上一帧的高度上，这时扣扳机，炮弹就沿着"还没压下压的炮管飞出去。
	# 实测炮管比准星高 5.5° 时，6 米处的弹道比敌车中心高1.2 米、从炮塔顶上掠过：
	# 一路飞出一百四十多米（tools/flick_probe.gd 的甩炮即射"一栏）。
	# 这恰好是近距离交战最容易被看见的地方——为了打到6 米外的车，炮口本来就得压
	# 到-5.7°，甩鼠标的幅度最大，滞后也最大，玩家的感受就是炮台抬得太高、打到天上。
	#
	# 俯仰本来就没有机械惯性可言：行程只有24°，鼠标给的就是绝对角度，平滑在这量
	# 只剩下输入延迟。炮塔yaw 仍然只turn_speed 约束（那是射界与炮塔转速这套玩法）：
	# 俯仰则必须是即时的——点哪打哪"只对纵向成立，也只需要对纵向成立。
	barrel.rotation.x = clampf(want_pitch, PITCH_MIN, PITCH_MAX)
	return absf(dy) < 0.06


## 目标点是否落在炮管俯仰范围内（HUD 用来提示"这个点打不到"）
func can_elevate_to(target: Vector3) -> bool:
	var local := to_local(target)
	var flat := Vector2(local.x, local.z).length()
	var want := atan2(local.y - aim_height, maxf(flat, 0.5))
	return want > PITCH_MIN - 0.02 and want < PITCH_MAX + 0.02


## 炮管指向的世界方向
func aim_dir() -> Vector3:
	return -barrel.global_transform.basis.z.normalized()


func muzzle_pos() -> Vector3:
	return muzzle.global_position


## 炮弹的出发点：默认就是炮口，但目标比炮口还近时沿炮管轴收回来。
##
## 炮口在车头前约3.8 m。两辆车贴到一起时（车身半径各 1.5 m，车心距 3~5 m），
## 炮口已经**越过对方车体**：炮弹从目标内部出发，而物理射线的 hit_from_inside
## 默认关闭，第一段射线什么都打不到，那一发就直接穿过去飞走。
## 所以出发点收回到炮塔耳轴与目标之间，保证起点永远在目标之前。
##
## 这一条与 PITCH_MIN 是一对：俯角够深只是让炮算*挑*得对，出发点还在目标重
## 照样打不中；反过来只收回出发点、俯角不够深，弹道仍然从车顶擦过去。
func shot_origin(dir: Vector3) -> Vector3:
	if barrel == null:
		return muzzle_pos()
	var base := barrel.global_position
	var tip := muzzle.global_position
	var span := base.distance_to(tip)
	if aim_point == Vector3.INF:
		return _clear_origin(base, dir, span)
	var reach := (aim_point - base).dot(dir)
	return _clear_origin(base, dir, clampf(reach * 0.5, 0.0, span))


## 把出发点以已经落进另一辆车里的位置沿炮管轴往回退。
##
## 两台车贴判3~4 m 时炮口（车头前3.8 m）已经插进对方车体。炮弹若从对方*内部**
## 出生，物理射线的 hit_from_inside 默认关闭，第一段什么都打不到——那一发就穿过压
## 飞走，玩家看到的是贴脸打空、炮弹飞到天上。所以不论候选点是怎么算出来的，
## 出发前都要验一次这里不在任何坦克体内"。
func _clear_origin(base: Vector3, dir: Vector3, dist: float) -> Vector3:
	var d := dist
	while d > 0.0 and _point_in_tank(base + dir * d):
		d = maxf(0.0, d - 0.4)
	return base + dir * d


func _point_in_tank(at: Vector3) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = at
	q.collision_mask = LAYER_TANK
	q.collide_with_areas = false
	q.exclude = [get_rid()]
	return not get_world_3d().direct_space_state.intersect_point(q).is_empty()


## 炮管这条直线最终打在哪：命中点；*什么都没打到时返回 Vector3.INF**。
##
## 这里不能返回"远处一点：HE 的抬升量是按这个距离解出来的，
## 而炮管的正上方与正前方都没有几何体时，一个假的远点会把弹道解成迫击炮。
## 实测（tools/he_probe.gd）拿 LOB_RANGE=220 米当兜底点时，解出来的炮口仰角是 21.3°，
## 而HE 的解算上限只有11°——炮弹从 36 米外的敌车头顶12 米处飞过，
## 屏幕上就成了"切了弹种就变高射炮。调用方（fire()）拿到INF 会退回平直发射。
func _line_of_fire_point(origin: Vector3, dir: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			origin, origin + dir * LOB_RANGE, LAYER_WORLD | LAYER_TANK)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return Vector3.INF
	return hit["position"]


## HE 的发射方向。两步：
##   1. 沿炮管方向找出准星实际落在哪（命中点或INF）；
##   2. 解一条正好落在那里的低抛弹道——HE 只有 112 m/s 又吃重力，直瞄发射会低掉
##      好几米，抬升量必须按落点解出来，否则"准星指哪"和炮弹落哪"是两件事。
##
## 两条退路都是*平直发射**，而不是换一个更远的目标去解"：
##   * 没有落点（准星指向天空或地图外）——没有落点可解；
##   * 解出来的仰角超过 `Shell.HE_SOLVE_MAX`（1°）——地图里没有那么远的落点，
##     再往上解就是拿一个兜底点当目标，炮弹会从敌人头顶飞过。
##
## 这里比的是**HE 的解算上限*，不是炮管上限：炮管上限 6° 是手感量：
## 准星压在 100 m 外的敌车上时炮管几乎是平的，弹道却要抬7.4° 才落得上去。
## 实测这两条退路把最坏落点偏差从 12.2 米收到1 米以内（tools/he_probe.gd）。
func he_dir(origin: Vector3, dir: Vector3) -> Vector3:
	var pt := _line_of_fire_point(origin, dir)
	if pt == Vector3.INF:
		return dir
	var lob := Shell.lob_dir(origin, pt, dir)
	if asin(clampf(lob.y, -1.0, 1.0)) > Shell.HE_SOLVE_MAX:
		return dir
	return lob


func can_fire() -> bool:
	return alive and reload_t <= 0.0 and not is_emp()


## 直瞄弹该往哪飞：炮管姿态只是*视觉**，真正该去的地方是准星打中的那个点。
##
## 两台车贴近时，玩家的准星自然压在敌车炮塔顶上（那是画面里最大的一块），
## 而炮管抬判+6° 就到顶了（ m 处指同2.4 m 高的塔顶需要+12°，差的这 6° 让弹道
## 从塔顶擦过去。AP 弹没有重力，擦过去以后一路爬升，6 秒能飞出一百多米——
## 玩家看到的就是炮台抬得太高、导弹打到天一。
##
## 所以发射方向按 `aim_point`（准星射线真实打中的点）解，而不是按 `aim_dir()`。
## 好处不止是近距离：中远距离准星压在车体轮廓上而命中体是圆柱或略窄时，炮弹同样
## 会落在准星上，而不会落在炮管延长线指向的附近某处"。
##
## 两条退路都退回炮管方向：
##   * 准星什么都没打到（`aim_point` 是300 m 兜底点）——玩家瞄的就是天空；
##   * 准星与炮管夹角超过`AIM_SOLVE_CONE`——炮塔还没转过来，这一发本来就不该打。
func aim_solution(barrel_dir: Vector3) -> Vector3:
	if barrel == null or aim_point == Vector3.INF:
		return barrel_dir
	var to := aim_point - barrel.global_position
	var dist := to.length()
	if dist < 0.5 or dist > AIM_SOLVE_MAX:
		return barrel_dir
	var solved := to / dist
	if barrel_dir.angle_to(solved) > AIM_SOLVE_CONE:
		return barrel_dir
	return solved


func fire() -> bool:
	if not can_fire():
		return false
	reload_t = reload_time
	shot_count += 1
	_recoil = 0.55
	var kind := shell_kind if can_use_he else Shell.Kind.AP
	var dir := aim_solution(aim_dir())
	var origin := shot_origin(dir)
	# HE 走抛物线，所以发射方向不能直接用炮管指向，交给he_dir() 解一条
	# 正好落在准星上的低抛弹道。于是换弹种不改变瞄准方式——准星压住谁就打中谁。
	if kind == Shell.Kind.HE:
		dir = he_dir(origin, dir)
	game.spawn_shell(self, origin, dir, kind)
	# 多弹装填：左右各加一发小散布，正面弹幕厚一倍但不改单发伤害
	if multi_t > 0.0:
		for s in [-1.0, 1.0]:
			game.spawn_shell(self, origin, dir.rotated(Vector3.UP, deg_to_rad(2.4) * s), kind)
	Fx.muzzle_flash(game.fx_root, muzzle_pos(), dir)
	Audio.play_3d("shoot", muzzle_pos())
	return true


func toggle_shell() -> void:
	if not can_use_he:
		return
	shell_kind = Shell.Kind.HE if shell_kind == Shell.Kind.AP else Shell.Kind.AP
	Audio.play("switch")


# ---------------- 受击 ----------------

## 返回 "shield" / "ricochet" / "hit" / "kill"，并输出实际伤害到out_dmg[0]
func take_hit(amount: int, from_pos: Vector3, kind: int, out_dmg: Array = []) -> String:
	if not alive:
		return "none"
	hit_count += 1
	if shield_t > 0.0:
		Audio.play_3d("steel", global_position)
		return "shield"

	var to_hit := from_pos - global_position
	to_hit.y = 0.0
	if to_hit.length() < 0.01:
		to_hit = Vector3.FORWARD
	# 入射方向与车体正面的夹角：° 正面，80° 背面
	var fwd := -global_transform.basis.z
	var ang := rad_to_deg(fwd.angle_to(to_hit.normalized()))

	var mult := armor_side
	var zone := "侧面"
	if ang < 55.0:
		mult = armor_front
		zone = "正面"
		# 正面被AP 弹以大角度擦到有几率跳弹
		if kind == Shell.Kind.AP and ang > 32.0 and randf() < 0.30:
			Audio.play_3d("ricochet", global_position)
			return "ricochet"
	elif ang > 125.0:
		mult = armor_rear
		zone = "背面"

	if armor_buff_t > 0.0:
		mult *= 0.6

	var dmg := maxi(1, int(round(amount * mult)))
	hp -= dmg
	if out_dmg.size() > 0:
		out_dmg[0] = dmg
	if out_dmg.size() > 1:
		out_dmg[1] = zone
	if is_player and game.has_method("on_player_hit"):
		game.on_player_hit(from_pos, dmg)

	Fx.hit_spark(game.fx_root, global_position + Vector3(0, 1.6, 0) + to_hit.normalized() * 1.6)
	if hp <= 0:
		destroy(true)
		return "kill"
	Audio.play_3d("steel", global_position)
	return "hit"


func destroy(_by_shell: bool) -> void:
	if not alive:
		return
	alive = false
	Fx.explosion(game.fx_root, global_position + Vector3(0, 1.2, 0), 1.6)
	if arena != null:
		arena.add_scorch(global_position, 1.3)
	Audio.play_3d("boom", global_position)
	game.on_tank_destroyed(self)
	queue_free()
