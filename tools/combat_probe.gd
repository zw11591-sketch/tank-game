extends Node
## 验收：穿墙与叠车。两件事都是"概率性发生"的故障，光靠手玩几局证明不了修没修好，
## 所以这里让所有地形各跑一轮，把每物理帧的几何状态摊开统计。
##
## 两条判据：
##   1. 穿墙 —— 任何坦克的车体圆与实心格矩形的重叠深度。depenetrate() 是硬约束，
##      所以稳态下这个值必须接近 0；超过 TOL_PEN 就说明约束被突破了。
##   2. 卡死 —— 两辆车处于接触状态、且双方单帧位移同时低于 FROZEN_STEP 的连续时长。
##      这里刻意不用"接触时长"当判据：并排挤着走也会长时间接触，那是正常的碰撞响应，
##      真正的故障是"顶在一起谁也动不了"，所以必须单独度量双方同时静止的那段时间。
##
## 还有一条元判据：判据活性。穿墙与卡死都是概率性故障，如果探针压根没撞到墙、
## 没叠到车，那么"没有发生故障"只是因为没测到，所以 wallFrames / pairFrames /
## distance 三个计数必须同时达标，VERDICT 里的 testValid 才会是 true。
##
## 另外顺手数一下场地补给的生成数量，确认"时不时能见到道具"真的在发生。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

## 判定为真实穿透的重叠深度（米）。留一点余量给单帧的数值抖动
const TOL_PEN := 0.15
## 车体圆到实心格的间隙小于这个值就算"贴上墙了"（米）。
## move_and_slide 有 6cm 的 safe_margin，所以紧贴着墙时间隙是正的而不是 0，
## 判据活性必须用间隙来数，不能用重叠量——那样永远数不到。
const TOL_TOUCH := 0.14
## 一对坦克处于接触状态的时长。只做观测，不作判据——
## 并排挤着走也会长时间接触，那是正常的碰撞响应
const STUCK_OBSERVE := true
## 两车中心距小于半径和的这个倍数即视为接触。
## 与 main.gd 的分离判据（want = 半径和 * 1.02）取同一个数，
## 于是这里数到的每一帧都是互推逻辑真的在工作的那一帧。
const CONTACT_K := 1.02
## 单帧位移低于这个值（米）就算这辆车没在动。120Hz 下约等于 0.6 m/s
const FROZEN_STEP := 0.005
## 接触中的两车同时不动，持续超过这个时长就是真卡死（秒）。
## 互推 + 切向滑移的设计目标是"半秒内必然解开"，所以这里按 0.6 秒收线。
## 注意这与"接触时长"是两件事：并排行驶也会长时间接触，但那不是故障。
const DEADLOCK_FAIL := 0.6
## 每个地形跑多少物理帧（120Hz）。20 秒足够走完"倒计时 → 敌人成批进场 →
## 场地补给至少刷两轮"，再短就测不到任何有效工况
const FRAMES_PER_TERRAIN := 2400
## 多久换一次驾驶输入：短到让车一直在换撞击角度，又长到车真的能跑起来
const INPUT_PERIOD := 70

var _f := 0
var _terrain := 0
var _started := false

# ---- 统计 ----
var _worst_pen := 0.0
var _pen_frames := 0
var _worst_pen_terrain := -1
var _contact: Dictionary = {}
var _worst_stuck := 0.0
var _worst_stuck_terrain := -1
## 卡死时长（接触且两车都不动）。这才是"叠在一起动不了"的直接度量
var _worst_frozen := 0.0
var _worst_frozen_terrain := -1
var _prev_pos: Dictionary = {}
var _powerups_seen := 0
var _seen_ids: Dictionary = {}
var _rows: Array = []
# 当前地形的局部统计
var _t_pen := 0.0
var _t_stuck := 0.0
var _t_frozen := 0.0
var _t_drops := 0
## 不设阈值的最大重叠深度。它用来证明判据是活的：如果一直是 0.000，
## 说明探针根本没碰到墙，"没有穿墙"这个结论也就毫无意义。
var _t_pen_raw := 0.0
## 真正贴上墙 / 贴上另一辆车的帧数，同样是判据活性的证据
var _t_wall_frames := 0
var _t_pair_frames := 0
var _t_enemy_peak := 0
## 玩家车行驶里程：确认探针的按键确实驱动了车，而不是在原地不动
var _t_dist := 0.0
var _last_pos := Vector3.INF
# 跨地形累计，用于判据活性
var _all_wall_frames := 0
var _all_pair_frames := 0
var _all_dist := 0.0


## 本探针挂在 tools/CombatProbe.tscn 上，主场景作为子节点 Main 一起实例化，
## 于是自动加载（Settings / Audio）与完整的游戏流程都在。
func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	Settings.drive_relative = true
	_begin_terrain(0)


