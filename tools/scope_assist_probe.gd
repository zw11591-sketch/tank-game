extends Node
## 验收：狙击镜的两项"射击辅助"。
##
## 1. 镜内炮塔跟瞄：同样的瞄准阶跃输入下，举镜时的炮塔残差必须明显小于不举镜
##    （SCOPE_TURRET_BOOST = 1.6）。测残差而不是测角速度：角速度是常量，
##    残差才是玩家真正感受到的"准星压上去了没有"。
## 2. 提前量标尺的拦截解：`Shell.intercept_time()` 解出来的飞行时间必须让
##    目标在那一刻正好落在弹道上；再拿这个点当准星开一炮，移动目标应当被命中。
##    这一条是"远程打击能力"的直接判据——标尺算错，炮就必然打空。
##
## 走廊（lane）：探针先在出生点周围找一条最长且两侧有余量的直线，再在这条线上
## 挑三个距离。找不到 20 m 以上就算 SKIP 并打印，不把环境问题算成功能失败。
##
## 用法：godot.exe --headless --path . res://tools/ScopeAssistProbe.tscn

const TARGET_SPEED := 12.0
const DUMMY_HP := 1000000
## 炮塔阶跃的瞄准偏移与观察帧数。60° / 10 帧在 5.4 rad/s 下刚好走不到一半，
## 于是"快 1.6 倍"会直接体现在残差上，不会被"已经转到位"抹平。
const CHASE_OFFSET := deg_to_rad(60.0)
const CHASE_FRAMES := 10
## 与 HUD 标尺一致的目标瞄准高度（车体命中圆柱中心）
const HUD_LEAD_Y := 1.05
## 三个测试距离的上限；实际会按找到的走廊长度等比收缩。
const LEAD_MAX_DIST := 40.0
const LEAD_MIN_DIST := 12.0

var _main: Node
var _p0 := Vector3.ZERO
var _lane_yaw := 0.0
var _lane_len := 0.0


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 0
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	# 排队一个敌人，避免 _update_play() 第一帧就判肃清切到 "clear"
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 10:
		await get_tree().physics_frame

	var p: Player = _main.player
	var rig: CameraRig = _main.rig
	_p0 = p.global_position
	var lane := _open_lane(p, _main.arena)
	_lane_yaw = float(lane["yaw"])
	_lane_len = float(lane["dist"])
	print("== scope assist probe  tank=%s  lane=%.0fm @ %.1fdeg"
			% [p.tank_id, _lane_len, rad_to_deg(_lane_yaw)])

	var fails := 0
	fails += _check_math()
	fails += await _check_chase(p, rig)
	fails += await _check_lead_shots(p, rig)
	print("VERDICT fail=%d %s" % [fails, "OK" if fails == 0 else "FAIL"])
	get_tree().quit(0 if fails == 0 else 1)


## 拦截解：|目标当前位置 + v·t − 炮口| 必须等于 弹速·t。
func _check_math() -> int:
	var from := Vector3.ZERO
	var to := Vector3(100.0, 0.0, 0.0)
	var vel := Vector3(0.0, 0.0, 12.0)
	var t := Shell.intercept_time(from, to, vel, Shell.AP_SPEED)
	var pt: Vector3 = to + vel * t
	var residual: float = absf(from.distance_to(pt) - Shell.AP_SPEED * t)
	var expect := 100.0 / sqrt(Shell.AP_SPEED * Shell.AP_SPEED - 12.0 * 12.0)
	var ok_t: bool = absf(t - expect) < 1e-4
	var ok_r: bool = residual < 0.01
	var ts := Shell.intercept_time(from, to, Vector3.ZERO, Shell.AP_SPEED)
	var ok_static: bool = absf(ts - 100.0 / Shell.AP_SPEED) < 1e-4
	print("  math  t=%.4fs (expect %.4f)  lead=%.2fm  residual=%.4fm  static=%.4fs  %s"
			% [t, expect, (pt - to).length(), residual, ts,
			"OK" if ok_t and ok_r and ok_static else "FAIL"])
	return 0 if ok_t and ok_r and ok_static else 1


## 炮塔阶跃残差：不举镜 vs 举镜。
##
## 探针把 turret_snap 临时归零：名册里的"误差越大转得越快"会让两种状态都很快
## 转到位，把 1.6 倍差抹平；要测的是倍率本身，所以只留恒速那一档。
func _check_chase(p: Player, rig: CameraRig) -> int:
	var snap := p.turret_snap
	p.turret_snap = 0.0
	var hip := await _chase_residual(p, rig, false)
	var scope := await _chase_residual(p, rig, true)
	p.turret_snap = snap
	Input.action_release("aim_scope")
	await get_tree().physics_frame
	var ok: bool = scope < hip * 0.8
	print("  chase hip=%.1fdeg  scope=%.1fdeg  ratio=%.2f  %s"
			% [rad_to_deg(hip), rad_to_deg(scope), scope / maxf(hip, 0.001),
			"OK" if ok else "FAIL"])
	return 0 if ok else 1


