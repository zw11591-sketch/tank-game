extends Node
## 临时诊断：在整张地图上随机取"合法但可能很挤"的位姿，长时间给油+给舵，
## 量可见车体压进墙里的最坏深度与被几何挡住的转向比例。
## 打印标签全用 ASCII。

const STEP := 1.0 / 120.0
const TRIALS := 90
const FRAMES := 300

var _main: Node
var _a: Arena
var _p: Player
var _seed := 20261020
var _blocked := 0
var _steer_frames := 0
var _depth_frames := 0
var _total_frames := 0


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 0
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
	_a = _main.arena
	await _frames(4)
	print("PROBE tight tank=%s hull=(%.2f, %.2f/%.2f)" % [
		_p.tank_id, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b])

	var worst := 0.0
	var worst_info := ""
	var used := 0
	var hist := [0, 0, 0, 0, 0]
	for trial in TRIALS:
		# 任意空格中心 + 任意朝向；只跳过一放下去就压墙的位姿
		var cx := _rnd(2, Arena.GRID_W - 2)
		var cy := _rnd(2, Arena.GRID_H - 2)
		if _a.blocks_tank(cx, cy):
			continue
		var yaw := _rnd(0, 16) * PI / 8.0
		var pos := Arena.cell_center(cx, cy)
		_p.global_position = pos
		_p.rotation.y = yaw
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = pos
		if _depth() > 0.001:
			continue
		used += 1
		var md := 0.0
		var mbi := ""
		for i in FRAMES:
			var th := 1.0
			var st := 0.0
			if i < FRAMES / 3:
				st = 1.0
			elif i < 2 * FRAMES / 3:
				st = -1.0
			else:
				th = -1.0
				st = 1.0
			_steer_frames += 1
			_total_frames += 1
			_p.drive(th, st, STEP)
			if _p.turn_blocked:
				_blocked += 1
			var d := _depth()
			if d > 0.002:
				_depth_frames += 1
			if d > md:
				md = d
				mbi = "i=%d pos=(%.2f,%.2f) yaw=%.0f" % [
					i, _p.global_position.x, _p.global_position.z, rad_to_deg(_p.rotation.y)]
		if md > worst:
			worst = md
			worst_info = "trial=%d cell=(%d,%d) %s" % [trial, cx, cy, mbi]
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
	print("PROBE tight worst=%.3f %s" % [worst, worst_info])
	print("PROBE tight used=%d hist <=3cm=%d 3-6cm=%d 6-12cm=%d 12-18cm=%d >18cm=%d" % [
		used, hist[0], hist[1], hist[2], hist[3], hist[4]])
	print("PROBE tight blocked=%d/%d (%.1f%%) depthFrames=%d/%d" % [
		_blocked, _steer_frames, 100.0 * float(_blocked) / maxf(float(_steer_frames), 1.0),
		_depth_frames, _total_frames])
	get_tree().quit(0)


func _depth() -> float:
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


func _rnd(a: int, b: int) -> int:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return a + _seed % maxi(b - a, 1)


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
