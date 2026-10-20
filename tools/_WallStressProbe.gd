extends Node
## 临时诊断：真实关卡里随机驾驶/随机朝向/被顶开时，可见车体压进墙里的最坏深度。
## 度量与 _ClipAfter 一致：车体矩形上 7x7 采样点到实心格边界的最大距离。
## 打印标签全用 ASCII。

const STEP := 1.0 / 120.0

var _main: Node
var _a: Arena
var _p: Player
var _seed := 777


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
	print("PROBE stress tank=%s hull=(%.2f, %.2f/%.2f) map=%s" % [
		_p.tank_id, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b,
		_a.terrain_name()])

	var cells := _open_cells()
	print("PROBE stress open_cells=%d" % cells.size())

	var worst := 0.0
	var worst_info := ""
	var hist := [0, 0, 0, 0, 0]
	var used := 0
	for trial in 240:
		var c: Vector2i = cells[_rnd(0, cells.size())]
		var yaw := _rnd(-3, 4) * PI * 0.25
		var pos := Arena.cell_center(c.x, c.y)
		_p.global_position = pos
		_p.rotation.y = yaw
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = pos
		if _depth() > 0.001:
			continue
		used += 1
		var th := float(_rnd(-1, 2))
		var st := float(_rnd(-1, 2))
		var md := 0.0
		for i in 240:
			# 后半段随机换输入，模拟"撞上之后继续给油/给舵"
			if i % 40 == 0:
				if _rnd(0, 3) == 0:
					st = -st
				if _rnd(0, 4) == 0:
					th = 0.0
			_p.drive(th, st, STEP)
			# 每 6 帧插一次"被别的坦克顶开"
			if i % 6 == 0 and _rnd(0, 3) == 0:
				var ang := _rnd(0, 628) * 0.01
				_p.nudge(Vector3(cos(ang), 0.0, sin(ang)) * (0.05 + _rnd(0, 20) * 0.01))
			var d := _depth()
			if d > md:
				md = d
		if md > worst:
			worst = md
			worst_info = "trial=%d cell=(%d,%d) yaw=%.0f th=%.1f st=%.1f" % [
				trial, c.x, c.y, rad_to_deg(yaw), th, st]
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
	print("PROBE stress worst=%.3f %s" % [worst, worst_info])
	print("PROBE stress used=%d hist <=3cm=%d 3-6cm=%d 6-12cm=%d 12-18cm=%d >18cm=%d" % [
		used, hist[0], hist[1], hist[2], hist[3], hist[4]])

	# 单独跑一遍大地图长时间直线冲墙
	await _ram_report()
	get_tree().quit(0)


func _ram_report() -> void:
	var cells := _open_cells()
	var worst := 0.0
	var info := ""
	for trial in 80:
		var c: Vector2i = cells[_rnd(0, cells.size())]
		var yaw := _rnd(0, 8) * PI * 0.25
		var pos := Arena.cell_center(c.x, c.y)
		_p.global_position = pos
		_p.rotation.y = yaw
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = pos
		if _depth() > 0.001:
			continue
		var md := 0.0
		for i in 360:
			_p.drive(1.0, 0.0, STEP)
			md = maxf(md, _depth())
		if md > worst:
			worst = md
			info = "trial=%d cell=(%d,%d) yaw=%.0f" % [trial, c.x, c.y, rad_to_deg(yaw)]
	print("PROBE ram worst=%.3f %s" % [worst, info])


func _open_cells() -> Array:
	var out: Array = []
	for y in range(2, Arena.GRID_H - 2):
		for x in range(2, Arena.GRID_W - 2):
			if not _a.blocks_tank(x, y) and not _a.blocks_tank(x - 1, y) \
					and not _a.blocks_tank(x + 1, y) and not _a.blocks_tank(x, y - 1) \
					and not _a.blocks_tank(x, y + 1):
				out.append(Vector2i(x, y))
	return out


func _depth() -> float:
	var yaw: float = _p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (_p._hull_half_f - _p._hull_half_b) * 0.5
	var center: Vector3 = _p.global_position + fwd * off
	var hl := (_p._hull_half_f + _p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 7:
		for ix in 7:
			var u := (float(ix) / 6.0 - 0.5) * 2.0
			var w := (float(iz) / 6.0 - 0.5) * 2.0
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
