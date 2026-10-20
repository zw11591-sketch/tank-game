extends Node
## 临时验收：狭窄通道里的通行平顺度。
##
## 关注的是"操控手感"这条主观诉求，所以先把它变成能比较的数：
##   census     —— 地图上"能过车的空隙"有多宽（按格统计），即"狭窄"到底指什么
##   straight   —— 对正后直行穿过单格宽走廊：巡航后的最低速 / 掉速帧数 / 单帧位移峰值
##   entry      —— 带着角度进走廊：会不会蹭墙掉速（这是最真实的工况）
##   wedged     —— 15° 卡进去之后，反打一舵能否自己走出来
##   graze      —— 直行中途轻推一舵去蹭墙再回正：掉多少速、多久恢复
##   depen      —— 车身摆在走廊里、只改朝向与横移：网格硬约束把车推开多少米
##   input      —— 走真实输入链路（Player.tick + 镜头相对驾驶）跑一段
##
## 两条实现约束，违反任何一条结论都会是假的：
##   1. drive() 每物理帧只调一次，与真实游戏一致。一帧里连调 N 次，queue_free 的
##      旧碰撞体还留在空间里（幽灵墙），量出来的"卡死"其实是自己的脚手架。
##   2. 不能开 "play" 状态跑长测量：敌人会刷出来把玩家打掉，测到一半对象就没了。
##      所以长测量停在 "ready"（state_timer 顶到很大），只有 input 一段才开 "play"
##      且把刷兵队列清空。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --path <proj> res://tools/CorridorProbe.tscn

const STEP := 1.0 / 120.0
## 起步到巡航要约 1.07 s（accel 14 m/s²，巡航 15 m/s），所以统计从第 150 帧起算
const WARM := 150
## 撞墙试车台：车从 CRASH_FROM 行起步，正前方 CRASH_Y 行是满幅钢墙
const CRASH_Y := 12
const CRASH_FROM := 3
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


# ---------------- 通道宽度普查 ----------------

## 统计"两侧都是掩体的可通行空隙"有多宽，按格数分档。
## 单格（4 m）是本项目最窄的一类通道——车宽 3.0 m，只剩 0.5 m 单侧余量。
func _census(a: Arena) -> String:
	var hist := {1: 0, 2: 0, 3: 0, 4: 0}
	for y in range(1, Arena.GRID_H - 1):
		var x := 1
		while x < Arena.GRID_W - 1:
			if a.blocks_tank(x, y):
				x += 1
				continue
			var x0 := x
			while x < Arena.GRID_W - 1 and not a.blocks_tank(x, y):
				x += 1
			if a.blocks_tank(x0 - 1, y) and a.blocks_tank(x, y):
				hist[mini(x - x0, 4)] += 1
	for x in range(1, Arena.GRID_W - 1):
		var y := 1
		while y < Arena.GRID_H - 1:
			if a.blocks_tank(x, y):
				y += 1
				continue
			var y0 := y
			while y < Arena.GRID_H - 1 and not a.blocks_tank(x, y):
				y += 1
			if a.blocks_tank(x, y0 - 1) and a.blocks_tank(x, y):
				hist[mini(y - y0, 4)] += 1
	return "gaps 1cell=%d 2cell=%d 3cell=%d 4+cell=%d" % [hist[1], hist[2], hist[3], hist[4]]


## 现搭一条纵向单格宽走廊：两侧砌砖墙，通道格清空，两端留开阔地。
##
## 清空带刻意开得又宽又长：测量要跑 4 秒、约 55 米，试车带太短的话车会撞上
## 地图剩下的墙，量到的那个 0.8 m/s 低谷其实是试车带的尽头，不是走廊的手感。
func _build_corridor(a: Arena, x: int, y0: int, ln: int) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for dx in range(-8, 9):
			var cx := x + dx
			if cx < 1 or cx >= Arena.GRID_W - 1:
				continue
			a.grid[y][cx] = Arena.EMPTY
	# 墙只砌在走廊那一段，两端是开阔地：车出得来、也进得去
	for y in range(y0 - 4, y0 + ln + 4):
		if y < 1 or y >= Arena.GRID_H - 1:
			continue
		a.grid[y][x - 1] = Arena.BRICK
		a.grid[y][x + 1] = Arena.BRICK
	a._rebuild_all()


