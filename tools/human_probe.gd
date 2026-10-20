extends Node
## 临时诊断：**传统履带转向**下"一个真实玩家"在真实战场窄通道里跑完整路线。
##
## 与 route_probe 的区别只有一处、但很关键：route_probe 靠镜头相对驾驶让车体自己
## 朝准星对齐，玩家只按 W。而 user://settings.cfg 里 drive_relative 可以被关掉，
## 那时 A/D 是"原地转车"，必须由人来打舵。
##
## 所以这里替玩家做一个最小但合理的控制器（写死在下面，参数越少越好）：
##   * 按住 W；
##   * 航向误差 |e| > 6° 就打舵修正（人不会为 3° 打车）；
##   * |e| > 50° 就松开 W，先转头再走（窄通道里人一定会这么做）。
## 判据只用**实际位移**：顶着墙角时 _speed 还报着 5 m/s，车却一米没动。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --headless --path <proj> res://tools/HumanProbe.tscn

const STEP := 1.0 / 120.0
const STILL_STEP := 0.012
const STILL_FRAMES := 40
const MAX_FRAMES := 1500
## 人打舵的死区
const STEER_DEAD := deg_to_rad(6.0)
## 误差大于这个角就收油门，先转头
const BRAKE_ANGLE := deg_to_rad(50.0)
## 收油门后要回到这个角以内才重新给油
const RESUME_ANGLE := deg_to_rad(20.0)
const TERRRAINS := [3]

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
	if _f == 40 and not _started:
		_started = true
		_run()


func _clear_steer() -> void:
	Input.action_release("turn_left")
	Input.action_release("turn_right")


func _dump(a: Arena, p: Player) -> String:
	var c := Arena.to_cell(p.global_position)
	var fwd := -p.global_transform.basis.z
	var nose := Arena.to_cell(p.global_position + fwd * p._nose_f)
	var tail := Arena.to_cell(p.global_position - fwd * p._nose_f)
	var rows := PackedStringArray()
	for dy in range(-4, 5):
		var row := ""
		for dx in range(-4, 5):
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


## 沿 A* 路径开一遍。返回统计与停滞点诊断。
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

	var wp := 0
	var cruise := p.move_speed
	var low := INF
	var slow := 0
	var since_move := 0
	var stall := 0
	var wedge := -1
	var wedge_info := ""
	var prev := p.global_position
	var reached := false
	var warm := 140
	var series := PackedStringArray()
	var dumping := 0
	var want_go := true
	for i in frames:
		await get_tree().physics_frame
		var cur: Vector3 = path[wp]
		var d := cur - p.global_position
		if Vector2(d.x, d.z).length() < 3.0 and wp < path.size() - 1:
			wp += 1
			cur = path[wp]
			d = cur - p.global_position
		var want_yaw := atan2(-d.x, -d.z)
		rig.aim_yaw = want_yaw
		# ---- 人：按航向误差决定打哪边舵、要不要收油 ----
		var e := angle_difference(p.rotation.y, want_yaw)
		_clear_steer()
		if absf(e) > STEER_DEAD:
			# angle_difference 是"从车头到目标"的有向角：e>0 表示要增大 rotation.y，
			# 而 drive() 里 rotation.y += -steer，所以此时按下的是 turn_left
			Input.action_press("turn_left" if e > 0.0 else "turn_right")
		if absf(e) > BRAKE_ANGLE:
			want_go = false
		elif absf(e) < RESUME_ANGLE:
			want_go = true
		if want_go:
			Input.action_press("move_forward")
		else:
			Input.action_release("move_forward")
		p.tick(STEP)

		var now := p.global_position
		var step := now.distance_to(prev)
		prev = now
		if dumping > 0:
			dumping -= 1
			series.append("%d x%+.2f z%+.2f yaw%+4.0f aim%+4.0f e%+4.0f v%.1f s%.3f cell(%d,%d) w%d go%d" % [
				i - warm, now.x, now.z,
				rad_to_deg(p.rotation.y), rad_to_deg(want_yaw), rad_to_deg(e),
				p.speed(), step,
				Arena.to_cell(now).x, Arena.to_cell(now).y,
				_run_width(a, Arena.to_cell(now)), 1 if want_go else 0])
		if i >= warm:
			var sp := p.speed()
			low = minf(low, sp)
			if sp < cruise * 0.5:
				slow += 1
			if step < STILL_STEP:
				since_move += 1
				if since_move >= STILL_FRAMES:
					stall += 1
			else:
				since_move = 0
			if wedge < 0 and since_move == STILL_FRAMES:
				wedge = i - warm
				var c := Arena.to_cell(now)
				wedge_info = "cell(%d,%d) w%d e%+.0fdeg v%.1f turnBlocked=%s go%d" % [
					c.x, c.y, _run_width(a, c), rad_to_deg(e), sp,
					str(p.turn_blocked), 1 if want_go else 0]
				dumping = 200
			# 速度掉到几乎停住：把这一段逐帧拍下来（比"连续 40 帧不动"更早触发）
			if wedge < 0 and sp < 1.0:
				wedge = i - warm
				var c2 := Arena.to_cell(now)
				wedge_info = "STOP cell(%d,%d) w%d e%+.0fdeg v%.1f turnBlocked=%s" % [
					c2.x, c2.y, _run_width(a, c2), rad_to_deg(e), sp,
					str(p.turn_blocked)]
				dumping = 260
		if now.distance_to(goal) < 5.0:
			reached = true
			break
	_clear_steer()
	Input.action_release("move_forward")

	var dump := ""
	if wedge >= 0:
		dump = _dump(a, p)
	return {
		"ok": true, "low": low, "slow": slow, "still": stall, "wedge": wedge,
		"wedgeInfo": wedge_info, "dump": dump, "reached": reached, "series": series,
		"end": p.speed(), "clear": p._spine_clear(),
	}


## 附近"能过车的连续空隙"有多宽（格）
func _run_width(a: Arena, c: Vector2i) -> int:
	var best := 1
	for dir in [Vector2i(1, 0), Vector2i(0, 1)]:
		var n := 1
		var pt: Vector2i = c
		while n < 6:
			pt += dir
			if a.blocks_tank(pt.x, pt.y):
				break
			n += 1
		pt = c
		var m := 1
		while m < 6:
			pt -= dir
			if a.blocks_tank(pt.x, pt.y):
				break
			m += 1
		best = maxi(best, n + m - 1)
	return best


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	main.set_process(false)

	for t in TERRRAINS:
		a.generate(1, t)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var r: Dictionary = await _route(a, t, MAX_FRAMES)
		var nm: String = Arena.TERRAINS[t]["name"]
		if not r["ok"]:
			print("PROBE legacy %-2d %-8s NO PATH" % [t, nm])
			continue
		print("PROBE legacy %-2d %-8s low=%5.1f slow=%4d still=%4d reached=%s wedgeAt=%s" % [
			t, nm, r["low"], r["slow"], r["still"], str(r["reached"]),
			str(r["wedge"]) if r["wedge"] >= 0 else "-"])
		if r["wedge"] >= 0:
			print("PROBE legacy %-2d %-8s where %s" % [t, nm, r["wedgeInfo"]])
			print("PROBE legacy %-2d %-8s map   %s" % [t, nm, r["dump"]])
			var rows: PackedStringArray = r["series"]
			for j in range(0, rows.size(), 10):
				print("PROBE ser %3d %s" % [j, rows[j]])
	get_tree().quit(0)