func _begin_terrain(i: int) -> void:
	_terrain = i
	_t_pen = 0.0
	_t_stuck = 0.0
	_t_frozen = 0.0
	_t_drops = 0
	_t_pen_raw = 0.0
	_t_wall_frames = 0
	_t_pair_frames = 0
	_t_enemy_peak = 0
	_t_dist = 0.0
	_last_pos = Vector3.INF
	_contact.clear()
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 2          # 第 3 关：敌人够多，掩体密度也上来了
	main._sel_terrain = i
	main._confirm_start()
	_started = true


func _physics_process(delta: float) -> void:
	if not _started:
		return
	var main := _main()
	if main == null or main.arena == null:
		return

	_f += 1
	_drive_randomly(main)
	_check_penetration(main)
	_check_overlap(main, delta)
	_count_drops(main)
	_t_enemy_peak = maxi(_t_enemy_peak, main._count_active())
	var p = main.player
	if p != null and is_instance_valid(p) and p.alive:
		if _last_pos.x < INF:
			# 重生会让坐标瞬移，跳变超过 5 米的那一帧不计入里程
			var d: float = p.global_position.distance_to(_last_pos)
			if d < 5.0:
				_t_dist += d
		_last_pos = p.global_position
	else:
		_last_pos = Vector3.INF

	if _f >= FRAMES_PER_TERRAIN:
		_flush(main)
		_f = 0
		if _terrain + 1 < Arena.TERRAINS.size():
			_begin_terrain(_terrain + 1)
		else:
			_summary()
			get_tree().quit(0)


## 换算成 ASCII 的地形标签：中文名过管道会乱码，所以只打 layout
func _layout(i: int) -> String:
	return str(Arena.TERRAINS[i]["layout"])


func _flush(_main) -> void:
	_all_wall_frames += _t_wall_frames
	_all_pair_frames += _t_pair_frames
	_all_dist += _t_dist
	_rows.append(("PROBE %-9s maxPen%6.3fm wallF%5d "
			+ "contact%5.2fs frozen%5.2fs pairF%5d drops%3d peakEnemy%3d m%6.0f") % [
		_layout(_terrain), _t_pen_raw, _t_wall_frames,
		_t_stuck, _t_frozen, _t_pair_frames, _t_drops, _t_enemy_peak, _t_dist,
	])
	print(_rows[_rows.size() - 1])


# ---------------- 输入：持续撞墙、撞敌人 ----------------

## 刻意把车往掩体和敌人身上开：穿墙与叠车都只在"被挤压"时才暴露，
## 老老实实在空地上转圈是测不出来的。
func _drive_randomly(main) -> void:
	# 探针车刀枪不入：这是一个几何测试，玩家一死就不再撞墙撞车，
	# 后面的帧全是空跑，统计量会被稀释成"看起来很干净"
	var p = main.player
	if p != null and is_instance_valid(p) and p.alive:
		p.hp = p.max_hp
	if _f % INPUT_PERIOD != 0:
		return
	for n in ["move_forward", "move_back", "turn_left", "turn_right"]:
		Input.action_release(n)
	# 大部分时间满油门前进（撞墙），偶尔倒车，并随机改镜头朝向换个撞击角度
	Input.action_press("move_forward" if randf() < 0.8 else "move_back")
	if randf() < 0.5:
		Input.action_press("turn_left" if randf() < 0.5 else "turn_right")
	if main.rig != null:
		main.rig.yaw = randf_range(-PI, PI)
	# 往最近的敌人身上开：正面对顶是叠车最容易卡住的姿态
	if p == null or not is_instance_valid(p) or not p.alive:
		return
	if main.enemies.size() > 0:
		var best = null
		var bd := INF
		for e in main.enemies:
			if not is_instance_valid(e) or not e.alive:
				continue
			var d: float = e.global_position.distance_to(p.global_position)
			if d < bd:
				bd = d
				best = e
		if best != null and bd < 40.0 and main.rig != null:
			var v: Vector3 = best.global_position - p.global_position
			main.rig.yaw = atan2(-v.x, -v.z)


# ---------------- 判据 1：穿墙 ----------------

## 车体圆与九宫格内每个实心格矩形的重叠深度，取最大值。
## 与 Arena.depenetrate() 用的是同一套圆-矩形距离，所以这里量的就是约束的残差。
func _check_penetration(main) -> void:
	var a: Arena = main.arena
	var half := Arena.CELL * 0.5
	for t in main.all_tanks():
		if not is_instance_valid(t):
			continue
		var pos: Vector3 = t.global_position
		var radius: float = t.body_radius - 0.02
		var c0 := Arena.to_cell(pos)
		var worst := 0.0
		var gap := INF
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cx: int = c0.x + dx
				var cy: int = c0.y + dy
				if not a.blocks_tank(cx, cy):
					continue
				var center := Arena.cell_center(cx, cy)
				var nx := clampf(pos.x, center.x - half, center.x + half)
				var nz := clampf(pos.z, center.z - half, center.z + half)
				var dist := Vector2(pos.x - nx, pos.z - nz).length()
				worst = maxf(worst, radius - dist)
				gap = minf(gap, dist - radius)
		if gap < TOL_TOUCH:
			_t_wall_frames += 1
		_t_pen_raw = maxf(_t_pen_raw, worst)
		if worst <= TOL_PEN:
			continue
		_pen_frames += 1
		_t_pen = maxf(_t_pen, worst)
		if worst > _worst_pen:
			_worst_pen = worst
			_worst_pen_terrain = _terrain


