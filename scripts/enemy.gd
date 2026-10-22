class_name Enemy
extends Tank
## 敌方坦克 AI：A* 寻路推进、视线判定、提前量预瞄射击，并按血量与距离切换包抄 / 后撤。
##
## 车型：0 侦察 / 1 中型 / 2 重型 / 3 火炮 / 4 Boss
## 难度 (0-2) 影响瞄准误差、反应时间与射速。

enum State { SEEK, ENGAGE, FLANK, RETREAT }

var etype := 0
var points := 100
var difficulty := 1

var state := State.SEEK
## 本帧是否看得见玩家。HUD 用它显示"被发现"指示灯；
## 与 sees 判定同源，避免界面和 AI 各算一套。
var sees_player := false
var target: Tank = null

var _path: Array = []
var _repath_t := 0.0
var _state_t := 0.0
var _aim_err := Vector3.ZERO
var _aim_err_t := 0.0
var _react_t := 0.0
var _flank_side := 1.0
var _stuck_t := 0.0
var _last_pos := Vector3.ZERO
var _unstuck_t := 0.0
var _engage_range := 46.0
var _prefer_range := 18.0
## 侧绕掷骰的冷却（见 _roll_flank）。0 表示"这一轮可以掷了"。
var _flank_roll_t := 0.0
## 掩体行为：装填期间退到"能挡住玩家视线"的格子后，装填完再开出来。
## _cover_pos 是选中的掩体点（Vector3.INF 表示没有），_cover_t > 0 表示
## 正在掩体行为中。_peek_pos / _peek_t 是装填结束后探头的位置与剩余时间。
var _cover_pos := Vector3.INF
var _cover_t := 0.0
var _peek_pos := Vector3.INF
var _peek_t := 0.0
## 选掩体的搜索冷却。`_find_cover()` 是几十次网格步进，没有冷却的话
## "附近没掩体"的敌人会在整段装填时间里每帧搜一次（120 Hz × 48 个候选格），
## 帧率会被这几台找不到墙的车吃掉。
var _cover_search_cd := 0.0
## 掩体搜索范围：以自身为圆心 3 格（12 m）内，且不超过 14 m。
## 再远就来不及在装填结束前退回去，行为会退化成"整场都在赶路"。
const COVER_SEARCH_CELLS := 3
const COVER_MAX_DIST := 14.0
## 草丛隐蔽的有效距离：超过这个距离就看不见蹲草的玩家。
## 20 m 大致是"一辆车从掩体后开到你面前"所需的时间，玩家有反应余地。
const CONCEAL_SIGHT := 20.0
## 敌车发动机循环。由 main 按距离开关，最多同时 3 台（见 set_engine_on）。
var _engine: AudioStreamPlayer3D


