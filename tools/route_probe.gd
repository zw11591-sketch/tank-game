extends Node
## 临时诊断：在**真实生成的地图**上跑"玩家会走的路"，量通行平顺度并定位卡点。
##
## 前面的探针（corridor / squeeze / wedge）搭的都是手搓的窄通道，全部通过。
## 但玩家抱怨的"窄通道不顺畅"发生在真实战场上，而真实战场有两件手搓试车台没有的事：
##   1. 路障格（BARRICADE）是后期加进去的，规划时只校验"连通性"，没有校验"宽度"；
##   2. 炮弹会在墙上打出一个**一格宽的洞**，玩家随即就想从洞里开过去。
##
## 判据只用**实际位移**，不看 _speed：撞在墙角上时 _speed 仍然报着指令速度
## （5.2 m/s 对应"以 45° 顶住墙、加速度与撞击掉速打平"），车却一米都没走。
## 第一版探针就是按 _speed 判停滞，于是把"顶着墙角不动"读成了"在正常行驶"。
##
## 停滞时打印该处 7x7 格的通行图与车身姿态，于是"哪里卡"与"为什么卡"能对上。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --headless --path <proj> res://tools/RouteProbe.tscn

const STEP := 1.0 / 120.0
## 单帧位移小于此值即视为"这一帧没有移动"（120Hz 下 15 m/s 是 0.125 米/帧）
const STILL_STEP := 0.012
## 连续这么多帧没有移动 = 一次停滞
const STILL_FRAMES := 40
## 走不到终点就放弃的帧数上限
const MAX_FRAMES := 1500

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	# user://settings.cfg 里可能存着"履带转向"，那会让本探针只按 W 的输入退化成
	# "沿车头轴直冲"——测出来的"卡死"其实是探针自己开进了墙里，不是游戏的问题。
	Settings.drive_relative = true
	var main := get_node("Main")
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


## 该格附近"能过车的连续空隙"有多宽（格）。1 格 = 4 米 = 车宽 3 米只剩 0.5 米单侧余量。
func _run_width(a: Arena, c: Vector2i) -> int:
	var best := 1
	for dir in [Vector2i(1, 0), Vector2i(0, 1)]:
		var n := 1
		var p: Vector2i = c
		while n < 6:
			p += dir
			if a.blocks_tank(p.x, p.y):
				break
			n += 1
		p = c
		var m := 1
		while m < 6:
			p -= dir
			if a.blocks_tank(p.x, p.y):
				break
			m += 1
		best = maxi(best, n + m - 1)
	return best


## 7x7 通行图：# 掩体 / . 空地 / P 车体中心 / o 车鼻车尾
func _dump(a: Arena, p: Player) -> String:
	var c := Arena.to_cell(p.global_position)
	var fwd := -p.global_transform.basis.z
	var nose := Arena.to_cell(p.global_position + fwd * p._nose_f)
	var tail := Arena.to_cell(p.global_position - fwd * p._nose_f)
	var rows := PackedStringArray()
	for dy in range(-3, 4):
		var row := ""
		for dx in range(-3, 4):
			var k := Vector2i(c.x + dx, c.y + dy)
			if k == c:
				row += "P"
			elif k == nose:
				row += "n"
			elif k == tail:
				row += "t"
			elif a.blocks_tank(k.x, k.y):
				row += "#"
			else:
				row += "."
		rows.append(row)
	return "/".join(rows)


## 本帧车体与墙的接触里最深的入射角（bite）与接触面数
func _contact(p: Player) -> Array:
	var head := (-p.global_transform.basis.z * signf(p.speed() if p.speed() != 0.0 else 1.0)).normalized()
	var bite := 0.0
	var walls := 0
	for i in p.get_slide_collision_count():
		var n := p.get_slide_collision(i).get_normal()
		var nf := Vector3(n.x, 0.0, n.z)
		if nf.length_squared() < 0.001:
			continue
		walls += 1
		bite = maxf(bite, clampf(-head.dot(nf.normalized()), 0.0, 1.0))
	return [bite, walls]


