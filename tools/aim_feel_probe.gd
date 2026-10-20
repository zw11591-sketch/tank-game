extends Node
## 验收：近距离交战时"人手的动作"与"准星落在哪"之间的距离感。
##
## 与 near_probe.gd 的区别：那里直接把 aim_pitch 设成理想角度，等于假设玩家能精确
## 摆出那个角度；本探针只做玩家真做得到的事——按住鼠标往下拖 px 个像素，然后读回
## 玩家的真实处境：
##   aim     拖完之后的瞄准角（度）
##   retY    准星在画面上的高度（%，0 = 上缘）
##   eBody   敌车车体中心在画面上的高度（%）
##   on      准星射线当前压在谁身上（tank / none）
##   hit     准星压在敌车上时扣扳机是否命中
##
## 每一行都把两辆车的位置钉死：否则十几帧的解叠会把玩家推开一米多，
## 测出来的"没打中"全是探针自己造成的。
##
## 判据（每台车 × 4~12 m）：
##   1. 准星压住敌车时扣扳机必须命中，且弹道爬升 ≤ 2 m；
##   2. 从水平压到"准星落在敌车车体上"所需的鼠标拖动 ≤ 600 px（一次顺畅拖拽）。
##
## 用法：godot.exe --headless --path . res://tools/AimFeelProbe.tscn

const DISTS := [3.2, 4.0, 6.0, 8.0, 12.0]
const DRAGS := [0, 80, 160, 240, 320, 420, 520, 640, 800, 1000, 1200]
const SETTLE := 24
const DUMMY_HP := 1000000
## 一次"顺畅拖拽"的鼠标像素上限
const ONE_DRAG := 600

var _main: Node
var _vp := Vector2(1920.0, 1080.0)
var _yaw := 0.0
var _p0 := Vector3.ZERO
var _rows: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.mouse_sens = 1.0
	Settings.invert_y = false
	_vp = Vector2(get_viewport().get_visible_rect().size)

	for idx in TankRoster.ORDER.size():
		await _run_tank(idx)
	_print_table()
	var fails := _fails()
	print("VERDICT fail=%d / %d %s" % [fails, _rows.size(), "OK" if fails == 0 else "FAIL"])
	get_tree().quit(0 if fails == 0 else 1)


func _run_tank(idx: int) -> void:
	# _confirm_start() 会把 Settings.selected_tank 写成 _sel_tank，所以只能走 _sel_tank
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
	var tid := p.tank_id
	_yaw = _open_yaw(p, _main.arena)
	if _yaw == INF:
		print("VERDICT no open firing lane (%s)" % tid)
		return
	_p0 = p.global_position
	print("== %s  aim_y=%.2f  pitch=[%.0f, %.0f]  drags=%s"
			% [tid, p.aim_height, rad_to_deg(Tank.PITCH_MIN),
			rad_to_deg(Tank.PITCH_MAX), str(DRAGS)])

	for d in DISTS:
		await _run_dist(p, float(d))

	p.global_position = _p0
	_main._clear_battle()
	await get_tree().physics_frame


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [4.0, 8.0, 12.0]:
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
	var ctr: Vector3 = _p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
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

	var body: Vector3 = ctr + Vector3(0, 1.1, 0)
	var body_y := -1.0
	var reach_px := -1.0
	var miss := 0
	var on_rows := 0
	var climb_max := 0.0

	for px in DRAGS:
		_reset_aim(p, e, ctr)
		var rig: CameraRig = _main.rig
		if int(px) > 0:
			rig.handle_mouse(Vector2(0.0, float(px)))
		for _i in SETTLE:
			_pin(p, e, ctr)
			await get_tree().physics_frame

		var aim := rad_to_deg(rig.aim_pitch)
		var sp: Vector2 = rig.aim_screen_point()
		var ret_y := _pct(sp.y) if sp != Vector2.INF else 999.0
		var proj := _project(rig, body)
		if proj.y > -9000.0:
			body_y = _pct(proj.y)
		var on: bool = rig.aim_target() != null and rig.aim_target() != p

		var fired_hit := true
		var climb := 0.0
		if on:
			on_rows += 1
			p.reload_t = 0.0
			var spawn: Vector3 = p.shot_origin(p.aim_dir())
			var fired: bool = p.fire()
			var guard := 0
			while guard < 200:
				guard += 1
				await get_tree().physics_frame
				var any := false
				for c in _main.get_children():
					if c is Shell:
						any = true
						climb = maxf(climb, c.global_position.y - spawn.y)
				if not any:
					break
			fired_hit = fired and e.hp < DUMMY_HP
			climb_max = maxf(climb_max, climb)
			if not fired_hit:
				miss += 1
			e.hp = DUMMY_HP
			e.alive = true
			_pin(p, e, ctr)
		if on and reach_px < 0.0 and aim < -1.0:
			reach_px = float(px)

		_rows.append({
			"tank": p.tank_id, "dist": d, "px": px, "aim": aim, "retY": ret_y,
			"eBody": body_y, "on": on, "hit": fired_hit, "climb": climb,
		})

	var flag := "OK"
	if miss > 0:
		flag = "FAIL(hit)"
	if reach_px < 0.0 or reach_px > ONE_DRAG:
		flag += " TOO-FAR-DOWN(%s)" % (("%.0fpx" % reach_px) if reach_px >= 0.0 else ">1200px")
	print("   d=%.1fm  on-rows=%d  reach=%s  misses=%d  climb=%.2f  %s" % [
		d, on_rows, (("%.0fpx" % reach_px) if reach_px >= 0.0 else ">1200px"),
		miss, climb_max, flag])

	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame


func _reset_aim(p: Player, e: Enemy, ctr: Vector3) -> void:
	var rig: CameraRig = _main.rig
	rig.aim_pitch = 0.0
	rig.pitch = CameraRig.PITCH_BASE
	rig.aim_yaw = _yaw
	rig.yaw = _yaw
	_pin(p, e, ctr)


func _project(rig: CameraRig, world: Vector3) -> Vector2:
	if rig.cam == null or rig.cam.is_position_behind(world):
		return Vector2(0.0, -9999.0)
	return rig.cam.unproject_position(world)


func _pct(y: float) -> float:
	return y / _vp.y * 100.0


func _fails() -> int:
	var n := 0
	for r in _rows:
		if bool(r["on"]) and (not bool(r["hit"]) or float(r["climb"]) > 2.0):
			n += 1
	return n


func _print_table() -> void:
	print("---- AIM FEEL TABLE ----  viewport %dx%d" % [int(_vp.x), int(_vp.y)])
	print("  tank    drag   d   aim    retY  eBody  on     climb  hit")
	for r in _rows:
		print("%-7s %5d %4.1f %6.1f %6.1f %6.1f  %-5s %6.2f  %s" % [
			r["tank"], r["px"], r["dist"], r["aim"], r["retY"], r["eBody"],
			"tank" if bool(r["on"]) else "none", r["climb"],
			"tank" if bool(r["hit"]) else "MISS"])