# ---------------- 判据 2：叠车 ----------------

## 每一对接触坦克的持续时长，以及其中"两辆车都不动"的持续时长。
##
## 这两个量必须分开看：并排挤着走、贴着对方绕过去，都会长时间处于接触状态，
## 那是正常的碰撞响应。真正的故障是"顶在一起谁也动不了"，
## 所以判据取后者——接触期间两车单帧位移同时低于 FROZEN_STEP 的连续时长。
func _check_overlap(main, delta: float) -> void:
	var list: Array = main.all_tanks()
	var live: Dictionary = {}
	var pos_now: Dictionary = {}
	for t in list:
		if is_instance_valid(t):
			pos_now[t.get_instance_id()] = t.global_position
	for i in list.size():
		for j in range(i + 1, list.size()):
			var a = list[i]
			var b = list[j]
			if not is_instance_valid(a) or not is_instance_valid(b):
				continue
			var d: Vector3 = b.global_position - a.global_position
			d.y = 0.0
			var want: float = (a.body_radius + b.body_radius) * CONTACT_K
			if d.length() >= want:
				continue
			var ida: int = a.get_instance_id()
			var idb: int = b.get_instance_id()
			var key := "%d:%d" % [ida, idb]
			var prev: Array = _contact.get(key, [0.0, 0.0])
			var held: float = float(prev[0]) + delta
			var frozen: float = float(prev[1])
			# 两辆车这一帧都几乎没动：互推没能把它们分开，开始累计卡死时长
			var ma: float = _moved(ida, pos_now)
			var mb: float = _moved(idb, pos_now)
			if ma < FROZEN_STEP and mb < FROZEN_STEP:
				frozen += delta
			else:
				frozen = 0.0
			live[key] = [held, frozen]
			_t_pair_frames += 1
			_t_stuck = maxf(_t_stuck, held)
			_t_frozen = maxf(_t_frozen, frozen)
			if frozen > _worst_frozen:
				_worst_frozen = frozen
				_worst_frozen_terrain = _terrain
			if held > _worst_stuck:
				_worst_stuck = held
				_worst_stuck_terrain = _terrain
	_contact = live
	_prev_pos = pos_now


## 这一帧走了多远。上一帧没有记录（刚生成）时按"在动"处理，不误报卡死。
func _moved(id: int, pos_now: Dictionary) -> float:
	if not _prev_pos.has(id):
		return INF
	return (Vector3(pos_now[id]) - Vector3(_prev_pos[id])).length()


# ---------------- 场地补给 ----------------

func _count_drops(main) -> void:
	for pu in main.powerups:
		if not is_instance_valid(pu):
			continue
		var id: int = pu.get_instance_id()
		if _seen_ids.has(id):
			continue
		_seen_ids[id] = true
		_powerups_seen += 1
		if pu.from_field:
			_t_drops += 1


# ---------------- 结论 ----------------

func _summary() -> void:
	print("PROBE ---- summary ----")
	print("PROBE terrains=%d framesEach=%d" % [Arena.TERRAINS.size(), FRAMES_PER_TERRAIN])
	print("PROBE penetration worst=%.3fm frames=%d tol=%.2fm at=%s" % [
		_worst_pen, _pen_frames, TOL_PEN,
		"none" if _worst_pen_terrain < 0 else _layout(_worst_pen_terrain),
	])
	print("PROBE overlap worstContact=%.2fs at=%s" % [
		_worst_stuck,
		"none" if _worst_stuck_terrain < 0 else _layout(_worst_stuck_terrain),
	])
	print("PROBE deadlock worstFrozen=%.2fs fail=%.2fs at=%s" % [
		_worst_frozen, DEADLOCK_FAIL,
		"none" if _worst_frozen_terrain < 0 else _layout(_worst_frozen_terrain),
	])
	print("PROBE powerupsTotal=%d" % _powerups_seen)
	var ok_pen: bool = _worst_pen <= TOL_PEN
	var ok_stuck: bool = _worst_frozen < DEADLOCK_FAIL
	# 判据活性：真的撞到过墙、真的叠过车、车真的开了，这三件事都成立，
	# 上面两个"没有发生故障"的结论才有意义
	var live_ok: bool = _all_wall_frames > 1000 and _all_pair_frames > 200 and _all_dist > 200.0
	print("PROBE liveness wallFrames=%d pairFrames=%d distance=%.0fm live=%s" % [
		_all_wall_frames, _all_pair_frames, _all_dist, str(live_ok),
	])
	print("PROBE VERDICT noClip=%s noDeadlock=%s testValid=%s" % [
		str(ok_pen), str(ok_stuck), str(live_ok),
	])