## 在一张真实地图上沿 A* 路径开一遍。返回统计与停滞点诊断。
func _route(a: Arena, t: int, frames: int) -> Dictionary:
	var main := _main()
	var p: Player = main.player
	var rig: CameraRig = main.rig
	var from := a.player_spawn()
	var goal := Arena.cell_center(Arena.GRID_W / 2, 2)
	var path: Array = a.find_path(from, goal)
	if path.is_empty():
		return {"ok": false}

	p.global_position = from
	# 车头必须与路径同向：背着路径起步会被镜头相对驾驶判成"目标在车尾那侧"而倒车
	var d0: Vector3 = path[0] - from
	p.rotation.y = atan2(-d0.x, -d0.z)
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = from
	p.hp = 1_000_000
	p.shield_t = 0.0
	p.set_physics_process(false)
	rig.yaw = p.rotation.y
	rig.aim_yaw = rig.yaw
	rig.aim_pitch = 0.0
	main.spawn_queue.clear()
	main.max_active = 0
	main.state = "play"
	main.state_timer = 1e9

	Input.action_press("move_forward")
	var wp := 0
	var cruise := p.move_speed
	var low := INF
	var slow := 0
	var still_frames := 0
	var wedge := -1
	var wedge_info := ""
	var prev := p.global_position
	var since_move := 0
	var reached := false
	var warm := 140
	var series := PackedStringArray()
	var dumping := 0
	for i in frames:
		await get_tree().physics_frame
		var cur: Vector3 = path[wp]
		var d := cur - p.global_position
		if Vector2(d.x, d.z).length() < 3.0 and wp < path.size() - 1:
			wp += 1
			cur = path[wp]
			d = cur - p.global_position
		rig.aim_yaw = atan2(-d.x, -d.z)
		var cmd := p._relative_drive(1.0, 0.0)
		p.tick(STEP)

		var now := p.global_position
		var step := now.distance_to(prev)
		prev = now
		if dumping > 0:
			dumping -= 1
			var ct2 := _contact(p)
			series.append("%d x%+.2f z%+.2f yaw%+4.0f aim%+4.0f e%+4.0f th%.2f st%+.2f T%d bite%.2f v%.1f s%.3f c%d cell(%d,%d) w%d" % [
				i - warm, now.x, now.z,
				rad_to_deg(p.rotation.y), rad_to_deg(rig.aim_yaw),
				rad_to_deg(angle_difference(p.rotation.y, rig.aim_yaw)),
				cmd.x, cmd.y, 1 if p.turn_blocked else 0, ct2[0], p.speed(), step,
				p.get_slide_collision_count(),
				Arena.to_cell(now).x, Arena.to_cell(now).y, _run_width(a, Arena.to_cell(now))])
		if i >= warm:
			var sp := p.speed()
			low = minf(low, sp)
			if sp < cruise * 0.5:
				slow += 1
			if step < STILL_STEP:
				since_move += 1
				if since_move >= STILL_FRAMES:
					still_frames += 1
			else:
				since_move = 0
			# 第一次停滞发生时把现场拍下来——后面再卡也说明不了新东西
			if wedge < 0 and since_move == STILL_FRAMES:
				wedge = i - warm
				var c := Arena.to_cell(now)
				var ct := _contact(p)
				wedge_info = "cell(%d,%d) w%d yaw%+.0fdeg v%.1f bite%.2f walls%d turnBlocked=%s" % [
					c.x, c.y, _run_width(a, c),
					rad_to_deg(angle_difference(p.rotation.y, atan2(-d.x, -d.z))),
					sp, ct[0], ct[1], str(p.turn_blocked)]
				dumping = 240
		if now.distance_to(goal) < 5.0:
			reached = true
			break
	Input.action_release("move_forward")

	var dump := ""
	if wedge >= 0:
		dump = _dump(a, p)
	return {
		"ok": true, "low": low, "slow": slow, "still": still_frames, "wedge": wedge,
		"wedgeInfo": wedge_info, "dump": dump, "reached": reached, "series": series,
		"end": p.speed(), "clear": p._spine_clear(),
	}


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	main.set_process(false)

	for t in range(Arena.TERRAINS.size()):
		a.generate(1, t)
		# 让 queue_free 的旧掩体真正离场，否则量到的是上一张图的脚手架
		await get_tree().physics_frame
		await get_tree().physics_frame
		var r := await _route(a, t, MAX_FRAMES)
		var nm: String = Arena.TERRAINS[t]["name"]
		if not r["ok"]:
			print("PROBE route %-2d %-8s NO PATH" % [t, nm])
			continue
		print("PROBE route %-2d %-8s low=%5.1f slow=%4d still=%4d reached=%s wedgeAt=%s"
			% [t, nm, r["low"], r["slow"], r["still"], str(r["reached"]),
				str(r["wedge"]) if r["wedge"] >= 0 else "-"])
		if r["wedge"] >= 0:
			print("PROBE route %-2d %-8s where %s" % [t, nm, r["wedgeInfo"]])
			print("PROBE route %-2d %-8s map   %s" % [t, nm, r["dump"]])
			var rows: PackedStringArray = r["series"]
			for j in range(0, rows.size(), 8):
				print("PROBE ser %3d %s" % [j, rows[j]])
	get_tree().quit(0)