func configure(t: int, stage: int, diff: int) -> void:
	etype = t
	difficulty = diff
	match t:
		0:  # 侦察：快、脆、贴脸骚扰
			max_hp = 150
			move_speed = 17.0
			turn_speed = 3.0
			turret_speed = 3.2
			reload_time = 1.9
			damage = 45
			points = 100
			body_radius = 1.35
			body_length = 3.9
			_prefer_range = 13.0
			_engage_range = 38.0
			armor_front = 0.85
		1:  # 中型：均衡主力
			max_hp = 280
			move_speed = 12.5
			turn_speed = 2.2
			turret_speed = 2.4
			reload_time = 2.6
			damage = 70
			points = 200
			armor_front = 0.7
			body_length = 4.4
			_prefer_range = 20.0
		2:  # 重型：慢、硬、正面难打
			max_hp = 450
			move_speed = 8.5
			turn_speed = 1.5
			turret_speed = 1.6
			reload_time = 3.6
			damage = 110
			points = 400
			body_radius = 1.75
			body_length = 4.9
			armor_front = 0.45
			armor_side = 0.9
			_prefer_range = 16.0
		3:  # 火炮：远程高爆、拉开距离、极脆
			max_hp = 170
			move_speed = 9.5
			turn_speed = 1.8
			turret_speed = 1.3
			reload_time = 4.4
			damage = 130
			points = 500
			can_use_he = true
			shell_kind = Shell.Kind.HE
			body_length = 4.6
			armor_front = 1.1
			armor_side = 1.3
			_prefer_range = 40.0
			_engage_range = 70.0
		4:  # Boss：巨型指挥车
			max_hp = 1100
			move_speed = 8.0
			turn_speed = 1.3
			turret_speed = 1.9
			reload_time = 1.9
			damage = 130
			points = 2000
			body_radius = 2.3
			body_length = 6.0
			armor_front = 0.45
			armor_side = 0.7
			armor_rear = 1.3
			_prefer_range = 22.0
			_engage_range = 60.0
			_hull_size = Vector3(4.6, 1.4, 6.0)

	# 炮管耳轴高度必须跟着模型走。
	#
	# `Tank.aim_at()` 用它把目标点换算成俯仰角，玩家侧是从名册的尺寸真值表取的；
	# 敌车一直沿用基类默认的 1.9 m，于是五款车全都在用"别人的耳轴"瞄准：
	# Boss 的真实耳轴是 2.55 m（高出 0.65），火炮车只有 1.70 m（低 0.2）。
	# 近距离交战时这点误差直接变成"炮口没指向目标"——Boss 的炮管偏低、炮弹从玩家
	# 头顶擦过去，低车则把炮弹压进地面。模型换了，这个数就必须跟着换。
	aim_height = float(TankRoster.dims(model_key())["aim_y"])

	# 关卡与难度成长
	var growth := 1.0 + minf(stage - 1, 7) * 0.09
	max_hp = int(max_hp * growth)
	damage = int(damage * (1.0 + minf(stage - 1, 7) * 0.05))
	match diff:
		0:
			max_hp = int(max_hp * 0.8)
			damage = int(damage * 0.7)
			reload_time *= 1.35
		2:
			max_hp = int(max_hp * 1.2)
			damage = int(damage * 1.2)
			reload_time *= 0.8
	hp = max_hp


## 车体涂装。亮度不是美术偏好而是判据：涂装值太低的车在暗图上直接压进黑场，
## 所以这里每种车型的主色都保持在能与地面拉开灰阶的亮度上
## （验收见 tools/vis_probe.gd 的 enemyLum / weber 两列）。
func hull_color() -> Color:
	match etype:
		0: return Color(0.62, 0.58, 0.28)
		2: return Color(0.42, 0.45, 0.52)
		3: return Color(0.56, 0.38, 0.56)
		4: return Color(0.60, 0.20, 0.20)
		_: return Color(0.64, 0.38, 0.26)


func accent_color() -> Color:
	return Color(0.95, 0.35, 0.25) if etype == 4 else Color(0.9, 0.45, 0.2)


## 敌车的炮塔顶盖识别色块自发光。
##
## 这是"看得见敌人"的兜底：自发光是加性的，所以亮图上它被环境光盖住、几乎看不出来，
## 暗图上却成了明确的信标；同理，敌车与地面灰阶撞车（雪原、沙漠）时，
## 这块色块仍然能把轮廓从背景里挑出来。于是不必为十二张地形各调一次光照。
## Boss 给得更强一点：它本来就该在进场的那一刻被认出来。
func accent_glow() -> float:
	return 1.5 if etype == 4 else 0.9


## 可读性底光按地形取值：环境越暗，敌人车体需要的"与光照无关的最低亮度"越高。
## 0.035 是白天的基准，暗图由 Arena 的 enemy_lift 覆盖（见 vis_probe 的 enemyLum）。
func readability_floor() -> float:
	if arena == null:
		return 0.035
	return arena.enemy_readability()


