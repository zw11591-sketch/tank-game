extends Node
## 临时诊断：玩家实际手感（镜头相对驾驶）下的转向速率、贴墙/走廊里的转角损失，
## 以及随机驾驶时可见车体压进砖墙的最坏深度。打印标签全用 ASCII。

const STEP := 1.0 / 120.0
const TRIALS := 60
const FRAMES := 240

var _main: Node
var _a: Arena
var _p: Player
var _seed := 9001


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.spawn_queue.clear()
	_main.max_active = 0
	for e in _main.enemies.duplicate():
		e.queue_free()
		_main.enemies.erase(e)
	_p = _main.player
	_p.shield_t = 0.0
	_p.set_physics_process(false)
	_a = _main.arena
	Settings.drive_relative = true
	await _frames(4)
	print("PROBE tank=%s hull=(%.3f, %.3f/%.3f) turn=%.2frad/s drive_relative=%s" % [
		_p.tank_id, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b,
		_p.turn_speed, str(Settings.drive_relative)])

	_clear()
	await _frames(2)
	await _open_tests()
	await _corridor_tests()
	await _wall_tests()
	await _stress()

	get_tree().quit(0)


# ---------------- 开阔地 ----------------

func _open_tests() -> void:
	# A/D 原地：满舵
	_place(Arena.cell_center(12, 12), 0.0)
	var yaw0: float = _p.rotation.y
	var t90 := -1.0
	for i in 180:
		_step_input(0.0, 1.0)
		var turned := absf(angle_difference(yaw0, _p.rotation.y))
		if t90 < 0.0 and turned >= deg_to_rad(90.0):
			t90 = (i + 1) * STEP
	print("PROBE open_pivot_A turn90=%s blocked=%d" % [
		("%.3fs" % t90) if t90 > 0.0 else "none", _blocked])

	# W+A 边走边转（镜头相对）
	_place(Arena.cell_center(12, 12), 0.0)
	yaw0 = _p.rotation.y
	var speed_sum := 0.0
	var turn_at := {}
	for i in 180:
		_step_input(1.0, 1.0)
		speed_sum += absf(_p._speed)
		var turned := rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y)))
		if i == 29:
			turn_at["05"] = turned
		elif i == 59:
			turn_at["10"] = turned
		elif i == 119:
			turn_at["20"] = turned
	print("PROBE open_WA deg@0.25=%.1f 0.5=%.1f 1.0=%.1f 1.5=%.1f avg_speed=%.1f blocked=%d pos=(%.2f,%.2f)" % [
		turn_at.get("05", 0.0), turn_at.get("10", 0.0), turn_at.get("20", 0.0),
		rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y))),
		speed_sum / 180.0, _blocked, _p.global_position.x, _p.global_position.z])

	# 先加速到满速再打舵：高速下转向权限
	_place(Arena.cell_center(12, 12), 0.0)
	for i in 90:
		_step_input(1.0, 0.0)
	yaw0 = _p.rotation.y
	var s0: float = _p._speed
	for i in 60:
		_step_input(1.0, 1.0)
	print("PROBE open_fast_A speed0=%.1f deg@0.5=%.1f" % [
		s0, rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y)))])


# ---------------- 走廊 ----------------

func _corridor_tests() -> void:
	# 两格宽（8 m）走廊：现在地形生成会把单格通道拓宽到这里
	_clear()
	for y in range(2, 24):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][14] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	var mid := Vector3((Arena.cell_center(12, 12).x + Arena.cell_center(13, 12).x) * 0.5,
			0.0, Arena.cell_center(12, 12).z)
	_p.global_position = mid
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = mid
	_p.set_physics_process(false)
	await _frames(2)
	print("PROBE corridor8 center=(%.2f,%.2f) depth0=%.3f" % [mid.x, mid.z, _rect_depth()])
	var yaw0: float = _p.rotation.y
	_blocked = 0
	var steer_frames := 0
	var worst := 0.0
	for i in 240:
		_step_input(0.0, 1.0)
		steer_frames += 1
		if _p.turn_blocked:
			_blocked += 1
		worst = maxf(worst, _rect_depth())
	print("PROBE corridor8_pivot_A deg=%.1f blocked=%d/%d deep=%.3f" % [
		rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y))), _blocked, steer_frames, worst])

	# 两格宽走廊里边走边转
	_p.global_position = mid
	_p.rotation.y = 0.0
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = mid
	await _frames(2)
	yaw0 = _p.rotation.y
	_blocked = 0
	worst = 0.0
	for i in 240:
		_step_input(1.0, 1.0)
		if _p.turn_blocked:
			_blocked += 1
		worst = maxf(worst, _rect_depth())
	print("PROBE corridor8_WA deg=%.1f blocked=%d/240 deep=%.3f pos=(%.2f,%.2f)" % [
		rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y))), _blocked, worst,
		_p.global_position.x, _p.global_position.z])


# ---------------- 贴单侧墙 ----------------

