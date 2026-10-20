extends Node
## 临时诊断（第二阶段）：
##   1. 五款车在开阔地 / 8m 走廊 / 贴墙三种工况下的实际转角；
##   2. 可见车体网格顶点是否被 Tank._hull_half_* 矩形包住；
##   3. 被外力顶向墙面时（nudge 连续推）可见车体的最坏压入深度；
##   4. 真实地图里"起始位置紧贴墙面"的随机驾驶压入深度。
## 打印标签全用 ASCII。

const STEP := 1.0 / 120.0

var _main: Node
var _a: Arena
var _p: Player
var _seed := 7777
var _blocked := 0


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
	_p.global_position = Vector3(0.0, -60.0, 0.0)
	_a = _main.arena
	Settings.drive_relative = true
	await _frames(4)

	for id in TankRoster.ORDER:
		var pl := Player.new()
		pl.tank_id = id
		pl.setup(_main, _a, Arena.cell_center(12, 12))
		pl.rig = _main.rig
		add_child(pl)
		await _frames(3)
		pl.set_physics_process(false)
		pl.shield_t = 0.0
		_p = pl
		_verts.clear()
		print("PROBE === %s turn=%.2f hull=(%.3f,%.3f/%.3f) mesh=(%.2f,%.2f/%.2f)" % [
			id, _p.turn_speed, _p._hull_half_w, _p._hull_half_f, _p._hull_half_b,
			_mesh_half_w(), _mesh_front(), _mesh_back()])
		await _tank_cases()
		_p.queue_free()
		await _frames(2)

	# 随机地图压力测试用基准车（Main 自带的那辆，位置已经挪开）
	var base := Player.new()
	base.tank_id = "falcon"
	base.setup(_main, _a, Arena.cell_center(12, 12))
	base.rig = _main.rig
	add_child(base)
	await _frames(3)
	base.set_physics_process(false)
	base.shield_t = 0.0
	_p = base
	await _stress_wall_hug()
	get_tree().quit(0)


func _tank_cases() -> void:
	_clear()
	await _frames(2)
	# 开阔地：A 满舵，量 90 度用时
	_place(Arena.cell_center(12, 12), 0.0)
	var yaw0: float = _p.rotation.y
	var t90 := -1.0
	for i in 240:
		_step_input(0.0, 1.0)
		if t90 < 0.0 and absf(angle_difference(yaw0, _p.rotation.y)) >= deg_to_rad(90.0):
			t90 = (i + 1) * STEP
	print("PROBE %s open90=%s" % [
		_p.tank_id, ("%.3fs" % t90) if t90 > 0.0 else "none"])

	# 8m 走廊原地转 2 s
	_clear()
	for y in range(2, 24):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][14] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	var mid := Vector3((Arena.cell_center(12, 12).x + Arena.cell_center(13, 12).x) * 0.5,
			0.0, Arena.cell_center(12, 12).z)
	_place(mid, 0.0)
	yaw0 = _p.rotation.y
	var total := 0.0
	var last: float = p_yaw()
	var worst := 0.0
	_blocked = 0
	for i in 240:
		_step_input(0.0, 1.0)
		total += absf(angle_difference(last, p_yaw()))
		last = p_yaw()
		if _p.turn_blocked:
			_blocked += 1
		worst = maxf(worst, _rect_depth())
	print("PROBE %s corridor8 total=%.1f blocked=%d/240 deep=%.3f" % [
		_p.tank_id, rad_to_deg(total), _blocked, worst])

	# 贴单侧墙、往墙里打舵 1.5 s
	_clear()
	for y in range(2, 24):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	var face := Arena.cell_center(13, 12).x - Arena.CELL * 0.5
	var pos := Vector3(face - _p._hull_half_w - 0.10, 0.0, Arena.cell_center(12, 12).z)
	_place(pos, 0.0)
	yaw0 = _p.rotation.y
	total = 0.0
	last = p_yaw()
	worst = 0.0
	_blocked = 0
	for i in 180:
		_step_input(0.0, 1.0)
		total += absf(angle_difference(last, p_yaw()))
		last = p_yaw()
		if _p.turn_blocked:
			_blocked += 1
		worst = maxf(worst, _rect_depth())
	print("PROBE %s wallhug total=%.1f blocked=%d/180 deep=%.3f x=%.2f" % [
		_p.tank_id, rad_to_deg(total), _blocked, worst, _p.global_position.x])

	# 外力顶向墙：每帧 nudge 0.12 m
	_place(pos, 0.0)
	worst = 0.0
	for i in 120:
		_p.nudge(Vector3(0.12, 0.0, 0.0))
		worst = maxf(worst, _rect_depth())
	print("PROBE %s pushIn deep=%.3f x=%.2f" % [
		_p.tank_id, worst, _p.global_position.x])


