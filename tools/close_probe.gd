extends Node
## 验收：近距离交战时炮管的实际俯仰，与"准星压住敌车"需要的角度。
##
## 背景：炮管俯仰范围是 [-18°, +6°]，炮口大约在 1.95 m 高。敌车中心在 1.1 m、
## 车顶在 2.2 m 左右。两车中心距缩短时，"从炮口指向敌车中心"所需的俯角迅速变大：
##   4 m → -12.2°   6 m → -7.9°   8 m → -5.9°   12 m → -3.9°
## 也就是说 8 m 以内都在 -6° 以下，炮管压不下去的话炮口射线会从敌车**上方**擦过去
## ——玩家看到的就是"炮口抬得太高、炮弹飞了"。
##
## 另见 tools/near_probe.gd：那里走真正的 fire() 路径（含炮口位置与命中体），
## 把"瞄车体"与"瞄炮塔"两种情况都覆盖到。本探针只量几何，不发射。
##
## 本探针把靶车摆在 4~30 m，按玩家会做的动作把瞄准角设成"指向敌车中心"，
## 再读回：实际俯仰、炮口射线打没打到靶车、HE 解算仰角与落点高度。
##
## 用法：godot.exe --headless --path . tools/CloseProbe.tscn

const DISTS := [4.0, 5.0, 6.0, 8.0, 12.0, 16.0, 22.0, 30.0]
const SETTLE := 50
const DUMMY_HP := 1000000
const LOB_RANGE := 220.0

var _main: Node
var _rows: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.selected_tank = "falcon"
	_main = get_node("Main")
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "ready"
	_main.state_timer = 1.0e9
	for _i in 8:
		await get_tree().physics_frame

	var p: Player = _main.player
	var arena: Arena = _main.arena
	var yaw := _open_yaw(p, arena)
	if yaw == INF:
		print("VERDICT no open firing lane")
		get_tree().quit(1)
		return
	# 把车体钉在测试朝向上：车体一歪，炮塔射界与炮口位置都会跟着变
	p.rotation.y = yaw

	for i in DISTS.size():
		var d: float = DISTS[i]
		var ctr: Vector3 = p.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * d
		var e := Enemy.new()
		e.configure(1, 3, 1)
		e.max_hp = DUMMY_HP
		e.setup(_main, arena, ctr)
		_main.add_child(e)
		_main.enemies.append(e)
		e.hp = DUMMY_HP
		e.rotation.y = yaw + PI
		await get_tree().physics_frame
		await get_tree().physics_frame
		# 交警卫别把靶车推开
		e.global_position = ctr
		e.rotation.y = yaw + PI
		await get_tree().physics_frame

		var target: Vector3 = e.global_position + Vector3(0, 1.1, 0)
		var pivot: Vector3 = p.global_position + Vector3(0, p.aim_height, 0)
		var to: Vector3 = target - pivot
		var flat := Vector2(to.x, to.z).length()
		var ideal := atan2(to.y, maxf(flat, 0.5))
		_main.rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
		_main.rig.aim_pitch = clampf(ideal, Tank.PITCH_MIN, Tank.PITCH_MAX)
		_main.rig.yaw = _main.rig.aim_yaw
		_main.rig.pitch = CameraRig.PITCH_BASE
		p.rotation.y = _main.rig.aim_yaw
		for _i in SETTLE:
			e.hp = DUMMY_HP
			await get_tree().physics_frame

		_rows.append(_measure(p, e, d, rad_to_deg(ideal)))

		e.alive = false
		_main.enemies.erase(e)
		e.queue_free()
		await get_tree().physics_frame

	_print_table()
	get_tree().quit(0)


## 找一条 30 m 内没有掩体、且靶车能放在正前方的通道
func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [4.0, 8.0, 16.0, 30.0]:
			var pos: Vector3 = p.global_position + dir * d
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
				ok = false
				break
			if arena.blocks_tank(c.x, c.y):
				ok = false
				break
			if not arena.has_line_of_sight(eye, pos + Vector3(0, 1.5, 0)):
				ok = false
				break
		if ok:
			return yaw
	return INF


func _measure(p: Player, e: Enemy, dist: float, ideal_deg: float) -> Dictionary:
	var origin: Vector3 = p.muzzle_pos()
	var dir: Vector3 = p.aim_dir()
	var elev := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))

	var hit := _ray(origin, dir, p, e)
	var hit_kind := "none"
	var hit_d := LOB_RANGE
	if not hit.is_empty():
		hit_kind = "tank" if hit["collider"] is Tank else "world"
		hit_d = (Vector3(hit["position"]) - origin).length()

	var solved: Vector3 = p.he_dir(origin, dir)
	var he_elev := rad_to_deg(asin(clampf(solved.y, -1.0, 1.0)))
	var he_miss := _parabola_miss(origin, solved, e)

	return {
		"dist": dist,
		"ideal": ideal_deg,
		"aim": rad_to_deg(_main.rig.aim_pitch),
		"elev": elev,
		"hit": hit_kind,
		"hitD": hit_d,
		"he": he_elev,
		"miss": he_miss,
	}


func _ray(origin: Vector3, dir: Vector3, p: Player, e: Enemy) -> Dictionary:
	var space := p.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
			origin, origin + dir * LOB_RANGE, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q.exclude = [p.get_rid()]
	return space.intersect_ray(q)


## HE 抛物线在靶车水平距离处的高度 − 靶车中心高度
func _parabola_miss(origin: Vector3, solved: Vector3, e: Enemy) -> float:
	var ctr: Vector3 = e.global_position + Vector3(0, 1.1, 0)
	var d: Vector3 = ctr - origin
	var r := Vector2(d.x, d.z).length()
	var vh := Vector2(solved.x, solved.z).length() * Shell.HE_SPEED
	var t := r / maxf(vh, 0.01)
	var y := origin.y + solved.y * Shell.HE_SPEED * t - 0.5 * Shell.HE_GRAVITY * t * t
	return y - ctr.y


func _print_table() -> void:
	print("---- CLOSE RANGE AIM TABLE ----")
	print("  pitch range [%.1f, %.1f] deg, muzzle height from aim_y"
			% [rad_to_deg(Tank.PITCH_MIN), rad_to_deg(Tank.PITCH_MAX)])
	print("  dist  ideal  aim  barrel  hit    hitD  heElev  heMiss")
	var bad := 0
	for r in _rows:
		var flag := ""
		if String(r["hit"]) != "tank":
			flag = "  MISS"
			bad += 1
		elif absf(float(r["miss"])) > 1.2:
			flag = "  HERUN"
		print("%5.1f %6.1f %5.1f %7.1f  %-5s %6.1f %7.1f %7.2f%s" % [
				r["dist"], r["ideal"], r["aim"], r["elev"], r["hit"], r["hitD"],
				r["he"], r["miss"], flag])
	print("VERDICT no-hit=%d / %d" % [bad, _rows.size()])
