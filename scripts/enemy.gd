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


# ---------------- 主循环 ----------------

func tick(delta: float) -> void:
	if not alive:
		return
	if game.state != "play":
		drive(0.0, 0.0, delta)
		return

	_state_t += delta
	_repath_t -= delta
	_aim_err_t -= delta
	_react_t = maxf(0.0, _react_t - delta)
	_unstuck_t = maxf(0.0, _unstuck_t - delta)

	target = _pick_target()
	var goal := _goal_position()
	var sees := target != null and _can_see(target)

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
	return arena.has_line_of_sight(global_position + Vector3(0, 1.8, 0), t.global_position + Vector3(0, 1.8, 0))


func _update_state(sees: bool, _delta: float) -> void:
	var hp_ratio := float(hp) / float(max_hp)
	var new_state := state

	if sees:
		var d := global_position.distance_to(target.global_position)
		if hp_ratio < 0.28 and etype != 4 and etype != 2:
			new_state = State.RETREAT
		elif d > _prefer_range * 1.9 and etype != 3:
			new_state = State.SEEK
		elif state != State.FLANK and _state_t > 3.5 and etype != 3 and randf() < 0.35:
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
		if state == State.ENGAGE:
			_react_t = [0.75, 0.45, 0.2][difficulty]


# ---------------- 行为 ----------------

func _do_seek(goal: Vector3, delta: float) -> void:
	_follow_path(goal, 1.0, delta)
	# 行进中把炮塔朝向前进方向，遇到挡路的砖墙就轰开
	var ahead := global_position - global_transform.basis.z * 9.0
	aim_at(ahead + Vector3(0, 1.5, 0), delta)
	if target != null and _can_see(target):
		return
	if _wall_ahead() and can_fire() and randf() < 0.02:
		fire()


func _do_engage(delta: float) -> void:
	if target == null:
		return
	var d := global_position.distance_to(target.global_position)
	# 保持在偏好交战距离上：太近后退，太远前压
	var throttle := 0.0
	if d > _prefer_range * 1.25:
		throttle = 0.8
	elif d < _prefer_range * 0.65:
		throttle = -0.7
	var steer := _steer_toward(target.global_position)
	drive(throttle, steer * 0.6, delta)
	_aim_and_shoot(delta)


func _do_flank(goal: Vector3, delta: float) -> void:
	if target == null:
		_do_seek(goal, delta)
		return
	# 绕着目标做圆周机动，争取打到对方侧后装甲
	var to_me := global_position - target.global_position
	to_me.y = 0.0
	var radius := _prefer_range
	var tangent := Vector3(-to_me.z, 0, to_me.x).normalized() * _flank_side
	var want := target.global_position + to_me.normalized() * radius + tangent * 10.0
	drive(0.85, _steer_toward(want) * 0.8, delta)
	_aim_and_shoot(delta)


func _do_retreat(delta: float) -> void:
	if target == null:
		drive(0.0, 0.0, delta)
		return
	var away := global_position + (global_position - target.global_position).normalized() * 18.0
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
