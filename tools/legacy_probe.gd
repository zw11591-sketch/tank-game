extends Node
## 临时诊断：**传统履带转向**（Settings.drive_relative = false）在单格宽通道里的手感。
##
## 为什么单独开一个：corridor / squeeze / wedge / pass 这几个探针全部先写死
## Settings.drive_relative = true，量的是"镜头相对驾驶"（车体自己朝准星对齐）。
## 而 user://settings.cfg 里 drive_relative 是可以被玩家关掉的，关掉之后走的是
## 传统履带转向：W/S 沿车头轴、A/D 原地左右转车。这条路径**一个探针都没覆盖**。
##
## 传统转向下"不顺畅"的来源与镜头相对驾驶完全不同，所以量的量也不同：
##   lane    —— 只按 W 沿单格走廊直行：能否守住中线
##   wiggle  —— 边走边小幅修正航向（玩家在走廊里的常规动作）：
##              每一次修正的代价有多大
##   pivot   —— 停在走廊里按住 A/D：车体到底能转多少度
##   bent    —— 单格宽 T 形路口按 W+D 拐进横向通道：能不能拐、磨多久
##   denied  —— 每个用例都顺带统计"玩家给了舵、车体却一度没转"的连续帧数峰值。
##              转向被整段否决才会出现，这是"手感一顿一顿"最直接的量。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --headless --path <proj> res://tools/LegacyProbe.tscn

const STEP := 1.0 / 120.0
const WARM := 150
## 单帧位移小于此值即视为"这一帧没有移动"（120Hz 下 15 m/s 是 0.125 米/帧）
const STILL_STEP := 0.012
const X := 12
const Y0 := 4
const Y1 := 22

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	Settings.drive_relative = false
	var main := get_node("Main")
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _main() -> Node:
	return get_node("Main")


func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 60 and not _started:
		_started = true
		_run()


# ---------------- 试车台 ----------------

