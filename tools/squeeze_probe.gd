extends Node
## 临时验收：窄通道里"玩家真正会做"的几件事，corridor_probe 没有覆盖。
##
##   corner —— 巡航中打满一舵（走廊里拐弯），再回正：掉多少速、多久恢复
##   bent   —— 单格宽走廊里过 90° 直角弯：真实输入链路（镜头相对驾驶 + 按住 W），
##             玩家只是把镜头转向侧向通道。能不能一把过去、掉多少速
##   pivot  —— 单格宽走廊里只按 A/D（镜头相对驾驶把它译成"朝画面左右开"）：
##             车会不会直接顶到侧墙上
##   swing  —— 边走边左右扫准星：镜头被准星拖走时车体会不会跟着歪
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --path <proj> res://tools/SqueezeProbe.tscn

const STEP := 1.0 / 120.0
const WARM := 150
## 只跑"1 格宽门口"那一段。调这一处手感时不必等前面七千多帧跑完。
const GAP_ONLY := true
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


## 清出一整条 17 格宽的空带；试车台长度必须够跑满整个测量窗口，
## 否则量到的低谷其实是"撞上了地图边界"（第一版就是这么被污染的）。
func _clear_all(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	a._rebuild_all()


## 纵向单格走廊：x 两侧砌墙，从 y=4 一直砌到 y=20
func _build_corridor(a: Arena, x: int, y0: int, y1: int) -> void:
	_clear_all(a)
	for y in range(y0, y1 + 1):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	a._rebuild_all()


## 单格宽 T 形通道：纵向走廊 x 列从 y0 到 y1，横向走廊在第 yc 行横穿。
## 车沿 +Z 开，到路口要拐进横向通道——这是"狭窄的障碍物通道"里最典型的一幕。
func _build_bent(a: Arena, x: int, y0: int, y1: int, yc: int) -> void:
	_clear_all(a)
	# 纵向走廊：x 两侧砌墙，两端封口
	for y in range(y0, y1 + 1):
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	for y in range(y0 - 2, y1 + 3):
		a.grid[y][x] = Arena.EMPTY
	a.grid[y0 - 2][x] = Arena.BRICK
	# 横向通道：第 yc 行横穿，两侧砌墙，两端封口
	for xx in range(2, Arena.GRID_W - 2):
		a.grid[yc][xx] = Arena.EMPTY
		a.grid[yc - 1][xx] = Arena.BRICK
		a.grid[yc + 1][xx] = Arena.BRICK
	a.grid[yc][2] = Arena.BRICK
	a.grid[yc][Arena.GRID_W - 3] = Arena.BRICK
	# 路口那一格必须通：十字口四向都是空的
	a.grid[yc][x] = Arena.EMPTY
	a.grid[yc - 1][x] = Arena.EMPTY
	a.grid[yc + 1][x] = Arena.EMPTY
	a._rebuild_all()


func _pose(p: Player, a: Arena, x: int, y: int, yaw_off: float) -> void:
	p.global_position = Arena.cell_center(x, y)
	p.rotation.y = PI + yaw_off
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	p.hp = 1_000_000
	if p.turret != null:
		p.turret.rotation.y = 0.0


func _lines(v: PackedFloat32Array, from: int, step: int) -> String:
	var out := PackedStringArray()
	for i in range(from, v.size(), step):
		out.append("%.1fs:%.1f" % [float(i) * STEP, v[i]])
	return " ".join(out)


# ---------------- corner：巡航中打满一舵 ----------------

func _corner(p: Player, a: Arena, ch: Dictionary, steer: float, on_s: float,
		off_s: float, frames: int) -> Dictionary:
	_pose(p, a, ch.x, ch.y0, 0.0)
	var cruise := p.move_speed
	var on_f := int(on_s / STEP)
	var off_f := int(off_s / STEP)
	var trace := PackedFloat32Array()
	var yaw_max := 0.0
	var lat_min := INF
	var lat_max := -INF
	var low := INF
	var recover := -1
	var axis := Arena.cell_center(ch.x, ch.y0).x
	var turn_end := WARM + on_f + off_f
	for i in frames:
		await get_tree().physics_frame
		var s := 0.0
		if i >= WARM and i < WARM + on_f:
			s = steer
		elif i >= WARM + on_f and i < turn_end:
			s = -steer
		p.drive(1.0, s, STEP)
		var lat: float = p.global_position.x - axis
		var dyaw := rad_to_deg(angle_difference(p.rotation.y, PI))
		trace.append(p.speed())
		if i >= WARM and i < turn_end + 180:
			yaw_max = maxf(yaw_max, absf(dyaw))
			lat_min = minf(lat_min, lat)
			lat_max = maxf(lat_max, lat)
			low = minf(low, p.speed())
			if i > turn_end and recover < 0 and p.speed() > cruise * 0.98:
				recover = i - turn_end
	return {
		"low": low, "recover": recover, "yawMax": yaw_max, "lat": lat_max - lat_min,
		"end": p.speed(), "clear": p._spine_clear(),
		"trace": _lines(trace, WARM, 24),
	}


# ---------------- bent / pivot / swing：真实输入链路 ----------------

func _input_start(main: Node, p: Player, a: Arena, x: int, y: int, yaw_off: float) -> void:
	_pose(p, a, x, y, yaw_off)
	var rig: CameraRig = main.rig
	rig.yaw = PI
	rig.aim_yaw = PI
	rig.aim_pitch = 0.0
	main.spawn_queue.clear()
	main.max_active = 0
	main.state = "play"
	main.state_timer = 1e9
	p.set_physics_process(false)


## 一道 1 格宽的"门口"：一整排砖墙上只留 x 那一格通。车正对门口开过去。
## 这是"狭窄的障碍物通道"最直白的样子——两侧是砖块，中间一条缝。
func _build_gap(a: Arena, x: int, yw: int) -> void:
	_clear_all(a)
	for xx in range(2, Arena.GRID_W - 2):
		a.grid[yw][xx] = Arena.BRICK
	a.grid[yw][x] = Arena.EMPTY
	a._rebuild_all()


## 正对门口开过去。量的是**实际位移**而不是指令速度：
## 撞上门口那块砖的棱角时 _speed 仍然是 15（它只是"指令"），
## 只有逐帧位移能看出车是不是真的被卡住了。
##
## relative=true 走真实输入链路（镜头相对驾驶 + 按住 W，镜头瞄在门口中线上），
## 也就是玩家实际会做的事：车体自己朝镜头对齐。relative=false 是"锁死车头方向
## 一条直线开过去"——那是压力测试而不是玩法：车头偏 8°、助跑 24 米会横漂 3.4 米，
## 比门口的半宽容差（0.5 米）大一个量级，撞不上门口是必然的，不能读成"卡死"。
func _gap(main: Node, p: Player, a: Arena, x: int, yw: int, y_from: int,
		yaw_off: float, lat: float, frames: int, relative := false,
		cam_yaw := PI) -> Dictionary:
	if relative:
		Settings.drive_relative = true
		_input_start(main, p, a, x, y_from, yaw_off)
		Input.action_press("move_forward")
		p.global_position += Vector3(lat, 0.0, 0.0)
		p._safe_pos = p.global_position
		# 镜头不是简单地对正前方，而是**瞄着门口中心**——玩家看到自己偏在门口一侧时
		# 会做的事就是这一件。于是这条测的是"偏着进、车体自己摆正、能不能穿过去"，
		# 而不是"偏着进、一路偏到底"。
		var rig: CameraRig = main.rig
		rig.yaw = cam_yaw
		rig.aim_yaw = cam_yaw
	else:
		_pose(p, a, x, y_from, yaw_off)
		p.global_position += Vector3(lat, 0.0, 0.0)
		p._safe_pos = p.global_position
	var wall := Arena.cell_center(x, yw)
	var prev := p.global_position
	var min_step := INF
	var min_at := -1
	var low := INF
	var rub := 0
	var through := -1
	var lat_min := INF
	var lat_max := -INF
	var trace := PackedFloat32Array()
	var diag := PackedStringArray()
	for i in frames:
		await get_tree().physics_frame
		if relative:
			p.tick(STEP)
		else:
			p.drive(1.0, 0.0, STEP)
		var now := p.global_position
		var step := now.distance_to(prev)
		prev = now
		var lat_now: float = now.x - wall.x
		lat_min = minf(lat_min, lat_now)
		lat_max = maxf(lat_max, lat_now)
		if i >= WARM and i % 12 == 0:
			# d = 这一帧网格硬约束想推出的量；safe = 到"上一个安全点"的距离。
			# 卡死的两种机制在这里分得开：d 一直很大 = 一直嵌在墙里；
			# z 不再前进而 safe 恒定 = 每帧被 _settle() 退回安全点（橡皮筋）。
			diag.append("%d/x%+.2f/z%+.2f/y%+4.1f/v%.1f/c%d/d%.2f/g%s" % [
				i - WARM, lat_now, now.z - wall.z,
				rad_to_deg(angle_difference(p.rotation.y, PI)), p.speed(),
				p.get_slide_collision_count(), p._depen_offset().length(),
				"1" if p._spine_clear() else "0",
			])
		if i >= WARM:
			if step < min_step:
				min_step = step
				min_at = i
			low = minf(low, p.speed())
			for c in p.get_slide_collision_count():
				var n := p.get_slide_collision(c).get_normal()
				if Vector3(n.x, 0.0, n.z).length_squared() > 0.001:
					rub += 1
					break
			if through < 0 and now.z > wall.z + 4.0:
				through = i - WARM
		trace.append(p.speed())
	if relative:
		Input.action_release("move_forward")
	return {
		"minStep": min_step, "minAt": min_at, "low": low, "rub": rub,
		"through": through, "lat": maxf(lat_max - lat_min, 0.0),
		"end": p.speed(), "clear": p._spine_clear(), "trace": _lines(trace, WARM, 60),
		"diag": " ".join(diag),
	}


## T 形窄路口里过 90° 直角弯：真实输入链路（镜头相对驾驶 + 按住 W）。
## 玩家会做的唯一一件事就是把镜头转向侧向通道——镜头相对驾驶里，镜头朝向就是目的地。
## 返回：最低速、是否拐进去了（进了横向通道）、车体最大偏航角、磨墙帧数。
func _bent(main: Node, p: Player, a: Arena, x: int, y0: int, yc: int,
		lead: float, sweep_s: float, frames: int) -> Dictionary:
	Settings.drive_relative = true
	_input_start(main, p, a, x, y0, 0.0)
	Input.action_press("move_forward")
	var rig: CameraRig = main.rig
	var trace := PackedFloat32Array()
	var low := INF
	var yaw_max := 0.0
	var rub := 0
	var got_out := -1
	var corner := Arena.cell_center(x, yc)
	var turn_at := -1
	var start_yaw := rig.yaw
	var sweep_f := maxi(int(sweep_s / STEP), 1)
	var diag := PackedStringArray()
	for i in frames:
		await get_tree().physics_frame
		if turn_at < 0 and p.global_position.z > corner.z - lead:
			turn_at = i
		if turn_at >= 0:
			var k := clampf(float(i - turn_at) / float(sweep_f), 0.0, 1.0)
			rig.yaw = lerp_angle(start_yaw, -PI * 0.5, k)
			rig.aim_yaw = rig.yaw
		p.tick(STEP)
		var now := p.global_position
		if i >= WARM and i % 24 == 0:
			diag.append("%d/d%.0f/x%+.2f/z%+.2f/v%.1f/c%+d" % [i - WARM,
				rad_to_deg(angle_difference(p.rotation.y, PI)),
				now.x - corner.x, now.z - corner.z, p.speed(),
				p.get_slide_collision_count()])
		if i >= WARM:
			low = minf(low, p.speed())
			yaw_max = maxf(yaw_max, absf(angle_difference(p.rotation.y, PI)))
			for c in p.get_slide_collision_count():
				if Vector3(p.get_slide_collision(c).get_normal().x, 0.0,
						p.get_slide_collision(c).get_normal().z).length_squared() > 0.001:
					rub += 1
					break
			if got_out < 0 and now.x > corner.x + 8.0:
				got_out = i - WARM
		trace.append(p.speed())
		# 拐进去就算结束：再往前开只会撞上横向通道尽头的封口墙，
		# 那个低谷与"过弯顺不顺"无关，会把 low / rub 一起污染掉
		if got_out >= 0:
			break
	Input.action_release("move_forward")
	return {
		"low": low, "yawMax": rad_to_deg(yaw_max), "rub": rub, "turnAt": turn_at - WARM,
		"out": got_out, "end": p.speed(), "clear": p._spine_clear(),
		"diag": " ".join(diag),
		"trace": _lines(trace, WARM, 24),
	}


## 单格宽走廊里只按 A（或 D）：镜头相对驾驶把它译成"朝画面左/右开"
func _pivot(main: Node, p: Player, a: Arena, ch: Dictionary, key: String,
		hold_s: float, frames: int) -> Dictionary:
	Settings.drive_relative = true
	_input_start(main, p, a, ch.x, ch.y0, 0.0)
	Input.action_press(key)
	var axis := Arena.cell_center(ch.x, ch.y0)
	var lat_min := INF
	var lat_max := -INF
	var low := INF
	var yaw_max := 0.0
	var trace := PackedFloat32Array()
	var hold_f := int(hold_s / STEP)
	for i in frames:
		await get_tree().physics_frame
		p.tick(STEP)
		var lat: float = p.global_position.x - axis.x
		var dyaw := rad_to_deg(angle_difference(p.rotation.y, PI))
		trace.append(p.speed())
		if i >= WARM and i < WARM + hold_f + 240:
			lat_min = minf(lat_min, lat)
			lat_max = maxf(lat_max, lat)
			low = minf(low, p.speed())
			yaw_max = maxf(yaw_max, absf(dyaw))
		if i >= WARM + hold_f:
			Input.action_release(key)
	Input.action_release(key)
	return {
		"low": low, "yawMax": yaw_max, "lat": lat_max - lat_min, "end": p.speed(),
		"clear": p._spine_clear(), "trace": _lines(trace, WARM, 24),
	}


## 按住 W 沿走廊开，同时以 period_s 为周期左右扫准星 swing_deg
func _swing(main: Node, p: Player, a: Arena, ch: Dictionary, swing_deg: float,
		period_s: float, frames: int, relative: bool) -> Dictionary:
	Settings.drive_relative = relative
	_input_start(main, p, a, ch.x, ch.y0, 0.0)
	Input.action_press("move_forward")
	var rig: CameraRig = main.rig
	var axis := Arena.cell_center(ch.x, ch.y0)
	var yaw_max := 0.0
	var lat_min := INF
	var lat_max := -INF
	var low := INF
	var trace := PackedFloat32Array()
	for i in frames:
		await get_tree().physics_frame
		rig.aim_yaw = wrapf(PI + deg_to_rad(swing_deg)
				* sin(float(i) * STEP * TAU / period_s), -PI, PI)
		p.tick(STEP)
		var lat: float = p.global_position.x - axis.x
		trace.append(p.speed())
		if i >= WARM:
			yaw_max = maxf(yaw_max, absf(angle_difference(p.rotation.y, PI)))
			lat_min = minf(lat_min, lat)
			lat_max = maxf(lat_max, lat)
			low = minf(low, p.speed())
	Input.action_release("move_forward")
	return {
		"low": low, "yawMax": rad_to_deg(yaw_max), "lat": lat_max - lat_min,
		"camYaw": rad_to_deg(angle_difference(rig.yaw, PI)), "clear": p._spine_clear(),
		"trace": _lines(trace, WARM, 24),
	}


## 门口用例的一行结论。只有"没穿过去"或"真的停住过"的用例才附诊断，
## 免得十来个用例的诊断把有用输出淹掉。
func _gap_row(tag: String, g: Dictionary) -> void:
	print("PROBE %-22s low=%5.1f minStep=%.4f at=%3d rub=%3d through=%3d lat=%.2f end=%5.1f clear=%s"
		% [tag, g["low"], g["minStep"], g["minAt"], g["rub"], g["through"],
			g["lat"], g["end"], str(g["clear"])])
	print("PROBE %-22s trace %s" % [tag, g["trace"]])
	if g["through"] < 0 or g["minStep"] < 0.02:
		print("PROBE %-22s diag  %s" % [tag, g["diag"]])


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	var p: Player = main.player
	main.set_process(false)
	main.state = "ready"
	main.state_timer = 1e9
	p.shield_t = 0.0
	p.set_physics_process(false)

	var ch := {"x": 12, "y0": 4}
	_build_corridor(a, ch.x, ch.y0, 20)
	await get_tree().physics_frame
	await get_tree().physics_frame
	print("PROBE squeeze cruise=%.1f freeWidth=%.1f hullWidth=%.1f clearance=%.2f corridorLen=%.0fm"
		% [p.move_speed, Arena.CELL, p.body_radius * 2.0,
			(Arena.CELL - p.body_radius * 2.0) * 0.5, (20 - 4) * Arena.CELL])

	# ---- 1 格宽门口：整排砖墙上只留一格。这是"狭窄的障碍物通道"最直白的样子。
	#      量的是**实际位移**：撞在门框棱角上时 _speed 仍然是 15（那只是指令），
	#      只有逐帧位移能看出车有没有真的被别住。
	_build_gap(a, ch.x, 10)
	await get_tree().physics_frame
	await get_tree().physics_frame

	# 基准：锁死车头方向的一条直线。正对门口时必须无损穿过——这是这套约束
	# （车宽 3.0 / 门宽 4.0 / 单侧余量 0.5）的下限验收。
	for lat in [-0.45, 0.0, 0.45]:
		_gap_row("gapLock off=%+.2f" % lat,
			await _gap(main, p, a, ch.x, 10, 4, 0.0, lat, 420))

	# 玩法工况：镜头瞄着门口中心、按住 W，车体自己对齐。带初始横向偏移与车头偏角，
	# 覆盖"偏在门口一侧"（±0.9 已经超出 0.5 米的余量，必须靠车体自己扳回来）
	# 与"车头歪着进"（±10°）两种情况。
	var door_cam := PI
	var door_dist := float(10 - 4) * Arena.CELL
	for lat in [-0.9, -0.45, 0.0, 0.45, 0.9]:
		door_cam = wrapf(PI - atan2(lat, door_dist), -PI, PI)
		for deg in [-10.0, 0.0, 10.0]:
			_gap_row("gapRel off=%+.2f ang=%+3.0f" % [lat, deg],
				await _gap(main, p, a, ch.x, 10, 4, deg_to_rad(deg), lat, 420, true, door_cam))

	if GAP_ONLY:
		get_tree().quit(0)

	_build_corridor(a, ch.x, ch.y0, 20)
	await get_tree().physics_frame
	await get_tree().physics_frame

	for on_s in [0.15, 0.25, 0.35, 0.5]:
		var r := await _corner(p, a, ch, 1.0, on_s, on_s, 660)
		print("PROBE corner steer=1.0 on=%.2fs low=%5.1f end=%5.1f recover=%3d yawMax=%4.1fdeg lat=%.2f clear=%s"
			% [on_s, r["low"], r["end"], r["recover"], r["yawMax"], r["lat"], str(r["clear"])])
		print("PROBE corner trace %s" % r["trace"])

	# ---- T 形窄路口：在路口前 6 / 10 / 14 米开始把镜头转向横向通道 ----
	_build_bent(a, ch.x, 4, 20, 14)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for lead in [6.0, 10.0, 14.0]:
		for sweep in [0.4, 0.8]:
			var b := await _bent(main, p, a, ch.x, 4, 14, lead, sweep, 700)
			print("PROBE bent lead=%4.1fm sweep=%.1fs low=%5.1f out=%3d end=%5.1f rub=%3d yawMax=%4.1fdeg turnAt=%3d clear=%s"
				% [lead, sweep, b["low"], b["out"], b["end"], b["rub"], b["yawMax"],
					b["turnAt"], str(b["clear"])])
			print("PROBE bent trace %s" % b["trace"])
			print("PROBE bent diag  %s" % b["diag"])

	_build_corridor(a, ch.x, ch.y0, 20)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for key in ["turn_left", "turn_right"]:
		var v := await _pivot(main, p, a, ch, key, 0.35, 620)
		print("PROBE pivot %-10s low=%5.1f end=%5.1f lat=%.2f yawMax=%4.1fdeg clear=%s"
			% [key, v["low"], v["end"], v["lat"], v["yawMax"], str(v["clear"])])
		print("PROBE pivot trace %s" % v["trace"])

	for sw in [60.0, 90.0]:
		var s := await _swing(main, p, a, ch, sw, 3.0, 540, true)
		print("PROBE swing rel swing=%4.0fdeg low=%5.1f yawMax=%4.1fdeg lat=%.2f camYaw=%+6.1f clear=%s"
			% [sw, s["low"], s["yawMax"], s["lat"], s["camYaw"], str(s["clear"])])
		print("PROBE swing rel trace %s" % s["trace"])
	get_tree().quit(0)