## 敌车轮廓描边：冷色、只落在掠射边缘。
##
## 原来"敌车可读"全靠 readability 把整车自发光抬高——暗图上是必要的，
## 但它也会在亮图上把车读成一块发光的模型。描边补的是另一件事：
## 车体明度不变，轮廓外侧多出 2~3 像素的冷色，敌车与墙面、地面交界处
## 永远有一条明度台阶。两件事叠在一起，才是"看得见"而不是"在发光"。
##
## 0.9 是实测取值：再高会在近距离变成一道荧光边，0.6 以下在 45 m 处
## 只剩不到一个像素宽，等于没描。
func edge_glow() -> float:
	if etype == 4:
		return 1.1
	return 0.9


## 车型 → Blender 模型。索引与 configure() 的 etype 分支一一对应。
func model_key() -> String:
	match etype:
		0: return "tank_scout"
		2: return "tank_heavy"
		3: return "tank_artillery"
		4: return "tank_boss"
		_: return "tank_medium"


func _ready() -> void:
	super._ready()
	_last_pos = global_position
	_flank_side = 1.0 if randf() < 0.5 else -1.0
	_build_engine_audio()


## ---- 敌车发动机声 ----
##
## 敌车原来是完全无声的：玩家只能靠看得见，绕到身后的敌人没有任何听觉预警。
## 一个低音量的 3D 循环就够，但必须限量——七辆车各挂一路循环会一直占着语音位，
## 而发动机声是最不紧急的那一层。所以由 main 按距离挑最近的 3 台打开，
## 其余静音（节点常驻但不播放，开关只是 playing）。
func _build_engine_audio() -> void:
	var st := Audio.engine_stream()
	if st == null:
		return
	_engine = AudioStreamPlayer3D.new()
	_engine.stream = st
	_engine.unit_size = 10.0
	_engine.max_distance = 48.0
	_engine.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_engine.bus = Audio.BUS_ENGINE
	_engine.volume_db = -19.0
	_engine.position = Vector3(0, 0.8, 1.4)
	add_child(_engine)


func set_engine_on(on: bool) -> void:
	if _engine == null:
		return
	if on and not _engine.playing:
		_engine.play()
	elif not on and _engine.playing:
		_engine.stop()


func _update_engine_pitch() -> void:
	if _engine == null or not _engine.playing:
		return
	var r := clampf(absf(speed()) / maxf(move_speed, 0.01), 0.0, 1.2)
	_engine.pitch_scale = clampf(0.78 + r * 0.7, 0.5, 2.0)


# ---------------- 主循环 ----------------

func tick(delta: float) -> void:
	if not alive:
		sees_player = false
		return
	if game.state != "play":
		sees_player = false
		drive(0.0, 0.0, delta)
		return

	_state_t += delta
	_repath_t -= delta
	_aim_err_t -= delta
	_react_t = maxf(0.0, _react_t - delta)
	_unstuck_t = maxf(0.0, _unstuck_t - delta)
	_cover_t = maxf(0.0, _cover_t - delta)
	_peek_t = maxf(0.0, _peek_t - delta)
	_cover_search_cd = maxf(0.0, _cover_search_cd - delta)

	target = _pick_target()
	var goal := _goal_position()
	var sees := target != null and _can_see(target)
	sees_player = sees

	_update_state(sees, delta)

	if _aim_err_t <= 0.0:
		_aim_err_t = randf_range(0.35, 0.9)
		var spread: float = [3.2, 1.9, 1.0][difficulty] * (1.0 + _prefer_range * 0.012)
		_aim_err = Vector3(randf_range(-spread, spread), 0.0, randf_range(-spread, spread))

	# 脱困优先于一切行为：被掩体或另一辆坦克卡住时先倒车转向脱开，
	# 否则一旦在 ENGAGE/FLANK 状态下顶住什么东西，就会一直顶到死
	if _unstuck_t > 0.0:
		drive(-0.85, _flank_side, delta)
		if target != null:
			aim_at(_predict(target), delta)
		_check_stuck(delta)
		return

	match state:
		State.ENGAGE:
			_do_engage(delta)
		State.FLANK:
			_do_flank(goal, delta)
		State.RETREAT:
			_do_retreat(delta)
		_:
			_do_seek(goal, delta)

	_check_stuck(delta)
	_update_engine_pitch()
	_update_flank_roll(delta)