# ---------------- 摆位与测量 ----------------

func _pose(p: Player, a: Arena, x: int, y: int, yaw_off: float, lat := 0.0) -> void:
	p.global_position = Arena.cell_center(x, y) + Vector3(lat, 0.0, 0.0)
	p.rotation.y = PI + yaw_off
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	p.hp = 1_000_000
	if p.turret != null:
		p.turret.rotation.y = 0.0


## 直行 frames 帧（每物理帧一帧一调）。steer 只在头 steer_s 秒有效，之后回正。
## 预算里 warm=统计窗口起点、slow=掉到半速以下的帧数、low=窗口内最低速。
func _line(p: Player, a: Arena, ch: Dictionary, yaw_off: float,
		steer: float, steer_s: float, frames: int, lat := 0.0,
		steer_b: float = 0.0, steer_b_s: float = 0.0, steer_b_at := 0) -> Dictionary:
	var home := Arena.cell_center(ch.x, ch.y0 - 1)
	_pose(p, a, ch.x, ch.y0 - 1, yaw_off, lat)
	var cruise := p.move_speed
	var low := INF
	var low_at := -1
	var slow := 0
	var contact := 0
	var max_step := 0.0
	var max_drop := 0.0
	var prev_spd := 0.0
	var prev := p.global_position
	var trace := PackedFloat32Array()
	for i in frames:
		await get_tree().physics_frame
		var s := 0.0
		if float(i) * STEP < steer_s:
			s = steer
		elif i >= steer_b_at and float(i - steer_b_at) * STEP < steer_b_s:
			s = steer_b
		p.drive(1.0, s, STEP)
		var now := p.global_position
		max_step = maxf(max_step, now.distance_to(prev))
		prev = now
		if i >= WARM:
			if p.get_slide_collision_count() > 0:
				contact += 1
			var sp := p.speed()
			if sp < low:
				low = sp
				low_at = i
			if sp < cruise * 0.5:
				slow += 1
			max_drop = maxf(max_drop, maxf(0.0, prev_spd - sp))
		prev_spd = p.speed()
		trace.append(p.speed())
	return {
		"low": low, "slow": slow, "contact": contact, "step": max_step, "drop": max_drop,
		"end": p.speed(), "dist": p.global_position.distance_to(home), "lowAt": low_at,
		"clear": p._spine_clear(), "trace": trace, "cruise": cruise,
	}


## 巡航之后轻推一舵去蹭墙，回正看恢复：before 取打舵前一帧。
## 只跑 330 帧（2.75 秒）：再长车就冲出试车带、撞上地图边界的钢墙，
## 那个低谷会被误读成"蹭墙的代价"。
func _graze(p: Player, a: Arena, ch: Dictionary, steer: float) -> Dictionary:
	_pose(p, a, ch.x, ch.y0 - 1, 0.0)
	var before := 0.0
	var low := INF
	var low_at := -1
	var recovery := -1
	var hit := -1
	for i in 330:
		await get_tree().physics_frame
		var s := steer if (i >= WARM and i < WARM + 36) else 0.0
		p.drive(1.0, s, STEP)
		if i == WARM - 1:
			before = p.speed()
		if i >= WARM:
			if hit < 0 and p.get_slide_collision_count() > 0:
				hit = i - WARM
			if p.speed() < low:
				low = p.speed()
				low_at = i
			if recovery < 0 and i > WARM + 60 and p.speed() > before * 0.95:
				recovery = i - WARM - 36
	return {"before": before, "low": low, "lowAt": low_at, "hit": hit, "recover": recovery}


