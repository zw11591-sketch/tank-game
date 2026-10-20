extends Node
## 临时诊断：窄通道里"按住某个方向"时，车体控制器到底做了什么。
##
## 与 squeeze/wedge 的区别：这里把 main 的 **两套** 处理都关掉
## （set_process + set_physics_process），并把 drive 拆成
## "只算 _relative_drive 的意图 + 只跑 drive 的物理"，于是
##   * 不会被补给/刷兵/状态机污染，
##   * 量到的每一个数都只反映控制器与几何。
##
## 关注的是：在单格宽走廊里推方向，车会不会**停下**（玩家读作"卡住"）。
## 逐帧打印 speed / 横向位置 / 车头偏角 / 是否被几何挡住 / 接触面数。
##
## 用法：godot --headless --path <proj> res://tools/NarrowProbe.tscn

const STEP := 1.0 / 120.0
const WARM := 150
## 只跑 T 形路口那一段：调这一处时不必等前面二十条用例跑完
const TEE_ONLY := false

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
	# 这里刻意不 _rebuild_all()：调用方紧接着还要改格子，而 _spawn_block() 不查重，
	# 同一格被重建两次就留下两个实体。被清成 EMPTY 的那几格旧墙因此留在场上——
	# 单格宽 T 形路口的横向通道口正是这种格，于是路口被两堵幽灵墙封死，
	# 车永远过不去（实测卡在 v=0.8 / out=-1）。整张网格写完只重建一次。


## 一条纵向单格宽走廊：x 两侧砌墙，两端留开阔地
func _build_corridor(a: Arena, x: int, y0: int, y1: int) -> void:
	_clear_all(a)
	for y in range(y0, y1 + 1):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	a._rebuild_all()


## 单格宽 T 形路口：纵向走廊 x 从 y0 到 y1，横向走廊在第 yc 行横穿。
## 整张网格一次写好再重建（见 _clear_all 的说明）。
func _build_tee(a: Arena, x: int, y0: int, y1: int, yc: int) -> void:
	_clear_all(a)
	for y in range(y0, y1 + 1):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
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


func _pose(p: Player, a: Arena, x: int, y: int, yaw_off: float, lat: float) -> void:
	p.global_position = Arena.cell_center(x, y) + Vector3(lat, 0.0, 0.0)
	p.rotation.y = PI + yaw_off
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	p.hp = 1_000_000
	p.turn_blocked = false
	if p.turret != null:
		p.turret.rotation.y = 0.0


## 一条用例：车头偏 yaw_off 度、横向偏 lat 米摆好，准星固定在
## 世界航向 PI + aim_deg（不动），按住 fwd/right，跑 frames 帧。
##
## aim_deg 是"玩家把准星摆在哪"——镜头相对驾驶里它就是目的地方向，
## 所以 aim_deg 偏离走廊轴 = 玩家想把车开向侧向。
func _case(main: Node, p: Player, a: Arena, x: int, y: int, yaw_off: float,
		lat: float, aim_deg: float, fwd: float, right: float, frames: int) -> Dictionary:
	_pose(p, a, x, y, deg_to_rad(yaw_off), lat)
	var rig: CameraRig = main.rig
	rig.aim_yaw = wrapf(PI + deg_to_rad(aim_deg), -PI, PI)
	rig.yaw = PI
	rig.aim_pitch = 0.0
	var axis := Arena.cell_center(x, y).x
	var low := INF
	var low_at := -1
	var blocked := 0
	var contact := 0
	var yaw_max := 0.0
	var lat_min := INF
	var lat_max := -INF
	var still := 0
	var trace := PackedStringArray()
	var prev := p.global_position
	for i in frames:
		await get_tree().physics_frame
		var cmd := p._relative_drive(fwd, right)
		p.drive(cmd.x, cmd.y, STEP)
		var now := p.global_position
		var sp := p.speed()
		if i >= WARM:
			if sp < low:
				low = sp
				low_at = i - WARM
			if p.turn_blocked:
				blocked += 1
			if p.get_slide_collision_count() > 0:
				contact += 1
			if now.distance_to(prev) < 0.01:
				still += 1
			yaw_max = maxf(yaw_max, absf(angle_difference(p.rotation.y, PI)))
			lat_min = minf(lat_min, now.x - axis)
			lat_max = maxf(lat_max, now.x - axis)
		prev = now
		if i >= WARM and (i - WARM) % 12 == 0:
			trace.append("%d/v%.1f/lat%+.2f/%+.0f/T%d" % [
				i - WARM, sp, now.x - axis,
				rad_to_deg(angle_difference(p.rotation.y, PI)),
				1 if p.turn_blocked else 0])
	return {
		"low": low, "lowAt": low_at, "blocked": blocked, "contact": contact,
		"yawMax": rad_to_deg(yaw_max), "still": still, "trace": " ".join(trace),
		"latMin": lat_min, "latMax": lat_max, "end": p.speed(),
		"clear": p._spine_clear(),
	}