func _wall_tests() -> void:
	_clear()
	for y in range(2, 24):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	var face := Arena.cell_center(13, 12).x - Arena.CELL * 0.5
	var pos := Vector3(face - _p._hull_half_w - 0.10, 0.0, Arena.cell_center(12, 12).z)

	for case in [
		{"tag": "hug_A_into", "th": 0.0, "st": 1.0},
		{"tag": "hug_WA_into", "th": 1.0, "st": 1.0},
		{"tag": "hug_A_away", "th": 0.0, "st": -1.0},
		{"tag": "hug_WA_away", "th": 1.0, "st": -1.0},
	]:
		_p.global_position = pos
		_p.rotation.y = 0.0
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = pos
		await _frames(2)
		var yaw0: float = _p.rotation.y
		_blocked = 0
		var worst := 0.0
		for i in 180:
			_step_input(case["th"], case["st"])
			if _p.turn_blocked:
				_blocked += 1
			worst = maxf(worst, _rect_depth())
		print("PROBE %s deg=%.1f blocked=%d/180 deep=%.3f pos=(%.2f,%.2f)" % [
			case["tag"], rad_to_deg(absf(angle_difference(yaw0, _p.rotation.y))),
			_blocked, worst, _p.global_position.x, _p.global_position.z])


# ---------------- 真实地图随机驾驶 ----------------

func _stress() -> void:
	# 换回原生地图
	_main._sel_terrain = 0
	_main._sel_stage = 0
	_a.generate(1, 0)
	await _frames(4)
	var cells := _open_cells()
	print("PROBE stress open_cells=%d" % cells.size())
	var worst := 0.0
	var info := ""
	var hist := [0, 0, 0, 0, 0]
	var used := 0
	_blocked = 0
	var steer_frames := 0
	for trial in TRIALS:
		var c: Vector2i = cells[_rnd(0, cells.size())]
		var yaw := float(_rnd(-4, 4)) * PI * 0.25
		var gp := Arena.cell_center(c.x, c.y)
		_p.global_position = gp
		_p.rotation.y = yaw
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = gp
		_p.set_physics_process(false)
		await _frames(2)
		if _rect_depth() > 0.001:
			continue
		used += 1
		var th := float(_rnd(-1, 2))
		var st := float(_rnd(-1, 2))
		var md := 0.0
		var mbi := ""
		for i in FRAMES:
			if i % 40 == 0:
				if _rnd(0, 3) == 0:
					st = -st
				if _rnd(0, 4) == 0:
					th = 0.0
			_step_input(th, st)
			if not is_zero_approx(st):
				steer_frames += 1
			if _p.turn_blocked:
				_blocked += 1
			var d := _rect_depth()
			if d > md:
				md = d
				mbi = "i=%d pos=(%.2f,%.2f) yaw=%.0f th=%.1f st=%.1f" % [
					i, _p.global_position.x, _p.global_position.z,
					rad_to_deg(_p.rotation.y), th, st]
		if md > worst:
			worst = md
			info = "trial=%d cell=(%d,%d) %s" % [trial, c.x, c.y, mbi]
		if md > 0.18:
			hist[4] += 1
		elif md > 0.12:
			hist[3] += 1
		elif md > 0.06:
			hist[2] += 1
		elif md > 0.03:
			hist[1] += 1
		else:
			hist[0] += 1
	print("PROBE stress worst=%.3f %s" % [worst, info])
	print("PROBE stress used=%d hist <=3cm=%d 3-6cm=%d 6-12cm=%d 12-18cm=%d >18cm=%d" % [
		used, hist[0], hist[1], hist[2], hist[3], hist[4]])
	print("PROBE turn blocked_frames=%d steer_frames=%d ratio=%.3f" % [
		_blocked, steer_frames, float(_blocked) / maxf(float(steer_frames), 1.0)])


# ---------------- 驾驶输入（与 Player.tick 的两行保持一致） ----------------

func _step_input(fwd: float, right: float) -> void:
	var yaw_before: float = _p.rotation.y
	var cmd: Vector2 = _p._relative_drive(fwd, right)
	_p.drive(cmd.x, cmd.y, STEP)
	_p._carry_aim_with_steer(yaw_before)


func _place(pos: Vector3, yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos
	_p.set_physics_process(false)
	_blocked = 0


# ---------------- 量测 ----------------

var _blocked := 0


func _rect_depth() -> float:
	var yaw: float = _p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (_p._hull_half_f - _p._hull_half_b) * 0.5
	var center: Vector3 = _p.global_position + fwd * off
	var hl := (_p._hull_half_f + _p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 9:
		for ix in 9:
			var u := (float(ix) / 8.0 - 0.5) * 2.0
			var w := (float(iz) / 8.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * _p._hull_half_w) + fwd * (w * hl)
			deep = maxf(deep, _point(pt))
	return deep


func _point(pt: Vector3) -> float:
	var c := Arena.to_cell(pt)
	if not _a.blocks_tank(c.x, c.y):
		return 0.0
	var center := Arena.cell_center(c.x, c.y)
	var half := Arena.CELL * 0.5
	return minf(half - absf(pt.x - center.x), half - absf(pt.z - center.z))


func _open_cells() -> Array:
	var out: Array = []
	for y in range(2, Arena.GRID_H - 2):
		for x in range(2, Arena.GRID_W - 2):
			if not _a.blocks_tank(x, y):
				out.append(Vector2i(x, y))
	return out


func _rnd(a: int, b: int) -> int:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return a + _seed % maxi(b - a, 1)


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY
	_a._rebuild_all()


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