func _pick_target() -> Tank:
	var p = game.player
	if p != null and is_instance_valid(p) and p.alive:
		return p
	return null


## 看不到玩家时推进目标是基地——保留"守家"这一核心压力
func _goal_position() -> Vector3:
	if target != null and (state == State.ENGAGE or state == State.FLANK or _state_t < 30.0):
		return target.global_position
	return arena.base_position()


func _can_see(t: Tank) -> bool:
	var d := global_position.distance_to(t.global_position)
	if d > _engage_range:
		return false
	# 烟雾弹在中远距离上遮蔽视野
	if t.has_method("is_smoked") and t.is_smoked() and d > 11.0:
		return false
	# 草丛隐蔽：站在灌木 / 芦苇里，中远距离看不见；开火后 expose_t 会让它失效。
	# 近距离（20 m 内）照常能发现——否则蹲草会变成"贴脸隐身"。
	if d > CONCEAL_SIGHT and t.has_method("is_concealed") and t.is_concealed():
		return false
	return arena.has_line_of_sight(global_position + Vector3(0, 1.8, 0), t.global_position + Vector3(0, 1.8, 0))


func _update_state(sees: bool, _delta: float) -> void:
	# 在掩体后面看不见玩家是预期内的。这段几秒里如果照常按 sees 判定，
	# 敌人会刚退进掩体就改去守家，再也不会探出来——掩体行为会退化成"逃跑"。
	if _cover_t > 0.0 or _peek_t > 0.0:
		if state != State.ENGAGE:
			state = State.ENGAGE
			_state_t = 0.0
			_repath_t = 0.0
		return
	var hp_ratio := float(hp) / float(max_hp)
	var new_state := state

	if sees:
		var d := global_position.distance_to(target.global_position)
		if hp_ratio < 0.28 and etype != 4 and etype != 2:
			new_state = State.RETREAT
		elif d > _prefer_range * 1.9 and etype != 3:
			new_state = State.SEEK
		elif state != State.FLANK and _state_t > 3.5 and etype != 3 and _roll_flank():
			# 阶段性地绕到侧后方，避免所有敌人正面排队送死
			new_state = State.FLANK
			_flank_side = 1.0 if randf() < 0.5 else -1.0
		elif state == State.FLANK and _state_t > 4.0:
			new_state = State.ENGAGE
		elif state != State.FLANK:
			new_state = State.ENGAGE
	else:
		if state == State.RETREAT and hp_ratio > 0.45:
			new_state = State.SEEK
		elif state != State.RETREAT:
			new_state = State.SEEK

	if new_state != state:
		state = new_state
		_state_t = 0.0
		_repath_t = 0.0
		# 反应延迟必须在**每一次**换状态时都给：原来只有 ENGAGE 给，
		# 于是"先侧绕再开火"和"一看不见就后撤"这两条路径绕过了难度差异——
		# 困难档的敌人在这两种状态下反应速度和简单档一模一样。
		_react_t = [0.75, 0.45, 0.2][difficulty]
		if state == State.FLANK or state == State.RETREAT:
			# 侧绕与后撤本来就比正面交战慢半拍，多给一点时间，读起来才像"在判断"
			_react_t *= 1.5