## 撞到的法线是哪一类：竖直法线是地面（与掉速无关），水平法线才是墙。
func _probe_normals(p: Player, a: Arena, ch: Dictionary) -> String:
	var out := PackedStringArray()
	for deg in [0.0, 10.0, 20.0]:
		_pose(p, a, ch.x, ch.y0 + 2, deg_to_rad(deg))
		for _i in 4:
			await get_tree().physics_frame
			p.drive(0.0, 0.0, STEP)
		var ns := PackedStringArray()
		for i in p.get_slide_collision_count():
			var n := p.get_slide_collision(i).get_normal()
			ns.append("(%.2f,%.2f,%.2f)" % [n.x, n.y, n.z])
		out.append("%.0fdeg n=%d %s" % [deg, p.get_slide_collision_count(), " ".join(ns)])
	return "slideNormals " + " | ".join(out)


## 移动中的撞墙诊断：把每帧的入射角（bite）与速度并排打出来，
## 确认"掉速"到底是不是 _bleed_on_impact 干的，以及拐点落在哪个角度。
func _bite_trace(p: Player, a: Arena, ch: Dictionary, deg: float, frames: int) -> void:
	var axis := Arena.cell_center(ch.x, ch.y0).x
	_pose(p, a, ch.x, ch.y0 - 1, deg_to_rad(deg))
	var out := PackedStringArray()
	for i in frames:
		await get_tree().physics_frame
		p.drive(1.0, 0.0, STEP)
		var head := (-p.global_transform.basis.z).normalized()
		var bite := 0.0
		var n_ground := 0
		for k in p.get_slide_collision_count():
			var n := p.get_slide_collision(k).get_normal()
			var nf := Vector3(n.x, 0.0, n.z)
			if nf.length_squared() < 0.001:
				n_ground += 1
				continue
			bite = maxf(bite, clampf(-head.dot(nf.normalized()), 0.0, 1.0))
		if i % 12 == 0:
			out.append("%d:b%.2f/v%.1f/x%+.2f/g%d" % [i, bite, p.speed(), p.global_position.x - axis, n_ground])
	print("PROBE biteTrace %4.0fdeg %s" % [deg, " ".join(out)])


