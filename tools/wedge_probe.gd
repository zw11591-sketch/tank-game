extends Node
## 临时验收：单格宽门口（一行砖墙上只留一格）的通过性。
##
## squeeze_probe 的 gapRel 用例在这里重做一版，去掉两个会伪造结论的因素：
##   1. 旧用例把 rig.yaw 写死。但第三人称相机的 _follow() 每帧都把 yaw 拖向车体朝向，
##      于是"写死的镜头方向"很快就变成车自己的朝向——转向控制器看到的角度误差归零，
##      再也不修方向。这里只给 rig.aim_yaw（玩家的准星意图），让相机自然跟随。
##   2. 旧用例把准星瞄在门口中心：车一开过门口，"到门口中心的方向"会突然反转 180°，
##      量到的减速其实是"玩家在往回看"。这里逐帧把准星压在门后那条路上
##      （门中线上车前 LOOKAHEAD 米的一点，进门前钉在墙面），与玩家实际做的事一致。
##
## 判据用"实际前进位移"而不是 _speed：撞在门框上时 _speed 仍然报 15（那只是指令），
## 只有位移能说明车有没有在走。stall 统计"油门到底却既不前进也不收敛"的帧数。
##
## 打印标签全用 ASCII（中文过 PowerShell 管道会被二次编码成乱码）。
## 用法：godot --headless --path <proj> res://tools/WedgeProbe.tscn

const STEP := 1.0 / 120.0
const WARM := 150
## 准星参照点放在门中线上的车前多少米
const LOOKAHEAD := 12.0

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _main() -> Node:
	return get_node("Main")


func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 40 and not _started:
		_started = true
		_run()