func _chase_residual(p: Player, rig: CameraRig, scoped: bool) -> float:
	# 输入通道：player.tick() 每帧都会用 is_action_pressed("aim_scope") 覆盖状态，
	# 所以必须从动作层按下去，直接写 rig.sniper 会被下一帧刷回去。
	if scoped:
		Input.action_press("aim_scope")
	else:
		Input.action_release("aim_scope")
	p.global_position = _p0
	p.rotation.y = _lane_yaw
	p.turret.rotation.y = 0.0
	rig.aim_pitch = 0.0
	rig.aim_yaw = _lane_yaw
	await get_tree().physics_frame
	rig.aim_yaw = wrapf(_lane_yaw + CHASE_OFFSET, -PI, PI)
	for _i in CHASE_FRAMES:
		await get_tree().physics_frame
	var want := wrapf(rig.aim_yaw - p.rotation.y, -PI, PI)
	return absf(angle_difference(p.turret.rotation.y, want))


func _check_lead_shots(p: Player, rig: CameraRig) -> int:
	var maxd: float = minf(_lane_len - 4.0, LEAD_MAX_DIST)
	if maxd < LEAD_MIN_DIST:
		print("  lead  SKIP: lane %.0fm too short (need %.0fm)" % [_lane_len, LEAD_MIN_DIST])
		return 0
	var dists := [maxd * 0.5, maxd * 0.75, maxd]
	var fails := 0
	for d in dists:
		fails += await _shot_row(p, rig, float(d))
	return fails


## 一辆匀速横穿的敌车：按拦截点开一炮，必须命中。
##
## 目标位置由探针逐帧写入（关掉它的物理与 AI），所以"它会在飞行时间里走到哪"
## 是已知量，拦截解对不对可以单独判。
func _shot_row(p: Player, rig: CameraRig, d: float) -> int:
	var fwd := Vector3(-sin(_lane_yaw), 0.0, -cos(_lane_yaw))
	var side := Vector3(cos(_lane_yaw), 0.0, -sin(_lane_yaw))
	var ctr: Vector3 = _p0 + fwd * d

	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.team = 1
	e.hp = DUMMY_HP
	e.set_physics_process(false)
	await get_tree().physics_frame

	var vel := side * TARGET_SPEED
	p.global_position = _p0
	p.rotation.y = _lane_yaw
	p.turret.rotation.y = 0.0
	p.reload_t = 0.0
	# 先把敌车摆到起始格上再等一帧：关掉物理之后它不会自己落地，
	# 否则"命中"与"从车顶飞过"读不出区别。
	e.global_position = ctr
	for _i in 2:
		await get_tree().physics_frame

	# 弹道只取决于炮塔与俯仰，与车体朝向无关
	var from: Vector3 = p.muzzle_pos()
	var tgt: Vector3 = ctr + Vector3(0, HUD_LEAD_Y, 0)
	var flight := Shell.intercept_time(from, tgt, vel, Shell.AP_SPEED)

	# 玩家做的事：把准星压到标尺上（瞄准角指向拦截点），然后扣扳机。
	var aim_pt: Vector3 = tgt + vel * flight
	var dir := (aim_pt - from).normalized()
	var want_yaw := atan2(-dir.x, -dir.z)
	var want_pitch := atan2(dir.y, Vector2(dir.x, dir.z).length())
	p.aim_at_angles(want_yaw, want_pitch, 1.0)
	p.aim_point = aim_pt
	var fired := p.fire()
	if not fired:
		print("  lead d=%.0fm  fire()=false  FAIL" % d)
		return 1

	var elapsed := 0.0
	var guard := 0
	var min_d := 1.0e9
	while guard < 240:
		guard += 1
		await get_tree().physics_frame
		elapsed += 1.0 / 120.0
		e.global_position = ctr + vel * elapsed
		for c in _main.get_children():
			if c is Shell:
				min_d = minf(min_d, c.global_position.distance_to(e.global_position + Vector3(0, 1.0, 0)))
		if e.hp < DUMMY_HP:
			break
		if elapsed > flight + 0.6 and _shells() == 0:
			break

	var hit: bool = e.hp < DUMMY_HP
	print("  lead d=%.0fm (%0.1f%% lane)  flight=%.3fs  lead=%.2fm  minDist=%.2f  %s"
			% [d, d / maxf(_lane_len, 1.0) * 100.0, flight, (aim_pt - tgt).length(),
			min_d, "HIT" if hit else "MISS"])
	e.alive = false
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
	return 0 if hit else 1


func _shells() -> int:
	var n := 0
	for c in _main.get_children():
		if c is Shell:
			n += 1
	return n


## 找一条最长的直线走廊（1 m 步进扫 96 m）。
##
## 中心线必须逐步扫，不能只抽几个距离：夹在中间的某一格墙会让炮弹半路撞上去，
## 而探针会把它误读成"拦截点算错了"（实测 25 / 40 m 两行就是这么假 MISS 的）。
func _open_lane(p: Player, arena: Arena) -> Dictionary:
	var best := {"yaw": 0.0, "dist": 0.0}
	for step in 288:
		var yaw := deg_to_rad(float(step) * 1.25)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var clear := 0.0
		for i in range(4, 96):
			var pos: Vector3 = p.global_position + dir * float(i)
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
				break
			if arena.blocks_tank(c.x, c.y):
				break
			clear = float(i)
		if clear > float(best["dist"]):
			best = {"yaw": yaw, "dist": clear}
	return best