func _clear_all(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	a._rebuild_all()


## 纵向单格走廊：x 两侧砌墙
func _build_corridor(a: Arena, x: int, y0: int, y1: int) -> void:
	_clear_all(a)
	for y in range(y0, y1 + 1):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	a._rebuild_all()


## 单格宽 T 形路口：纵向走廊在第 yc 行被横向通道横穿
func _build_bent(a: Arena, x: int, y0: int, y1: int, yc: int) -> void:
	_clear_all(a)
	for y in range(y0, y1 + 1):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	for y in range(maxi(y0 - 2, 1), mini(y1 + 3, Arena.GRID_H - 1)):
		a.grid[y][x] = Arena.EMPTY
	a.grid[y0 - 2][x] = Arena.BRICK
	for xx in range(2, Arena.GRID_W - 2):
		a.grid[yc][xx] = Arena.EMPTY
		a.grid[yc - 1][xx] = Arena.BRICK
		a.grid[yc + 1][xx] = Arena.BRICK
	a.grid[yc][2] = Arena.BRICK
	a.grid[yc][Arena.GRID_W - 3] = Arena.BRICK
	a.grid[yc][x] = Arena.EMPTY
	a.grid[yc - 1][x] = Arena.EMPTY
	a.grid[yc + 1][x] = Arena.EMPTY
	a._rebuild_all()


## 摆车：yaw = PI 即车头朝 +Z
func _pose(main: Node, p: Player, a: Arena, x: int, y: int, yaw_off: float) -> void:
	p.global_position = Arena.cell_center(x, y)
	p.rotation.y = PI + yaw_off
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	p.hp = 1_000_000
	p.turn_blocked = false
	if p.turret != null:
		p.turret.rotation.y = 0.0
	var rig: CameraRig = main.rig
	rig.yaw = PI
	rig.aim_yaw = PI
	rig.aim_pitch = 0.0
	main.spawn_queue.clear()
	main.max_active = 0
	main.state = "play"
	main.state_timer = 1e9
	p.set_physics_process(false)


# ---------------- 统计 ----------------

## 逐帧统计器。denied = 玩家给了舵、车体却一度没转的帧数。
class Meter:
	var low := INF
	var still := 0
	var rub := 0
	var denied := 0
	var yaw_max := 0.0
	var denied_run := 0
	var denied_run_max := 0
	var _prev_yaw := 0.0

	func tick_frame(p: Player, steer_in: float, from: int, i: int) -> void:
		var v := p.speed()
		var dyaw := absf(p.rotation.y - _prev_yaw)
		_prev_yaw = p.rotation.y
		if i < from:
			return
		low = minf(low, v)
		yaw_max = maxf(yaw_max, absf(angle_difference(p.rotation.y, PI)))
		if absf(steer_in) > 0.1 and dyaw < 1e-5:
			denied += 1
			denied_run += 1
			denied_run_max = maxi(denied_run_max, denied_run)
		else:
			denied_run = 0
		for c in p.get_slide_collision_count():
			var n := p.get_slide_collision(c).get_normal()
			if Vector3(n.x, 0.0, n.z).length_squared() > 0.001:
				rub += 1
				break


func _row(tag: String, m: Meter, extra: String) -> void:
	print("PROBE %-18s low=%5.1f still=%4d rub=%4d denied=%4d run=%3d yawMax=%5.1fdeg %s" % [
		tag, m.low, m.still, m.rub, m.denied, m.denied_run_max,
		rad_to_deg(m.yaw_max), extra])


# ---------------- 用例 ----------------

## 只按 W 沿单格走廊直行
func _lane(main: Node, p: Player, a: Arena, yaw_off: float, frames: int) -> Meter:
	_build_corridor(a, X, Y0, Y1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_pose(main, p, a, X, Y0 + 1, yaw_off)
	var axis := Arena.cell_center(X, Y0 + 1).x
	var m := Meter.new()
	m._prev_yaw = p.rotation.y
	var lat_min := INF
	var lat_max := -INF
	var prev := p.global_position
	Input.action_press("move_forward")
	for i in frames:
		await get_tree().physics_frame
		p.tick(STEP)
		m.tick_frame(p, 0.0, WARM, i)
		var lat: float = p.global_position.x - axis
		if i >= WARM:
			lat_min = minf(lat_min, lat)
			lat_max = maxf(lat_max, lat)
			if p.global_position.distance_to(prev) < STILL_STEP:
				m.still += 1
		prev = p.global_position
	Input.action_release("move_forward")
	print("PROBE %-18s lat=[%+.2f,%+.2f] end=%5.1f clear=%s" % [
		"  lane-lat", lat_min, lat_max, p.speed(), str(p._spine_clear())])
	return m


## 边走边小幅修正航向：0.15s 一边，交替 A / D。这是玩家在走廊里的常规动作。
func _wiggle(main: Node, p: Player, a: Arena, frames: int) -> Meter:
	_build_corridor(a, X, Y0, Y1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_pose(main, p, a, X, Y0 + 1, 0.0)
	var m := Meter.new()
	m._prev_yaw = p.rotation.y
	var hold := int(0.15 / STEP)
	Input.action_press("move_forward")
	for i in frames:
		await get_tree().physics_frame
		var steer_in := 0.0
		if i >= WARM:
			var phase := ((i - WARM) / hold) % 2
			steer_in = 1.0 if phase == 0 else -1.0
			if phase == 0:
				Input.action_press("turn_right")
				Input.action_release("turn_left")
			else:
				Input.action_press("turn_left")
				Input.action_release("turn_right")
		p.tick(STEP)
		m.tick_frame(p, steer_in, WARM, i)
	Input.action_release("move_forward")
	Input.action_release("turn_left")
	Input.action_release("turn_right")
	return m


## 停在走廊里按住 A：车体到底能转多少度
func _pivot(main: Node, p: Player, a: Arena, key: String, frames: int) -> Meter:
	_build_corridor(a, X, Y0, Y1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_pose(main, p, a, X, Y0 + 4, 0.0)
	var m := Meter.new()
	m._prev_yaw = p.rotation.y
	var axis := Arena.cell_center(X, Y0 + 4).x
	var lat_min := INF
	var lat_max := -INF
	Input.action_press(key)
	for i in frames:
		await get_tree().physics_frame
		p.tick(STEP)
		m.tick_frame(p, 1.0, WARM, i)
		var lat: float = p.global_position.x - axis
		if i >= WARM:
			lat_min = minf(lat_min, lat)
			lat_max = maxf(lat_max, lat)
	Input.action_release(key)
	print("PROBE %-18s lat=[%+.2f,%+.2f] end=%5.1f clear=%s" % [
		"  pivot-lat", lat_min, lat_max, p.speed(), str(p._spine_clear())])
	return m


## 单格宽 T 形路口：按 W 开过去，到路口改按 W+D 拐进横向通道
func _bent(main: Node, p: Player, a: Arena, lead: float, frames: int) -> Array:
	var yc := 14
	_build_bent(a, X, Y0, Y1, yc)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_pose(main, p, a, X, Y0 + 1, 0.0)
	var m := Meter.new()
	m._prev_yaw = p.rotation.y
	var corner := Arena.cell_center(X, yc)
	var out := -1
	var turn_at := -1
	Input.action_press("move_forward")
	for i in frames:
		await get_tree().physics_frame
		if turn_at < 0 and p.global_position.z > corner.z - lead:
			turn_at = i
			Input.action_press("turn_right")
		p.tick(STEP)
		m.tick_frame(p, 1.0 if turn_at >= 0 else 0.0, WARM, i)
		if out < 0 and p.global_position.x < corner.x - 8.0:
			out = i - WARM
			break
	Input.action_release("move_forward")
	Input.action_release("turn_right")
	var extra := "turnAt=%d out=%d end=%5.1f clear=%s" % [
		turn_at - WARM, out, p.speed(), str(p._spine_clear())]
	return [m, extra]


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	var p: Player = main.player
	main.set_process(false)
	main.state = "ready"
	main.state_timer = 1e9
	p.shield_t = 0.0
	p.set_physics_process(false)
	print("PROBE legacy drive_relative=%s cruise=%.1f cell=%.1f hull=%.1f clearance=%.2f" % [
		str(Settings.drive_relative), p.move_speed, Arena.CELL, p.body_radius * 2.0,
		(Arena.CELL - p.body_radius * 2.0) * 0.5])

	_row("lane     0deg", await _lane(main, p, a, 0.0, 560), "")
	_row("lane  +12deg", await _lane(main, p, a, deg_to_rad(12.0), 560), "")
	_row("wiggle", await _wiggle(main, p, a, 560), "")
	_row("pivot turn_left", await _pivot(main, p, a, "turn_left", 420), "")
	_row("pivot turn_right", await _pivot(main, p, a, "turn_right", 420), "")
	for lead in [6.0, 10.0]:
		var r: Array = await _bent(main, p, a, lead, 900)
		_row("bent lead=%4.1fm" % lead, r[0], r[1])
	get_tree().quit(0)
