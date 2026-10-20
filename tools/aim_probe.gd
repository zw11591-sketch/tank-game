extends Node
## 验收：近距离（2.6~7 m）把准星压在敌车**可见轮廓**上时，炮弹有没有打中。
##
## 与 near_probe.gd 的区别：那里只瞄「车体中心 1.1 m」与「炮塔中心 2.2 m」两个理想点，
## 而且敌车只有中型车。玩家真实会瞄的是轮廓上任意一点——车顶边缘、炮塔侧面、
## 偏置 0.4 m 的侧缘，以及低矮的侦察车 / 高大的 Boss。
##
## 每行记录：
##   aimH   瞄准点离地高度
##   want   玩家给的角度（未收敛）
##   aim    收敛之后的瞄准角（= 炮管俯仰）
##   barrelY / enemyTop  炮管耳轴高度 / 敌车可见轮廓顶面高度
##   hit / climb         是否命中 / 弹道最高爬升
##
## 判据：准星射线落在敌车身上（on=tank）时，扣扳机必须命中，且 climb ≤ 2 m。
##
## 用法：godot.exe --headless --path . res://tools/AimProbe.tscn

## 玩家车型：主战（耳轴最高之一）与歼击车（耳轴最低）
const PLAYERS := [1, 4]
## 敌车车型：中型 / 重型 / 火炮 / Boss
const ENEMIES := [1, 2, 3, 4]
const DISTS := [2.6, 3.2, 4.5, 7.0]
## 瞄法：车体中心 / 轮廓顶缘 / 车顶上方 0.1 m / 侧面偏置
const MODES := ["body", "top", "edge", "side"]
const SETTLE := 30
const DUMMY_HP := 1000000

var _main: Node
var _rows: Array = []
var _yaw := 0.0
var _p0 := Vector3.ZERO


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.selected_tank = "falcon"
	for pi in PLAYERS.size():
		await _run_player(PLAYERS[pi])
	_print_table()
	var bad := _fails()
	print("VERDICT fail=%d / %d %s" % [bad, _rows.size(), "OK" if bad == 0 else "FAIL"])
	get_tree().quit(0 if bad == 0 else 1)


func _run_player(tank_idx: int) -> void:
	_main = get_node("Main")
	_main._sel_tank = tank_idx
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 10:
		await get_tree().physics_frame

	var p: Player = _main.player
	_yaw = _open_yaw(p, _main.arena)
	if _yaw == INF:
		print("VERDICT no open firing lane (%s)" % p.tank_id)
		return
	_p0 = p.global_position
	print("== %s  aim_y=%.2f" % [p.tank_id, p.aim_height])

	for et in ENEMIES:
		for d in DISTS:
			for m in MODES:
				_rows.append(await _run(p, int(et), float(d), String(m)))

	p.global_position = _p0
	_main._clear_battle()
	await get_tree().physics_frame


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [3.0, 7.0, 12.0]:
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


## 敌车的可见轮廓：车体顶面与耳轴（取自名册尺寸真值表，与模型同源）
func _hull_top(t: Tank) -> float:
	return float(TankRoster.dims(t.model_key())["hull"].y)


func _trunnion(t: Tank) -> float:
	return float(TankRoster.dims(t.model_key())["aim_y"])


func _run(p: Player, etype: int, d: float, mode: String) -> Dictionary:
	var ctr: Vector3 = _p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	var e := Enemy.new()
	e.configure(etype, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = DUMMY_HP
	e.set_physics_process(false)
	await get_tree().physics_frame
	e.global_position = ctr
	e.rotation.y = _yaw + PI

	var hull_top := _hull_top(e)
	var tr := _trunnion(e)
	var aim_h := 0.5 * hull_top
	var side := 0.0
	match mode:
		"top":
			aim_h = tr + 0.55
		"edge":
			aim_h = hull_top + 0.10
		"side":
			aim_h = tr
			side = 0.45

	var target: Vector3 = ctr + Vector3(-sin(_yaw + PI * 0.5), 0.0, -cos(_yaw + PI * 0.5)) * side
	target.y = ctr.y + aim_h
	var pivot: Vector3 = _p0 + Vector3(0, p.aim_height, 0)
	var to: Vector3 = target - pivot
	var flat := Vector2(to.x, to.z).length()

	var rig: CameraRig = _main.rig
	p.global_position = _p0
	p.rotation.y = _yaw
	p._speed = 0.0
	rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
	rig.aim_pitch = clampf(atan2(to.y, maxf(flat, 0.5)), Tank.PITCH_MIN, Tank.PITCH_MAX)
	rig.yaw = rig.aim_yaw
	rig.pitch = CameraRig.PITCH_BASE
	var want := rad_to_deg(rig.aim_pitch)

	for _i in SETTLE:
		p.global_position = _p0
		p.rotation.y = _yaw
		p._speed = 0.0
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		e.hp = DUMMY_HP
		await get_tree().physics_frame

	var on: bool = rig.aim_target() != null and rig.aim_target() != p
	var aim := rad_to_deg(rig.aim_pitch)
	var barrel := rad_to_deg(p.barrel.rotation.x)

	var hit := false
	var climb := 0.0
	var fired := false
	if on:
		p.reload_t = 0.0
		var spawn: Vector3 = p.shot_origin(p.aim_dir())
		fired = p.fire()
		var guard := 0
		while guard < 200:
			guard += 1
			await get_tree().physics_frame
			var any := false
			for c in _main.get_children():
				if c is Shell:
					any = true
					climb = maxf(climb, c.global_position.y - spawn.y)
			if not any:
				break
		hit = fired and e.hp < DUMMY_HP

	var row := {
		"player": p.tank_id, "etype": etype, "dist": d, "mode": mode,
		"hullTop": hull_top, "aimH": aim_h, "want": want, "aim": aim,
		"barrel": barrel, "on": on, "hit": hit, "climb": climb,
	}
	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
	return row


func _fails() -> int:
	var n := 0
	for r in _rows:
		if bool(r["on"]) and (not bool(r["hit"]) or float(r["climb"]) > 2.0):
			n += 1
	return n


func _print_table() -> void:
	print("---- CLOSE RANGE AIM/CONVERGE TABLE ----")
	print(" player etype dist  mode  hullTop aimH   want   aim barrel  on    climb hit")
	for r in _rows:
		print("%-7s %5d %4.1f %-6s %7.2f %5.2f %6.1f %5.1f %6.1f %-5s %6.2f %s" % [
			r["player"], r["etype"], r["dist"], r["mode"], r["hullTop"], r["aimH"],
			r["want"], r["aim"], r["barrel"],
			"tank" if bool(r["on"]) else "none", r["climb"],
			"tank" if bool(r["hit"]) else "MISS"])
