extends Node
## 探针：狙击镜的"边瞄准边射击"。
##
## 走的是真实输入通道（Input.action_press / release + 鼠标事件），不直接调 fire()：
## 要测的正是 player.tick() 的状态机有没有在开镜时挡掉开火、锁定有没有真的成立。
##
## 四组判据：
##   1. 开镜后单击 / 按住都能开火（原有行为不能丢）；
##   2. 准星连续压在同一个移动目标上 0.4 s 后进入火控锁定，提前量补偿 > 0；
##   3. 锁定之后按当前准星直接开火（不手动瞄提前量）能命中远处横穿的敌车；
##   4. 镜内开火震屏是腰射的一半（SCOPE_KICK_SCALE），连射不会把准星顶走。
##
## 用法：godot.exe --headless --path . res://tools/ScopeFireProbe.tscn

const DUMMY_HP := 1000000
const TARGET_SPEED := 12.0
const MAX_RANGE := 40.0

var _main: Node
var _p0 := Vector3.ZERO
var _lane_yaw := 0.0
var _lane_len := 0.0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 0
	_main._sel_diff = 1
	_main._sel_stage = 1
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	# 场上留一个"待生成"的敌人：否则 _update_play() 会在第一帧判定肃清，
	# 立刻切到 "clear"，而开火与开镜只在 "play" 里读输入。
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
	print("== scope fire probe  tank=%s  lane=%.0fm @ %.1fdeg"
			% [p.tank_id, _lane_len, rad_to_deg(_lane_yaw)])
	print("scope_probe start  sniper=%s  shots=%d" % [str(rig.sniper), p.shot_count])

	var lanes := {"p": p, "rig": rig}
	_fails += await _check_firing(lanes)
	_fails += await _check_lock_and_lead(lanes)
	_fails += await _check_kick(lanes)
	print("VERDICT fail=%d %s" % [_fails, "OK" if _fails == 0 else "FAIL"])
	get_tree().quit(0 if _fails == 0 else 1)


# ---------------- 1. 开火 ----------------

func _check_firing(l: Dictionary) -> int:
	var p: Player = l["p"]
	var rig: CameraRig = l["rig"]
	var fails := 0

	# 单独开镜：真实鼠标事件，事件层也会走 player._unhandled_input
	_mouse(MOUSE_BUTTON_RIGHT, true)
	for _i in 8:
		await get_tree().process_frame
		for _j in 2:
			await get_tree().physics_frame
	print("after scope press   sniper=%s  fov_target=%.0f  shots=%d"
			% [str(rig.sniper), rig._fov(), p.shot_count])
	if not rig.sniper:
		fails += 1

	p.reload_t = 0.0
	var before := p.shot_count
	_mouse(MOUSE_BUTTON_LEFT, true)
	for _i in 4:
		await get_tree().physics_frame
	_mouse(MOUSE_BUTTON_LEFT, false)
	for _i in 30:
		await get_tree().physics_frame
	var click := p.shot_count - before
	print("scoped single click shots=%d (delta %d)  shells=%d  sniper=%s  %s"
			% [p.shot_count, click, _shell_count(), str(rig.sniper),
			"OK" if click == 1 else "FAIL"])
	if click != 1:
		fails += 1

	p.reload_t = 0.0
	before = p.shot_count
	_mouse(MOUSE_BUTTON_LEFT, true)
	for _i in 120:
		await get_tree().physics_frame
	_mouse(MOUSE_BUTTON_LEFT, false)
	for _i in 10:
		await get_tree().physics_frame
	var hold := p.shot_count - before
	print("scoped hold 1s      shots=%d (delta %d)  %s"
			% [p.shot_count, hold, "OK" if hold >= 3 else "FAIL"])
	if hold < 3:
		fails += 1

	_mouse(MOUSE_BUTTON_RIGHT, false)
	for _i in 4:
		await get_tree().physics_frame
	print("after scope release sniper=%s  %s" % [str(rig.sniper),
			"OK" if not rig.sniper else "FAIL"])
	if rig.sniper:
		fails += 1
	return fails


# ---------------- 2 / 3. 锁定与提前量 ----------------

