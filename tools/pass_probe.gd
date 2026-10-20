extends Node
## 临时诊断：一格宽门口（整排墙上只留一格）为什么"偏着开就进不去"。
##
## squeeze_probe 的 gapRel 用例只报到"没穿过去 + 卡在 0.8 m/s"，看不出是
## 控制器没在修正航向，还是几何把车别住了。这里逐帧打印控制器的中间量：
##   e   = angle_difference(车头, 准星方向)，单位度。它就是 _relative_drive 的输入误差
##   a   = rig.aim_yaw（准星世界朝向，相对 PI）。若它自己漂向车头，就是自洽回路
##   c   = rig.yaw（镜头朝向，相对 PI）
##   th/st = 控制器给出的油门与舵
##   T   = turn_blocked（这一帧转向被几何否掉）
##   d   = 网格硬约束想推出的位移长度
##
## 用法：godot --path <proj> res://tools/PassProbe.tscn

const STEP := 1.0 / 120.0
const WARM := 150

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _main() -> Node:
	return get_node("Main")


func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 150 and not _started:
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


func _deg(a: float, b: float) -> float:
	return rad_to_deg(angle_difference(a, b))


## 偏 lat 米、车头偏 ang 度起步，镜头瞄门口中心，按住 W 走 frames 帧。
## 逐帧打印控制器中间量。
func _run_case(main: Node, p: Player, a: Arena, x: int, yw: int, y_from: int,
		lat: float, ang: float, frames: int, every: int, use_tick: bool) -> void:
	var wall := Arena.cell_center(x, yw)
	var dist := float(yw - y_from) * Arena.CELL
	var cam := wrapf(PI - atan2(lat, dist), -PI, PI)
	Settings.drive_relative = true
	main.spawn_queue.clear()
	main.max_active = 0
	main.state = "play"
	main.state_timer = 1e9
	p.global_position = Arena.cell_center(x, y_from) + Vector3(lat, 0.0, 0.0)
	p.rotation.y = PI + deg_to_rad(ang)
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	p.hp = 1_000_000
	p.turn_blocked = false
	p.set_physics_process(false)
	var rig: CameraRig = main.rig
	rig.yaw = cam
	rig.aim_yaw = cam
	rig.aim_pitch = 0.0

	Input.action_press("move_forward")
	print("PROBE case off=%+.2f ang=%+3.0f cam=%+5.1f mouse=%d tick=%s" % [
		lat, ang, _deg(cam, PI), Input.mouse_mode, str(use_tick)])
	var low := INF
	var through := -1
	for i in frames:
		await get_tree().physics_frame
		var cmd := p._relative_drive(1.0, 0.0)
		if use_tick:
			p.tick(STEP)
		else:
			p.drive(cmd.x, cmd.y, STEP)
		var now := p.global_position
		var err := _deg(p.rotation.y, rig.aim_yaw)
		low = minf(low, p.speed())
		if through < 0 and now.z > wall.z + 4.0:
			through = i
		if i % every == 0:
			print("PROBE  %3d x%+.2f z%+.2f y%+5.1f e%+6.1f a%+6.1f c%+6.1f th%.2f st%+.2f T%d v%4.1f c%d d%.2f" % [
				i, now.x - wall.x, now.z - wall.z, _deg(p.rotation.y, PI), err,
				_deg(rig.aim_yaw, PI), _deg(rig.yaw, PI), cmd.x, cmd.y,
				1 if p.turn_blocked else 0, p.speed(),
				p.get_slide_collision_count(), p._depen_offset().length()])
	Input.action_release("move_forward")
	print("PROBE case low=%5.1f through=%3d end=%5.1f clear=%s" % [
		low, through, p.speed(), str(p._spine_clear())])


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
	await get_tree().physics_frame
	await get_tree().physics_frame
	print("PROBE gap x=%d yw=%d freeWidth=%.1f hullWidth=%.1f clearance=%.2f cruise=%.1f" % [
		x, yw, Arena.CELL, p.body_radius * 2.0,
		(Arena.CELL - p.body_radius * 2.0) * 0.5, p.move_speed])

	# 基准：正着开（对照，能过）
	await _run_case(main, p, a, x, yw, 4, 0.0, 0.0, 420, 24, false)
	# 车头偏 10°：squeeze_probe 里过不去的工况
	await _run_case(main, p, a, x, yw, 4, 0.0, 10.0, 600, 12, false)
	# 同一条用例，但走 Player.tick()（引擎侧完整链路）——squeeze_probe 就是这么跑的
	await _run_case(main, p, a, x, yw, 4, 0.0, 10.0, 600, 12, true)
	get_tree().quit(0)