func _stress_wall_hug() -> void:
	# 换回真正的随机地图
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
	var steer_frames := 0
	_blocked = 0
	for trial in 120:
		var c: Vector2i = cells[_rnd(0, cells.size())]
		# 只取紧贴实心格的位置：车体中心必须离墙至少半个车宽，否则一开局就压墙
		var gp := Arena.cell_center(c.x, c.y)
		_p.global_position = gp
		_p.rotation.y = 0.0
		_p._speed = 0.0
		_p.velocity = Vector3.ZERO
		_p._safe_pos = gp
		_p.set_physics_process(false)
		await _frames(2)
		if _rect_depth() > 0.001:
			continue
		used += 1
		var yaw := float(_rnd(-4, 4)) * PI * 0.25
		_p.rotation.y = yaw
		_p._settle()
		var th := 1.0
		var st := 1.0 if _rnd(0, 2) == 0 else -1.0
		var md := 0.0
		var mbi := ""
		for i in 180:
			if i % 30 == 0 and _rnd(0, 4) == 0:
				st = -st
			_step_input(th, st)
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
	print("PROBE turn blocked=%d/%d ratio=%.3f" % [
		_blocked, steer_frames, float(_blocked) / maxf(float(steer_frames), 1.0)])


# ---------------- 网格轮廓 ----------------

var _verts: Array = []


func _mesh_half_w() -> float:
	_verts.clear()
	_collect(_p)
	return _extent(0)


func _mesh_front() -> float:
	if _verts.is_empty():
		_collect(_p)
	return _extent(2, true)


func _mesh_back() -> float:
	if _verts.is_empty():
		_collect(_p)
	return _extent(2, false)


func _extent(axis: int, front := false) -> float:
	var v := 0.0
	for e in _verts:
		var mi: MeshInstance3D = e[0]
		var arr: PackedVector3Array = e[1]
		var xf: Transform3D = _p.global_transform.affine_inverse() * mi.global_transform
		for p in arr:
			var q: Vector3 = xf * p
			var val: float = absf(q[axis]) if axis == 0 else (maxf(-q.z, 0.0) if front else maxf(q.z, 0.0))
			v = maxf(v, val)
	return v


func _collect(n: Node) -> void:
	if n is MeshInstance3D and n.mesh != null:
		var mi := n as MeshInstance3D
		if _p._counts_as_hull(mi) and not _under_gun(mi) and mi.mesh.get_surface_count() > 0:
			var arr: Array = mi.mesh.surface_get_arrays(0)
			if not arr.is_empty():
				_verts.append([mi, arr[Mesh.ARRAY_VERTEX]])
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		_collect(c)


func _under_gun(n: Node) -> bool:
	var q: Node = n
	while q != null and q != _p:
		var s := String(q.name)
		if s.begins_with("Turret") or s.begins_with("Barrel") or s.begins_with("Muzzle"):
			return true
		q = q.get_parent()
	return false


# ---------------- 驾驶 ----------------

func _step_input(fwd: float, right: float) -> void:
	var yaw_before: float = _p.rotation.y
	var cmd: Vector2 = _p._relative_drive(fwd, right)
	_p.drive(cmd.x, cmd.y, STEP)
	_p._carry_aim_with_steer(yaw_before)


func p_yaw() -> float:
	return _p.rotation.y


func _place(pos: Vector3, yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos
	_p.set_physics_process(false)
	_blocked = 0


# ---------------- 量测 ----------------

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