## 侧绕掷骰。原来这个 35% 是每个 tick 掷一次的，而 tick 是 120 Hz——
## 于是"3.5 秒后开始考虑侧绕"实际是"3.5 秒后必然在下一帧侧绕"，
## 概率参数完全不起作用，全场的敌人会同时包抄。
## 改成每 3.5 秒掷一次，35% 才真的是"大约三次里有一次"。
func _roll_flank() -> bool:
	if _flank_roll_t > 0.0:
		return false
	_flank_roll_t = 3.5
	return randf() < 0.35


func _update_flank_roll(delta: float) -> void:
	_flank_roll_t = maxf(0.0, _flank_roll_t - delta)


# ---------------- 行为 ----------------

func _do_seek(goal: Vector3, delta: float) -> void:
	_follow_path(goal, 1.0, delta)
	# 行进中把炮塔朝向前进方向，遇到挡路的砖墙就轰开
	var ahead := global_position - global_transform.basis.z * 9.0
	aim_at(ahead + Vector3(0, 1.5, 0), delta)
	if target != null and _can_see(target):
		# 看得见就该打：原来这里直接 return，于是"发现玩家但还没进入偏好距离"
		# 的敌人只会一边瞄一边往前走，全程不开火——读起来像在发呆。
		# 炮塔本来就已经指着它了，扣一下扳机没有任何额外成本。
		_aim_and_shoot(delta)
		return
	if _wall_ahead() and can_fire() and randf() < 0.02:
		fire()


func _do_engage(delta: float) -> void:
	if target == null:
		return
	var d := global_position.distance_to(target.global_position)
	var to_t := target.global_position - global_position
	to_t.y = 0.0

	# 探头：装填完成，从掩体后开出来打一发。
	# 走 1.6 秒足够把炮口推出掩体，又不至于一路冲到玩家脸上。
	if _peek_t > 0.0:
		_follow_path(_peek_pos, 0.9, delta)
		_aim_and_shoot(delta)
		return

	# 掩体后：装填期间退到墙后，炮塔仍然指着玩家。
	# 车体先到掩体点站住，剩下的时间只是等装填——这段时间玩家能看到
	# "它躲起来了"，而不是一辆在原地转圈的车。
	if _cover_t > 0.0:
		if reload_t > reload_time * 0.12:
			var to_c := _cover_pos - global_position
			to_c.y = 0.0
			if to_c.length() > 1.3:
				_follow_path(_cover_pos, 0.95, delta)
			else:
				drive(0.0, 0.0, delta)
			aim_at(_predict(target), delta)
			return
		# 装填完成：选一个能重新看见玩家的点，开出去
		_begin_peek(to_t)
		_cover_t = 0.0
		_follow_path(_peek_pos, 0.9, delta)
		_aim_and_shoot(delta)
		return

	# 装填过程的前半段（剩余最多时）退到掩体后：刚开完炮就往回缩正是
	# "一炮一缩"的时机，而等到只剩最后一点装填时间再退，地图上只会看到
	# 一辆车在墙边来回蹭。侦察车与火炮车不参与——前者靠机动、后者靠射程，
	# 退到墙后反而失去意义。搜索带冷却，见 _cover_search_cd。
	if reload_t > reload_time * 0.45 and etype != 0 and etype != 3 \
			and _cover_search_cd <= 0.0:
		var cover := _find_cover()
		_cover_search_cd = 0.75
		if cover != Vector3.INF:
			_cover_pos = cover
			_cover_t = reload_time + 1.0
			return

	# 重型与 Boss 在装填期间斜摆车身：正面装甲以约 30° 迎敌，炮塔独立瞄准。
	# 于是"等装填"这段时间也在做防御动作，而不是站着挨打。
	if (etype == 2 or etype == 4) and reload_t > 0.0 and d < _prefer_range * 1.7:
		var want := atan2(-to_t.x, -to_t.z) + deg_to_rad(30.0) * _flank_side
		drive(0.0, _steer_yaw(want) * 0.8, delta)
		_aim_and_shoot(delta)
		return

	# 保持在偏好交战距离上：太近后退，太远前压
	var throttle := 0.0
	if d > _prefer_range * 1.25:
		throttle = 0.8
	elif d < _prefer_range * 0.65:
		throttle = -0.7
	var steer := _steer_toward(target.global_position)
	drive(throttle, steer * 0.6, delta)
	_aim_and_shoot(delta)