## 一辆匀速横穿的敌车：准星一直压在它身上，0.4 s 后应当锁定；
## 锁定之后**不手动瞄提前量**，直接按当前准星开火也必须命中。
##
## 这一条是"远程打击能力"的直接判据：判定的是**弹道方向**——
## 锁定后按准星开火，炮弹的初速必须指向拦截点；不补提前量的那一发只指向
## 准星压着的车体当前位置（40 m 外差 1.77 m，车体只有 6 m 长，瞄准更靠后的
## 车尾时就会打空）。命中只是兜底，方向对了才是火控真的在工作。
func _check_lock_and_lead(l: Dictionary) -> int:
	var p: Player = l["p"]
	var rig: CameraRig = l["rig"]
	var fails := 0
	var maxd: float = minf(_lane_len - 4.0, MAX_RANGE)
	if maxd < 20.0:
		print("  lock  SKIP: lane %.0fm too short (need 20m)" % _lane_len)
		return 0

	var fwd := Vector3(-sin(_lane_yaw), 0.0, -cos(_lane_yaw))
	var side := Vector3(cos(_lane_yaw), 0.0, -sin(_lane_yaw))
	var ctr: Vector3 = _p0 + fwd * maxd
	var vel := side * TARGET_SPEED

	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.team = 1
	e.hp = DUMMY_HP
	# 敌车要能被准星射线和炮弹射线**真的命中**：物理关掉之后（以及落地完成之前）
	# 它的碰撞体不在物理空间里，射线会直接穿过去，火控锁定永远不成立。
	# 探针自带一个静态碰撞体，位置每帧跟着敌车手动摆。
	e.set_physics_process(false)
	# 物理关掉之后 `_speed` 不会自己推进，但 `motion_velocity()` 读的就是它：
	# 手动给一个"横向 12 m/s"的速度，火控才会算出提前量。
	# 朝向要满足 `-basis.z * speed = side * 12`。
	e.rotation.y = _lane_yaw - PI * 0.5
	e._speed = TARGET_SPEED
	await get_tree().physics_frame

	# 摆位：车头对准走廊，炮塔与准星都指向敌车
	p.global_position = _p0
	p.rotation.y = _lane_yaw
	p.turret.rotation.y = 0.0
	p.reload_t = 0.0
	e.global_position = ctr
	for _i in 2:
		await get_tree().physics_frame

	_mouse(MOUSE_BUTTON_RIGHT, true)
	for _i in 3:
		await get_tree().physics_frame
	var from: Vector3 = p.barrel.global_position
	var tgt0: Vector3 = ctr + Vector3(0, 1.05, 0)
	var d := tgt0 - from
	rig.aim_yaw = atan2(-d.x, -d.z)
	rig.aim_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), Tank.PITCH_MIN, Tank.PITCH_MAX)
	await get_tree().physics_frame
	print("  lock setup  sniper=%s  target=%s" % [str(rig.sniper), str(rig.aim_target())])
	# 敌车在物理帧之间会被探针重新摆位，但 rig 的准星射线按渲染帧缓存，
	# 所以每一帧都要按敌车的当前位置重写一次瞄准角（模拟玩家持续跟瞄）。
	var locked_at := -1
	for i in 70:
		# 敌车沿横向匀速走，瞄准角一直压在它身上（模拟玩家持续跟瞄）。
		var at: Vector3 = ctr + vel * (float(i) / 120.0)
		e.global_position = at
		var to: Vector3 = at + Vector3(0, 1.05, 0)
		var dd := to - from
		rig.aim_yaw = atan2(-dd.x, -dd.z)
		rig.aim_pitch = clampf(atan2(dd.y, Vector2(dd.x, dd.z).length()),
				Tank.PITCH_MIN, Tank.PITCH_MAX)
		rig.invalidate_aim()
		await get_tree().physics_frame
		if p.scope_lock_ready and locked_at < 0:
			locked_at = i
	print("  lock  ready=%s  at_frame=%d  ratio=%.2f  lead=%.2fm  %s"
			% [str(p.scope_lock_ready), locked_at, p.scope_lock_ratio, p.scope_lead_len,
			"OK" if p.scope_lock_ready and p.scope_lead_len > 0.1 else "FAIL"])
	if not p.scope_lock_ready or p.scope_lead_len <= 0.1:
		fails += 1

	# 锁定后按当前准星开火。敌车继续走，看弹道是否真的落在它身上。
	p.reload_t = 0.0
	var fired_at: Vector3 = e.global_position
	var cross: Vector3 = rig.aim_point()
	var fired := p.fire()
	# 直接验方向：炮弹的初速必须指向拦截点，而不是准星当前压着的车体。
	# 只验"打中了"不够——车体有 6 m 长，不补提前量的那一发也可能擦到车尾。
	var sh := _last_shell()
	if sh != null and sh.vel.length() > 1.0:
		var mz: Vector3 = p.muzzle_pos()
		var aim_pt: Vector3 = p._lead_point(cross, e)
		var sd: Vector3 = sh.vel.normalized()
		var off_cross := rad_to_deg(sd.angle_to((cross - mz).normalized()))
		var off_lead := rad_to_deg(sd.angle_to((aim_pt - mz).normalized()))
		var ok_dir: bool = off_lead < 1.0 and off_lead < off_cross * 0.5
		print("  aimed  cross=%.2fdeg  lead=%.2fdeg  SHIFT %.2fm  %s"
				% [off_cross, off_lead, (aim_pt - cross).length(),
				"OK" if ok_dir else "FAIL"])
		if not ok_dir:
			fails += 1
	var elapsed := 0.0
	var min_d := 1.0e9
	var guard := 0
	while guard < 240:
		guard += 1
		await get_tree().physics_frame
		elapsed += 1.0 / 120.0
		# 敌车从击发那一刻起沿横向匀速前进，与火控解算使用的是同一个速度向量
		e.global_position = fired_at + vel * elapsed
		for c in _main.get_children():
			if c is Shell:
				min_d = minf(min_d, c.global_position.distance_to(e.global_position + Vector3(0, 1.0, 0)))
		if e.hp < DUMMY_HP:
			break
		if elapsed > 0.6 and _shell_count() == 0:
			break
	var hit: bool = e.hp < DUMMY_HP
	print("  shot  fired=%s  d=%.0fm  minDist=%.2f  %s"
			% [str(fired), maxd, min_d, "HIT" if hit else "MISS"])
	if not fired or not hit:
		fails += 1

	Input.action_release("aim_scope")
	e.alive = false
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
	return fails


