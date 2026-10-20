extends Node
## 临时诊断 4：随机地图 + 随机朝向/输入模糊测试，找车体压进墙的最坏情况。

var _main: Node
var _a: Arena
var _p: Player
var _dt := 1.0 / 120.0
var _seed := 12345


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	_main._sel_tank = 0
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_p = _main.player
	_p.shield_t = 0.0
	_a = _main.arena
	await _frames(4)

	var worst := 0.0
	var worst_info := ""
	var hist := [0, 0, 0, 0, 0]
	var skipped := 0
	var used := 0
	for trial in 160:
		_make_field(trial)
		# 车放在中心格，随机朝向；随机给 W/S + A/D
		var yaw := deg_to_rad(_rnd(0, 360))
		_p.global_position = Arena.cell_center(12, 12)
		_p.rotation.y = yaw
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = _p.global_position
		# 起点本来就压在墙里的样本不说明问题（真实游戏不会这么刷新），直接跳过
		if _p._hull_depth(yaw) > 0.001:
			skipped += 1
			continue
		used += 1
		var th := float(_rnd(-1, 1))
		var st := float(_rnd(-1, 1))
		if absf(th) < 0.3:
			th = 0.0
		var md := 0.0
		for i in 150:
			_p.drive(th, st, _dt)
			var d := _p._hull_depth(_p.rotation.y)
			if d > md:
				md = d
			if i == 75:
				st = -st if _rnd(0, 2) == 0 else st
		if md > worst:
			worst = md
			worst_info = "trial=%d yaw=%.0f th=%.1f st=%.1f" % [trial, rad_to_deg(yaw), th, st]
		if md > 0.18:
			hist[4] += 1
		elif md > 0.12:
			hist[3] += 1
		elif md > 0.06:
			hist[2] += 1
		elif md > 0.02:
			hist[1] += 1
		else:
			hist[0] += 1
	print("PROBE fuzz worst=%.3f %s" % [worst, worst_info])
	print("PROBE fuzz used=%d skipped=%d" % [used, skipped])
	print("PROBE fuzz hist <=2cm=%d 2-6cm=%d 6-12cm=%d 12-18cm=%d >18cm=%d" % [
		hist[0], hist[1], hist[2], hist[3], hist[4]])
	get_tree().quit(0)


func _make_field(trial: int) -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY
	# 中心 7x7 周围随机摆墙，避开中心格
	for y in range(8, 17):
		for x in range(8, 17):
			if x == 12 and y == 12:
				continue
			if _rnd(0, 100) < 34:
				_a.grid[y][x] = Arena.BRICK
	_a._rebuild_all()


func _rnd(a: int, b: int) -> int:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return a + _seed % maxi(b - a, 1)


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