## 撞墙试车台：清出一整条通道，在 CRASH_Y 行横砌一道满幅钢墙。
## 墙必须横贯整幅地图——斜擦时车会沿墙滑出十几米，墙太短就成了"滑过墙端再加速"，
## 量到的不是撞墙掉速。
func _build_wall(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(CRASH_FROM, CRASH_Y + 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	for x in range(1, Arena.GRID_W - 1):
		a.grid[CRASH_Y][x] = Arena.STEEL
	a._rebuild_all()


## 满油门撞墙。deg 是"偏离正撞"的角度，所以入射角 bite ≈ cos(deg)：
## 0° 正面、30° 偏三成、60° 已经很擦。报到墙那一刻的速度，以及之后各时间点的速度。
##
## 不靠"检测到碰撞"来定位撞击帧：斜擦时车身一路蹭着墙，第一次接触的位置
## 与"速度开始被吃掉"的位置不是同一处。改成取"最高速那一帧"当基准，对每种入射角都稳。
func _crash(p: Player, a: Arena, deg: float) -> Dictionary:
	_pose(p, a, 12, CRASH_FROM, deg_to_rad(deg))
	var trace := PackedFloat32Array()
	for i in 660:
		await get_tree().physics_frame
		p.drive(1.0, 0.0, STEP)
		trace.append(p.speed())
	var peak := 0.0
	var i_peak := 0
	for i in trace.size():
		if trace[i] >= peak:
			peak = trace[i]
			i_peak = i
	var mark := {}
	for d in [30, 60, 120, 240]:
		if i_peak + d < trace.size():
			mark[d] = trace[i_peak + d]
	return {"peak": peak, "mark": mark, "end": p.speed(), "at": i_peak}


## 蹭墙那一下的逐帧诊断：把每帧的入射角、速度、横向位置并排打出来。
## 用来看"轻推一舵"到底在哪一帧、以什么角度吃掉了速度。
func _graze_trace(p: Player, a: Arena, ch: Dictionary, steer: float) -> void:
	var axis := Arena.cell_center(ch.x, ch.y0).x
	_pose(p, a, ch.x, ch.y0 - 1, 0.0)
	var out := PackedStringArray()
	for i in 260:
		await get_tree().physics_frame
		var s := steer if (i >= WARM and i < WARM + 36) else 0.0
		p.drive(1.0, s, STEP)
		if i < WARM - 4 or i > WARM + 60:
			continue
		var head := (-p.global_transform.basis.z * signf(p.speed())).normalized()
		var bite := 0.0
		var nwall := 0
		var nground := 0
		for k in p.get_slide_collision_count():
			var n := p.get_slide_collision(k).get_normal()
			var nf := Vector3(n.x, 0.0, n.z)
			if nf.length_squared() < 0.001:
				nground += 1
				continue
			nwall += 1
			bite = maxf(bite, clampf(-head.dot(nf.normalized()), 0.0, 1.0))
		out.append("%d/b%.2f/v%.1f/x%+.2f/w%d" % [i - WARM, bite, p.speed(), p.global_position.x - axis, nwall])
	print("PROBE grazeTrace steer=%.2f %s" % [steer, " ".join(out)])


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	var p: Player = main.player
	# 关掉 main 的状态机：否则 "ready" 计时走完会切到 "play" 刷敌人，
	# 或者肃清计数走完直接换关——测到一半玩家对象就被 _clear_battle() 释放了
	main.set_process(false)
	# 长测量停在地图就绪但没开打的那一档：敌人不出场，车也不会被测到一半被打掉
	main.state = "ready"
	main.state_timer = 1e9
	p.shield_t = 0.0
	p.set_physics_process(false)

	var census := _census(a)
	var ch := {"x": 12, "y0": 9, "len": 6}
	_build_corridor(a, ch.x, ch.y0, ch.len)
	# 让 queue_free 的旧掩体真正离场，否则量到的是脚手架
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("PROBE census %s" % census)
	print("PROBE narrow x=%d y0=%d len=%d freeWidth=%.1f hullWidth=%.1f clearance=%.2f cruise=%.1f"
		% [ch.x, ch.y0, ch.len, Arena.CELL, p.body_radius * 2.0,
			(Arena.CELL - p.body_radius * 2.0) * 0.5, p.move_speed])

	var r := await _line(p, a, ch, 0.0, 0.0, 0.0, 420)
	_line_row("straight", r)

	for deg in [3.0, 10.0, 15.0, 25.0, 30.0, 35.0, 40.0]:
		r = await _line(p, a, ch, deg_to_rad(deg), 0.0, 0.0, 300)
		_line_row("entry%+4.0fdeg" % deg, r)

	for lat in [-0.35, 0.0, 0.35]:
		r = await _line(p, a, ch, 0.0, 0.0, 0.0, 300, lat)
		_line_row("offset%+5.2f" % lat, r)

	# 15° 进走廊之后反打一舵：能不能自己走回来（第 240 帧起反向打舵 0.4 秒）
	r = await _line(p, a, ch, deg_to_rad(15.0), 0.0, 0.0, 420, 0.0, -0.25, 0.4, 240)
	_line_row("wedged15+fix", r)

	for s in [0.25, 0.5, 1.0]:
		var g := await _graze(p, a, ch, s)
		print("PROBE graze steer=%.2f before=%5.1f low=%5.1f at=%3d hitFrame=%d recoverFrames=%d"
			% [s, g["before"], g["low"], g["lowAt"], g["hit"], g["recover"]])
	await _graze_trace(p, a, ch, 0.25)

	print("PROBE %s" % await _probe_normals(p, a, ch))

	for deg in [10.0, 15.0, 25.0]:
		await _bite_trace(p, a, ch, deg, 156)

	var yaws := PackedStringArray()
	for deg in [0.0, 2.0, 5.0, 10.0, 15.0, 20.0, 30.0, 45.0]:
		p.global_position = Arena.cell_center(ch.x, ch.y0 + ch.len / 2)
		p.rotation.y = PI + deg_to_rad(deg)
		p._safe_pos = p.global_position
		yaws.append("%.0fdeg=%.3f" % [deg, p._depen_offset().length()])
	print("PROBE depenYaw %s" % " ".join(yaws))

	await _input_run(main, p, ch)

	# ---- 撞墙手感：正面与斜擦都要掉速，别被走廊这一轮的改动一起削掉 ----
	_build_wall(a)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for deg in [0.0, 15.0, 30.0, 45.0]:
		var c := await _crash(p, a, deg)
		print("PROBE crash%+4.0fdeg peak=%5.1f t025=%.1f t050=%.1f t100=%.1f t200=%.1f end=%.1f"
			% [deg, c["peak"], c["mark"].get(30, -1.0), c["mark"].get(60, -1.0),
				c["mark"].get(120, -1.0), c["mark"].get(240, -1.0), c["end"]])
	get_tree().quit(0)


func _line_row(tag: String, r: Dictionary) -> void:
	print("PROBE %-13s low=%5.1f at=%3d slowFrames=%3d contact=%3d maxStep=%.3f maxDrop=%5.2f end=%5.1f dist=%5.1f clear=%s"
		% [tag, r["low"], r["lowAt"], r["slow"], r["contact"], r["step"], r["drop"], r["end"], r["dist"], str(r["clear"])])


## 真实输入链路：开回引擎侧的 tick，按 W 走完整换算（drive_relative + 镜头跟随）。
## 起始车头偏 8°、镜头对正走廊——等价于"玩家看着走廊按 W，车体自己摆正"。
func _input_run(main: Node, p: Player, ch: Dictionary) -> void:
	Settings.drive_relative = true
	var rig: CameraRig = main.rig
	_pose(p, main.arena, ch.x, ch.y0 - 1, deg_to_rad(8.0))
	rig.yaw = PI
	rig.aim_yaw = PI
	main.spawn_queue.clear()
	main.max_active = 0
	main.state = "play"
	main.state_timer = 1e9
	p.set_physics_process(true)
	Input.action_press("move_forward")
	var low := INF
	var contact := 0
	var max_step := 0.0
	var prev := p.global_position
	var lat_min := INF
	var lat_max := -INF
	var yaw_max := 0.0
	var trace := PackedFloat32Array()
	var axis := Arena.cell_center(ch.x, ch.y0)
	for i in 300:
		await get_tree().physics_frame
		var now := p.global_position
		max_step = maxf(max_step, now.distance_to(prev))
		prev = now
		if i >= WARM:
			if p.get_slide_collision_count() > 0:
				contact += 1
			low = minf(low, p.speed())
		lat_min = minf(lat_min, now.x - axis.x)
		lat_max = maxf(lat_max, now.x - axis.x)
		yaw_max = maxf(yaw_max, absf(angle_difference(p.rotation.y, PI)))
		trace.append(p.speed())
	Input.action_release("move_forward")
	p.set_physics_process(false)
	var out := PackedStringArray()
	for i in range(0, trace.size(), 30):
		out.append("%.2fs:%.1f" % [float(i) * STEP, trace[i]])
	print("PROBE input low=%5.1f contact=%3d maxStep=%.3f lat=[%+.2f,%+.2f] yawMax=%.1fdeg"
		% [low, contact, max_step, lat_min, lat_max, rad_to_deg(yaw_max)])
	print("PROBE input trace %s" % " ".join(out))