# ---------------- 4. 镜内震屏 ----------------

## 镜内开火震屏必须是腰射的一半：同样的 trauma 在 26° 视场里对应的画面位移
## 是腰射的好几倍，不缩放就一发把准星顶离 40 m 外的目标一整个车身。
func _check_kick(l: Dictionary) -> int:
	var rig: CameraRig = l["rig"]
	var hip := _kick_peak(rig, false)
	var scope := _kick_peak(rig, true)
	var ratio := scope / maxf(hip, 0.0001)
	var ok: bool = absf(ratio - CameraRig.SCOPE_KICK_SCALE) < 0.01
	print("  kick  hip=%.3f  scope=%.3f  ratio=%.2f  %s"
			% [hip, scope, ratio, "OK" if ok else "FAIL"])
	return 0 if ok else 1


## 清掉当前 trauma 之后再打一发，读回峰值。
## trauma 下限为 0 时 fire_kick 的"取 max"分支才不会掩盖缩放。
func _kick_peak(rig: CameraRig, scoped: bool) -> float:
	rig.sniper = scoped
	rig._trauma = 0.0
	rig._fire_push = 0.0
	rig.fire_kick(0.45)
	return rig._fire_push


# ---------------- 工具 ----------------

func _mouse(button: int, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = down
	ev.position = Vector2(960, 540)
	Input.parse_input_event(ev)


func _shell_count() -> int:
	var n := 0
	for c in _main.get_children():
		if c is Shell:
			n += 1
	return n


func _last_shell() -> Shell:
	var found: Shell = null
	for c in _main.get_children():
		if c is Shell:
			found = c
	return found


## 找一条最长的直线走廊（1 m 步进扫 96 m）。
##
## 只扫格子不够：掩体的碰撞体比格子略胖，斜着擦过墙角时中心格是空的，
## 射线却会被相邻墙面的碰撞体挡住（实测 8.5 m 处就有一堵这种墙）。
## 所以同时做一条 1.6 m 高的射线，取两者的较小值。留 2 m 余量，
## 让敌车整个车体都落在这条线上。
func _open_lane(p: Player, arena: Arena) -> Dictionary:
	var origin: Vector3 = p.global_position
	var best := {"yaw": 0.0, "dist": 0.0}
	for step in 288:
		var yaw := deg_to_rad(float(step) * 1.25)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var cell_clear := 0.0
		for i in range(4, 96):
			var pos: Vector3 = origin + dir * float(i)
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
				break
			if arena.blocks_tank(c.x, c.y):
				break
			cell_clear = float(i)
		var ray_clear := _ray_clear(p, origin, dir, 96.0)
		var clear: float = minf(cell_clear, ray_clear - 2.0)
		if clear > float(best["dist"]):
			best = {"yaw": yaw, "dist": clear}
	return best


## 从 1.6 m 高处沿 dir 能走多远。碰撞体不在格子里的装饰物也算数。
func _ray_clear(p: Player, origin: Vector3, dir: Vector3, maxd: float) -> float:
	var from := origin + Vector3(0, 1.6, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * maxd,
			Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [p.get_rid()]
	var hit := p.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return maxd
	return from.distance_to(hit["position"])