## 在自身周围找一个"能挡住玩家视线"的格子。
##
## 判据有三条，缺一不可：
##   * 候选点本身可通行（不然退不过去）；
##   * 从候选点到玩家没有视线（这才是掩体，而不是"离墙近"）；
##   * 挡视线的必须是砖墙——水面不挡视线，残骸也不该被当成战术掩体。
##
## 只在装填中途调用（每 2~4 秒一次），几十次网格步进的成本可以忽略。
func _find_cover() -> Vector3:
	if target == null:
		return Vector3.INF
	var c := Arena.to_cell(global_position)
	var eye := Vector3(0, 1.8, 0)
	var best := Vector3.INF
	var best_d := 1e9
	for dy in range(-COVER_SEARCH_CELLS, COVER_SEARCH_CELLS + 1):
		for dx in range(-COVER_SEARCH_CELLS, COVER_SEARCH_CELLS + 1):
			if dx == 0 and dy == 0:
				continue
			if absi(dx) + absi(dy) > COVER_SEARCH_CELLS + 1:
				continue
			var n := Vector2i(c.x + dx, c.y + dy)
			if arena.blocks_tank(n.x, n.y):
				continue
			var p := Arena.cell_center(n.x, n.y)
			var dist := p.distance_to(global_position)
			if dist > COVER_MAX_DIST or dist < 2.0:
				continue
			if arena.has_line_of_sight(p + eye, target.global_position + eye):
				continue
			# 玩家方向上紧邻的格子必须是砖墙：水和残骸不算掩体
			var dir := target.global_position - p
			dir.y = 0.0
			var probe := Arena.to_cell(p + dir.normalized() * Arena.CELL * 1.1)
			if arena.cell(probe.x, probe.y) != Arena.BRICK:
				continue
			if dist < best_d:
				best_d = dist
				best = p
	return best


## 从掩体后开出来的落点：沿玩家方向依次试 4/6/8 m，取第一个能看见玩家的。
## 都看不见（比如掩体是一整排墙）就退而求其次，沿同方向开出去再说——
## 至少不会停在原地等玩家绕过来。
func _begin_peek(to_target: Vector3) -> void:
	var dir := to_target.normalized()
	var eye := Vector3(0, 1.8, 0)
	var best := Vector3.INF
	for dist in [4.0, 6.0, 8.0]:
		var p := arena.snap_open(_cover_pos + dir * dist)
		if arena.has_line_of_sight(p + eye, target.global_position + eye):
			best = p
			break
	if best == Vector3.INF:
		best = arena.snap_open(global_position + dir * 5.0)
	_peek_pos = best
	_peek_t = 1.6
	_cover_pos = Vector3.INF


## 转向一个世界朝向。与 _steer_toward() 的区别是它不经过"目标点"，
## 用于斜摆车身这类"只关心车头指哪"的动作。
func _steer_yaw(want_yaw: float) -> float:
	return clampf(wrapf(want_yaw - rotation.y, -PI, PI) * 1.6, -1.0, 1.0)


func _do_flank(goal: Vector3, delta: float) -> void:
	if target == null:
		_do_seek(goal, delta)
		return
	# 绕着目标做圆周机动，争取打到对方侧后装甲
	var to_me := global_position - target.global_position
	to_me.y = 0.0
	var radius := _prefer_range
	var tangent := Vector3(-to_me.z, 0, to_me.x).normalized() * _flank_side
	# 目标点可能落在墙里或水里：侧绕的圆轨道不管地形。
	# 先贴到最近的可通行格，至少"朝这个方向开"是可行的。
	var want := arena.snap_open(
			target.global_position + to_me.normalized() * radius + tangent * 10.0)
	drive(0.85, _steer_toward(want) * 0.8, delta)
	_aim_and_shoot(delta)