func _row(tag: String, r: Dictionary) -> void:
	print("PROBE %-16s low=%5.1f at=%3d still=%3d blocked=%3d contact=%3d yawMax=%5.1f lat=[%+.2f,%+.2f] end=%5.1f clear=%s" % [
		tag, r["low"], r["lowAt"], r["still"], r["blocked"], r["contact"],
		r["yawMax"], r["latMin"], r["latMax"], r["end"], str(r["clear"])])
	print("PROBE %-16s trace %s" % [tag, r["trace"]])


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	var p: Player = main.player
	# main 的 _process 管状态机，_physics_process 管坦克互推与炮弹——
	# 两个都关掉，量到的东西才只属于控制器
	main.set_process(false)
	main.set_physics_process(false)
	main.state = "ready"
	main.state_timer = 1e9
	p.shield_t = 0.0
	p.set_physics_process(false)
	Settings.drive_relative = true

	var x := 12
	_build_corridor(a, x, 4, 20)
	await get_tree().physics_frame
	await get_tree().physics_frame
	print("PROBE narrow freeWidth=%.1f hullWidth=%.1f clearance=%.2f cruise=%.1f" % [
		Arena.CELL, p.body_radius * 2.0, (Arena.CELL - p.body_radius * 2.0) * 0.5,
		p.move_speed])

	# ---- 基准：准星对正走廊轴，按住 W ----
	if TEE_ONLY:
		_build_tee(a, x, 4, 20, 14)
		await get_tree().physics_frame
		await get_tree().physics_frame
		for turn_deg in [-90.0]:
			for lead in [8.0, 14.0, 20.0]:
				for sweep in [0.3]:
					_tee_row("tee t%+4.0f l%2.0f s%.1f" % [turn_deg, lead, sweep],
						await _tee(main, p, a, x, 14, turn_deg, lead, sweep, 620))
		get_tree().quit(0)
	_row("hold aim0", await _case(main, p, a, x, 5, 0.0, 0.0, 0.0, 1.0, 0.0, 300))
	# ---- 准星摆到侧向：玩家在走廊里想把车开到左边/右边 ----
	for aim in [-90.0, -60.0, -45.0, -25.0, 25.0, 45.0, 60.0, 90.0]:
		_row("aim%+4.0f" % aim, await _case(main, p, a, x, 5, 0.0, 0.0, aim, 1.0, 0.0, 300))
	# ---- 只按 A/D（fwd=0）：镜头相对驾驶把它译成 aim ∓90° ----
	_row("pureLeft", await _case(main, p, a, x, 5, 0.0, 0.0, 0.0, 0.0, -1.0, 300))
	_row("pureRight", await _case(main, p, a, x, 5, 0.0, 0.0, 0.0, 0.0, 1.0, 300))
	# ---- 斜着进走廊：准星对正、车头偏 ----
	for deg in [15.0, 25.0, 35.0]:
		_row("enter%+3.0f" % deg, await _case(main, p, a, x, 5, deg, 0.0, 0.0, 1.0, 0.0, 300))
	# ---- 偏着进走廊 ----
	for lat in [-0.4, 0.4]:
		_row("off%+.2f" % lat, await _case(main, p, a, x, 5, 0.0, lat, 0.0, 1.0, 0.0, 300))

	# ---- 单格宽 T 形路口：走到路口再把准星转向横向通道 ----
	_build_tee(a, x, 4, 20, 14)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for turn_deg in [-90.0, 90.0]:
		for lead in [4.0, 8.0, 14.0]:
			for sweep in [0.3, 0.8]:
				_tee_row("tee t%+4.0f l%2.0f s%.1f" % [turn_deg, lead, sweep],
					await _tee(main, p, a, x, 14, turn_deg, lead, sweep, 620))
	get_tree().quit(0)