func _clear_all(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	a._rebuild_all()


## 一整排砖墙上只留 x 那一格通
func _build_gap(a: Arena, x: int, yw: int) -> void:
	_clear_all(a)
	for xx in range(2, Arena.GRID_W - 2):
		a.grid[yw][xx] = Arena.BRICK
	a.grid[yw][x] = Arena.EMPTY
	a._rebuild_all()


## 单格宽走廊 → 单格宽门口 串起来：这才是"狭窄的障碍物通道"的完整走法
func _build_corridor_and_gap(a: Arena, x: int, yg: int) -> void:
	_clear_all(a)
	for y in range(1, yg):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	for xx in range(2, Arena.GRID_W - 2):
		a.grid[yg][xx] = Arena.BRICK
	a.grid[yg][x] = Arena.EMPTY
	a._rebuild_all()


func _pose(p: Player, a: Arena, x: int, y: int, yaw_off: float, lat: float) -> void:
	p.global_position = Arena.cell_center(x, y) + Vector3(lat, 0.0, 0.0)
	p.rotation.y = PI + yaw_off
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	p.hp = 1_000_000
	if p.turret != null:
		p.turret.rotation.y = 0.0


## 门口用例：偏 lat 米、车头偏 deg 度，准星压在门后那条路上，按住 W。
## 返回巡航后的最低速、穿过去用的帧数、停滞帧数、最大横向漂移。
func _door(main: Node, p: Player, a: Arena, x: int, yw: int, y_from: int,
		deg: float, lat: float, frames: int) -> Dictionary:
	Settings.drive_relative = true
	_pose(p, a, x, y_from, deg_to_rad(deg), lat)
	var rig: CameraRig = main.rig
	var wall := Arena.cell_center(x, yw)
	rig.aim_yaw = PI
	rig.yaw = PI
	rig.aim_pitch = 0.0
	main.spawn_queue.clear()
	main.max_active = 0
	main.state = "play"
	main.state_timer = 1e9
	p.set_physics_process(false)
	Input.action_press("move_forward")

	var low := INF
	var through := -1
	var stall := 0
	var lat_min := INF
	var lat_max := -INF
	var prev_z := p.global_position.z
	var trace := PackedFloat32Array()
	for i in frames:
		await get_tree().physics_frame
		# 准星压在门后那条路上：门中线上车前 LOOKAHEAD 米的一点，进门前钉在墙面上
		var aim_pt := Vector3(wall.x, 0.0, maxf(p.global_position.z + LOOKAHEAD, wall.z))
		var d := aim_pt - p.global_position
		rig.aim_yaw = atan2(-d.x, -d.z)
		p.tick(STEP)
		var now := p.global_position
		if i >= WARM:
			low = minf(low, p.speed())
			# 油门压到底却既不前进也不收敛 = 真的卡住了，不是"慢"
			if p.speed() < 3.0 and now.z - prev_z < 0.02:
				stall += 1
		prev_z = now.z
		lat_min = minf(lat_min, now.x - wall.x)
		lat_max = maxf(lat_max, now.x - wall.x)
		if through < 0 and now.z > wall.z + 4.0:
			through = i
		trace.append(p.speed())
	Input.action_release("move_forward")
	var out := PackedStringArray()
	for i in range(WARM, trace.size(), 30):
		out.append("%.1fs:%.1f" % [float(i - WARM) * STEP, trace[i]])
	return {
		"low": low, "through": -1 if through < 0 else through - WARM,
		"lat": maxf(lat_max - lat_min, 0.0), "stall": stall,
		"end": p.speed(), "trace": " ".join(out), "clear": p._spine_clear(),
	}


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	var p: Player = main.player
	main.set_process(false)
	main.state = "ready"
	main.state_timer = 1e9
	p.shield_t = 0.0
	p.set_physics_process(false)

	var x := 12
	var yw := 10
	_build_gap(a, x, yw)
	# 让 queue_free 的旧掩体真正离场
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("PROBE gate freeWidth=%.1f hullWidth=%.1f clearance=%.2f cruise=%.1f" % [
		Arena.CELL, p.body_radius * 2.0, (Arena.CELL - p.body_radius * 2.0) * 0.5,
		p.move_speed])

	# lat 覆盖"门口单侧余量之内"（±0.45）与"已经偏出门框"（±1.5 / ±3）两种情况；
	# ang 覆盖对正（0）与车头歪着进（±15）
	var ok := 0
	var total := 0
	var worst_low := INF
	for lat in [-3.0, -1.5, -0.9, -0.45, 0.0, 0.45, 0.9, 1.5, 3.0]:
		for deg in [-15.0, -10.0, -5.0, 0.0, 5.0, 10.0, 15.0]:
			var r := await _door(main, p, a, x, yw, 4, deg, lat, 420)
			total += 1
			worst_low = minf(worst_low, r["low"])
			var passed: bool = r["through"] >= 0 and r["stall"] < 30
			if passed:
				ok += 1
			print("PROBE gate lat=%+.2f ang=%+4.0f low=%5.1f pass=%5s stall=%3d latDrift=%.2f end=%5.1f clear=%s" % [
				lat, deg, r["low"], ("%d" % r["through"]) if passed else "FAIL",
				r["stall"], r["lat"], r["end"], str(r["clear"])])
			if not passed:
				print("PROBE gate lat=%+.2f ang=%+4.0f trace %s" % [lat, deg, r["trace"]])
	print("PROBE gate TOTAL passed=%d/%d worstLow=%.1f" % [ok, total, worst_low])

	# ---- 单格宽走廊接单格宽门口：三种进入角度 ----
	_build_corridor_and_gap(a, x, yw)
	await get_tree().physics_frame
	await get_tree().physics_frame
	ok = 0
	total = 0
	for lat in [-0.45, 0.0, 0.45]:
		for deg in [-12.0, 0.0, 12.0]:
			var r2 := await _door(main, p, a, x, yw, 4, deg, lat, 420)
			total += 1
			var passed: bool = r2["through"] >= 0 and r2["stall"] < 30
			if passed:
				ok += 1
			print("PROBE chain lat=%+.2f ang=%+4.0f low=%5.1f pass=%5s stall=%3d end=%5.1f clear=%s" % [
				lat, deg, r2["low"], ("%d" % r2["through"]) if passed else "FAIL",
				r2["stall"], r2["end"], str(r2["clear"])])
			if not passed:
				print("PROBE chain lat=%+.2f ang=%+4.0f trace %s" % [lat, deg, r2["trace"]])
	print("PROBE chain TOTAL passed=%d/%d" % [ok, total])
	get_tree().quit(0)