func _do_retreat(delta: float) -> void:
	if target == null:
		drive(0.0, 0.0, delta)
		return
	var away := arena.snap_open(
			global_position + (global_position - target.global_position).normalized() * 18.0)
	drive(0.9, _steer_toward(away) * 0.9, delta)
	_aim_and_shoot(delta)


func _aim_and_shoot(delta: float) -> void:
	if target == null:
		return
	var aim := _predict(target)
	var locked := aim_at(aim, delta)
	if not locked or _react_t > 0.0 or not can_fire():
		return
	if not arena.has_line_of_sight(muzzle_pos(), target.global_position + Vector3(0, 1.6, 0)):
		return
	fire()


## 提前量预瞄：按炮弹飞行时间预测目标位置，再叠加难度决定的瞄准误差。
## 抛物线的抬升量不在这里补——HE 的弹道由 fire() 解算，
## 所以 AI 和玩家一样"瞄哪打哪"，两边的命中率受同一套规则约束。
func _predict(t: Tank) -> Vector3:
	var to := t.global_position - global_position
	var spd := Shell.HE_SPEED if shell_kind == Shell.Kind.HE else Shell.AP_SPEED
	var flight := to.length() / spd
	var lead: Vector3 = t.velocity * flight * [0.35, 0.75, 1.0][difficulty]
	var p: Vector3 = t.global_position + lead + _aim_err
	return p + Vector3(0, 1.5, 0)


# ---------------- 移动辅助 ----------------

func _follow_path(goal: Vector3, speed_scale: float, delta: float) -> void:
	if _repath_t <= 0.0:
		_path = arena.find_path(global_position, goal, _too_wide_for_lanes())
		_repath_t = randf_range(0.5, 0.9)

	while _path.size() > 0 and global_position.distance_to(_path[0]) < Arena.CELL * 0.7:
		_path.remove_at(0)

	if _path.is_empty():
		drive(0.0, _steer_toward(goal) * 0.8, delta)
		return

	var wp: Vector3 = _path[0]
	var steer := _steer_toward(wp)
	# 转弯太急时减速，避免绕圈
	var throttle: float = (1.0 - clampf(absf(steer) - 0.35, 0.0, 1.0) * 0.65) * speed_scale
	if _unstuck_t > 0.0:
		drive(-0.8, _flank_side, delta)
		return
	drive(throttle, steer, delta)


func _steer_toward(p: Vector3) -> float:
	var local := to_local(p)
	var want := atan2(local.x, -local.z)
	return clampf(want * 1.6, -1.0, 1.0)


## 车体比一格还宽的车（Boss 4.70 m，一格 4.0 m）不能走单格通道。
##
## 窄通道里它的车身会左右各压进砖墙 0.345 m——玩家看到的就是"坦克穿墙"
## （tools/_BossCorridorProbe.tscn）。这类车改走 Arena 的宽体网格，于是它会
## 绕远路；只有在宽网格上确实无路可走时才退回普通网格。
func _too_wide_for_lanes() -> bool:
	return _hull_half_w * 2.0 > Arena.CELL - 0.1


func _wall_ahead() -> bool:
	var probe := global_position - global_transform.basis.z * (body_length * 0.5 + 2.0)
	var c := Arena.to_cell(probe)
	return arena.cell(c.x, c.y) == Arena.BRICK


func _check_stuck(delta: float) -> void:
	if global_position.distance_to(_last_pos) < 0.35:
		_stuck_t += delta
	else:
		_stuck_t = 0.0
		_last_pos = global_position
	if _stuck_t > 1.1:
		_stuck_t = 0.0
		_unstuck_t = 0.7
		_flank_side = -_flank_side
		_repath_t = 0.0
		_last_pos = global_position
