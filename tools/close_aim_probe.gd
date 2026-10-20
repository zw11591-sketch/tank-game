extends Node
## 验收：近战把准星压在敌车**看得见的那块外形**上（而不是精确的车体中心）时，
## 炮弹到底打不打中、弹道有没有爬升。
##
## 背景：near_probe 只把准星压到车体中心 / 炮塔中心，而玩家在 3~18 m 上瞄的是
## 炮塔那块最大的轮廓——它的上沿、左右两个角都在命中体之外。炮管于是被抬到
## 正仰角，炮弹从车顶擦过去、一路飞到天上。
##
## 每一行：lateral 是横向偏移、aimY 是瞄准高度，两者都取**正面**上的一个点
## （不是车体中心，否则纵向角度会偏小）。判据：
##   * 弹道必须落在车上：`hit = tank`（造成伤害）或 `tank*`（正面跳弹）。
##     跳弹是 4.2 节的设计结果（正面 + AP + `ang > 32°` 时 30%），零伤害但炮弹
##     确实撞在车体上、有"跳弹!"飘字，不是玩家说的"打空"，所以单列一栏而不算失败。
##   * 真正的失败有两种：射线从车边飞过去（blowby，弹道爬升几十米一路飞走），
##     或者炮管压根没朝准星（说明压炮把瞄准拽歪了）。两种都打 `MISS`。
##
## 用法：godot.exe --headless --path . res://tools/CloseAimProbe.tscn

const DISTS := [3.0, 5.0, 8.0, 12.0, 18.0, 24.0, 36.0, 48.0]
const LATERALS := [-1.25, 0.0, 1.25]
const HEIGHTS := [1.1, 2.4]
## 反向验收：准星抬到车顶上方这么高（米）就是"瞄天空"，压炮一点都不许介入。
const SKY_RISE := 1.2
const SETTLE := 24
const DUMMY_HP := 1000000

var _main: Node
var _yaw := 0.0
var _p0 := Vector3.ZERO
var _rows: Array = []
var _sky: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	for idx in TankRoster.ORDER.size():
		await _run_tank(idx)
	_print_table()
	var bad := _fails()
	print("VERDICT fail=%d / %d %s" % [bad, _rows.size(), "OK" if bad == 0 else "FAIL"])
	get_tree().quit(0 if bad == 0 else 1)


func _run_tank(idx: int) -> void:
	_main = get_node("Main")
	_main._sel_tank = idx
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 10:
		await get_tree().physics_frame

	var p: Player = _main.player
	_yaw = _open_yaw(p, _main.arena)
	if _yaw == INF:
		print("VERDICT no open lane")
		return
	_p0 = p.global_position
	print("== %s aim_y=%.2f" % [p.tank_id, p.aim_height])

	for d in DISTS:
		await _run_dist(p, float(d))
	# 反向验收：瞄车顶上方就是瞄天空，压炮不许把炮管拽下来。
	# 只在准星真的抬得到的高度上测：12 m 处要 9.2° 才够到车顶上方，而炮管上限 6°，
	# 那一帧"准星"本身就被钳在车顶附近，压炮介入是正确行为。
	for d in [24.0, 36.0, 48.0]:
		await _run_sky(p, float(d))

	p.global_position = _p0
	_main._clear_battle()
	await get_tree().physics_frame


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [3.0, 6.0, 12.0, 18.0, 24.0, 36.0, 48.0]:
			var pos: Vector3 = p.global_position + dir * d
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
				ok = false
				break
			if arena.blocks_tank(c.x, c.y):
				ok = false
				break
			if not arena.has_line_of_sight(eye, pos + Vector3(0, 1.5, 0)):
				ok = false
				break
		if ok:
			return yaw
	return INF


func _pin(p: Player, e: Enemy, ctr: Vector3) -> void:
	p.global_position = _p0
	p.rotation.y = _yaw
	p._speed = 0.0
	e.global_position = ctr
	e.rotation.y = _yaw + PI


func _run_dist(p: Player, d: float) -> void:
	var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var ctr: Vector3 = _p0 + fwd * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = DUMMY_HP
	e.set_physics_process(false)
	await get_tree().physics_frame
	_pin(p, e, ctr)

	var miss := 0
	var ric := 0
	var climb_max := 0.0
	for lat in LATERALS:
		for h in HEIGHTS:
			var rec := await _one(p, e, ctr, fwd, side, d, float(lat), float(h))
			_rows.append(rec)
			if not bool(rec["hit"]):
				miss += 1
			if bool(rec["ricochet"]):
				ric += 1
			climb_max = maxf(climb_max, float(rec["climb"]))

	print("   d=%5.1fm  misses=%2d  ricochet=%2d  climbMax=%6.2f  %s" % [
			d, miss, ric, climb_max, "OK" if miss == 0 else "FAIL"])

	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame


## 瞄准点取敌车**正面**上的一个可见点：车身半径 1.5 m，再往里 0.25 m
func _one(p: Player, e: Enemy, ctr: Vector3, fwd: Vector3, side: Vector3,
		d: float, lat: float, h: float) -> Dictionary:
	var face: Vector3 = ctr - fwd * 1.25 + side * lat + Vector3(0, h, 0)
	var pivot: Vector3 = p.global_position + Vector3(0, p.aim_height, 0)
	var to: Vector3 = face - pivot
	var flat := Vector2(to.x, to.z).length()
	var ideal := atan2(to.y, maxf(flat, 0.5))
	var rig: CameraRig = _main.rig
	rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
	rig.aim_pitch = clampf(ideal, Tank.PITCH_MIN, Tank.PITCH_MAX)
	rig.yaw = rig.aim_yaw
	rig.pitch = CameraRig.PITCH_BASE
	p.rotation.y = rig.aim_yaw
	# 上一行打出去的炮弹还在飞是最常见的串扰源：AP 弹没有重力、6 秒才消失，
	# 把它的爬升算到这一发头上就会得出"负仰角也爬升 150 m"这种假数据。
	_clear_shells()
	for _i in SETTLE:
		_pin(p, e, ctr)
		await get_tree().physics_frame

	var barrel := rad_to_deg(p.barrel.rotation.x)
	var spawn: Vector3 = p.shot_origin(p.aim_dir())
	e.hp = DUMMY_HP
	e.hit_count = 0
	p.reload_t = 0.0
	var fired: bool = p.fire()
	var shell: Shell = _first_shell()
	var climb := 0.0
	var guard := 0
	while guard < 240:
		guard += 1
		await get_tree().physics_frame
		if not is_instance_valid(shell):
			break
		climb = maxf(climb, shell.global_position.y - spawn.y)

	var hits: int = e.hit_count
	var dmg: int = DUMMY_HP - e.hp
	var stuck: bool = fired and hits > 0
	e.hp = DUMMY_HP
	e.alive = true
	_pin(p, e, ctr)
	return {
		"tank": p.tank_id, "dist": d, "lat": lat, "aimY": h,
		"ideal": rad_to_deg(ideal), "barrel": barrel,
		"climb": climb, "hit": stuck, "ricochet": stuck and dmg == 0,
	}


func _clear_shells() -> void:
	for c in _main.get_children():
		if c is Shell:
			c.queue_free()


func _first_shell() -> Shell:
	for c in _main.get_children():
		if c is Shell:
			return c
	return null


## 反向验收：准星抬到炮塔顶上方 `SKY_RISE` 米（明显是打天空）时，压炮必须完全不介入。
##
## 判据两条：炮管角就是玩家给的角度（误差 < 0.3°），且这一发不打中车。
## 少了这条，"压炮"可以靠"一直把炮管压在车体中心"骗过上面那张表——
## 那样一来远处想打高一点也打不上去，成了另一个 bug。
func _run_sky(p: Player, d: float) -> void:
	var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var ctr: Vector3 = _p0 + fwd * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = DUMMY_HP
	e.set_physics_process(false)
	await get_tree().physics_frame
	_pin(p, e, ctr)

	var h: float = p.aim_height + Tank.TURRET_TOP_RISE + SKY_RISE
	var pivot: Vector3 = _p0 + Vector3(0, p.aim_height, 0)
	var to: Vector3 = ctr + Vector3(0, h, 0) - pivot
	var flat := Vector2(to.x, to.z).length()
	var ideal := atan2(to.y, maxf(flat, 0.5))
	var rig: CameraRig = _main.rig
	rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
	rig.aim_pitch = clampf(ideal, Tank.PITCH_MIN, Tank.PITCH_MAX)
	rig.yaw = rig.aim_yaw
	rig.pitch = CameraRig.PITCH_BASE
	p.rotation.y = rig.aim_yaw
	_clear_shells()
	for _i in SETTLE:
		_pin(p, e, ctr)
		await get_tree().physics_frame

	var want := rad_to_deg(clampf(ideal, Tank.PITCH_MIN, Tank.PITCH_MAX))
	var barrel := rad_to_deg(p.barrel.rotation.x)
	e.hp = DUMMY_HP
	e.hit_count = 0
	p.reload_t = 0.0
	p.fire()
	var shell: Shell = _first_shell()
	var guard := 0
	while guard < 120 and is_instance_valid(shell):
		guard += 1
		await get_tree().physics_frame

	var drifted := absf(barrel - want) < 0.3
	var missed: bool = e.hit_count == 0
	_sky.append({
		"tank": p.tank_id, "dist": d, "aimY": h, "ideal": rad_to_deg(ideal),
		"barrel": barrel, "drifted": drifted, "missed": missed,
	})

	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame


func _fails() -> int:
	var n := 0
	for r in _rows:
		if not bool(r["hit"]):
			n += 1
	for s in _sky:
		if not (bool(s["drifted"]) and bool(s["missed"])):
			n += 1
	return n


func _print_table() -> void:
	print("---- CLOSE AIM TABLE (crosshair on the visible tank) ----")
	print("  pitch [%.1f, %.1f] deg" % [rad_to_deg(Tank.PITCH_MIN), rad_to_deg(Tank.PITCH_MAX)])
	print("  tank    dist   lat  aimY  ideal barrel  climb  hit")
	for r in _rows:
		print("%-7s %5.1f %5.2f %5.1f %6.1f %6.1f %6.2f  %s" % [
			r["tank"], r["dist"], r["lat"], r["aimY"], r["ideal"], r["barrel"],
			r["climb"], "tank*" if bool(r["ricochet"]) else ("tank" if bool(r["hit"]) else "MISS")])
	print("---- SKY TABLE (crosshair above the turret: assist must stay out) ----")
	print("  tank    dist  aimY  ideal barrel  free  miss")
	for s in _sky:
		print("%-7s %5.1f %5.1f %6.1f %6.1f %5s %5s%s" % [
			s["tank"], s["dist"], s["aimY"], s["ideal"], s["barrel"],
			"yes" if bool(s["drifted"]) else "NO",
			"yes" if bool(s["missed"]) else "NO",
			"" if bool(s["drifted"]) and bool(s["missed"]) else "  FAIL"])