## 单格宽 T 形路口过 90° 弯：走到距路口 lead 米处开始把准星扫向横向通道
## （sweep 秒内扫完 90°），之后保持不动。玩家在镜头相对驾驶下唯一会做的事。
##
## turn_deg 决定拐向：-90 走 +x，+90 走 -x。
## 量的是"能不能出去"（横向位移 8 米）与过程中掉到多慢。
func _tee(main: Node, p: Player, a: Arena, x: int, yc: int, turn_deg: float,
		lead: float, sweep: float, frames: int) -> Dictionary:
	var corner := Arena.cell_center(x, yc)
	var rig: CameraRig = main.rig
	_pose(p, a, x, yc - 9, 0.0, 0.0)
	rig.yaw = PI
	rig.aim_yaw = PI
	rig.aim_pitch = 0.0
	# turn_deg<0 时准星转向 PI-90°（世界 -x），>0 则转向 +x。
	# 这里原来取反了，于是"车明明已经拐进横向通道、以 15 m/s 跑出去"仍记成 out=-1。
	var exit_pos := -1.0 if turn_deg < 0.0 else 1.0
	var sweep_f := maxi(int(sweep / STEP), 1)
	var turn_at := -1
	var low := INF
	var got_out := -1
	var rub := 0
	var yaw_max := 0.0
	var diag := PackedStringArray()
	var prev := p.global_position
	for i in frames:
		await get_tree().physics_frame
		if turn_at < 0 and p.global_position.z > corner.z - lead:
			turn_at = i
		if turn_at >= 0:
			var k := clampf(float(i - turn_at) / float(sweep_f), 0.0, 1.0)
			rig.aim_yaw = wrapf(PI + deg_to_rad(turn_deg) * k, -PI, PI)
		var cmd := p._relative_drive(1.0, 0.0)
		p.drive(cmd.x, cmd.y, STEP)
		var now := p.global_position
		if i >= WARM:
			low = minf(low, p.speed())
			yaw_max = maxf(yaw_max, absf(angle_difference(p.rotation.y, PI)))
			for k2 in p.get_slide_collision_count():
				var n := p.get_slide_collision(k2).get_normal()
				if Vector3(n.x, 0.0, n.z).length_squared() > 0.001:
					rub += 1
					break
			if got_out < 0 and (now.x - corner.x) * exit_pos > 8.0:
				got_out = i - WARM
			if (i - WARM) % 24 == 0:
				var ns := PackedStringArray()
				for k3 in p.get_slide_collision_count():
					var n3 := p.get_slide_collision(k3).get_normal()
					ns.append("(%.2f,%.2f,%.2f)" % [n3.x, n3.y, n3.z])
				diag.append("%d/x%+.2f/z%+.2f/v%.1f/y%+.0f/T%d/th%.2f/st%+.2f/w%d/%s/d%.2f/g%s" % [
					i - WARM, now.x - corner.x, now.z - corner.z, p.speed(),
					rad_to_deg(angle_difference(p.rotation.y, PI)),
					1 if p.turn_blocked else 0, cmd.x, cmd.y,
					p.get_slide_collision_count(), "".join(ns),
					p._depen_offset().length(), "1" if p._spine_clear() else "0"])
		prev = now
		if got_out >= 0:
			break
	return {"low": low, "out": got_out, "rub": rub, "yawMax": rad_to_deg(yaw_max),
		"diag": " ".join(diag), "end": p.speed(), "clear": p._spine_clear()}


func _tee_row(tag: String, r: Dictionary) -> void:
	print("PROBE %-18s low=%5.1f out=%3d rub=%3d yawMax=%5.1f end=%5.1f clear=%s" % [
		tag, r["low"], r["out"], r["rub"], r["yawMax"], r["end"], str(r["clear"])])
	print("PROBE %-18s diag %s" % [tag, r["diag"]])
