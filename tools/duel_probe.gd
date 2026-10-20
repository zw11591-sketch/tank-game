extends Node
## 诊断：近距交火时**双方**炮口的俯仰与实际弹道——尤其是"炮台抬得太高、炮弹打到天上"。
##
## 与 near/aim 两个探针的区别：那里是玩家静止、靶车冻结；这里靶车 AI 照常开火，
## 于是能回答"两辆车贴得很近时，到底是谁的炮管抬起来了、弹道爬升多少"。
##
## 每一发炮弹记录：射手 / 炮管俯仰 / 发射方向仰角 / 起点高度 / 最大爬升 / 是否命中。
##
## 用法：godot.exe --headless --path . res://tools/DuelProbe.tscn

const DISTS := [3.0, 4.0, 6.0, 10.0]
const ETYPES := [1, 4]
const RUN_FRAMES := 150

var _main: Node
var _yaw := 0.0
var _p0 := Vector3.ZERO
var _rows: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.selected_tank = "falcon"
	_main = get_node("Main")
	_main._sel_tank = 1
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
		print("VERDICT no open lane")
		get_tree().quit(1)
		return
	_p0 = p.global_position
	print("== player %s aim_y=%.2f pitch=[%.1f, %.1f]" % [
		p.tank_id, p.aim_height, rad_to_deg(Tank.PITCH_MIN), rad_to_deg(Tank.PITCH_MAX)])

	for et in ETYPES:
		for d in DISTS:
			await _run(p, int(et), float(d))
	_print_table()
	get_tree().quit(0)


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [4.0, 8.0, 12.0]:
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


func _run(p: Player, etype: int, d: float) -> void:
	var ctr: Vector3 = _p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	var e := Enemy.new()
	e.configure(etype, 3, 1)
	e.max_hp = 1000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.rotation.y = _yaw + PI
	await get_tree().physics_frame
	p.hp = 1000000

	var shells: Dictionary = {}
	var first := true
	var pitch_sum := 0.0
	var pitch_n := 0
	var saw_pitch := 0.0

	for f in RUN_FRAMES:
		# 两辆车都钉在原地：测的是俯仰与弹道，不是 AI 的走位
		p.global_position = _p0
		p.rotation.y = _yaw
		p._speed = 0.0
		p.reload_t = 0.0
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		e.reload_t = 0.0
		_main.rig.aim_yaw = _yaw
		_main.rig.aim_pitch = 0.0
		await get_tree().physics_frame

		var eb := rad_to_deg(e.barrel.rotation.x)
		var to: Vector3 = p.global_position + Vector3(0, 1.1, 0) - (e.global_position + Vector3(0, e.aim_height, 0))
		var flat := Vector2(to.x, to.z).length()
		var ideal := rad_to_deg(atan2(to.y, maxf(flat, 0.5)))
		if f % 10 == 0:
			saw_pitch = eb
		pitch_sum += eb
		pitch_n += 1
		if first and f > 5:
			first = false

		for c in _main.get_children():
			if not (c is Shell):
				continue
			var s: Shell = c
			var id := s.get_instance_id()
			if not shells.has(id):
				shells[id] = {
					"owner": "enemy" if s.shooter == e else ("player" if s.shooter == p else "?"),
					"pitch": pitch_sum / maxf(pitch_n, 1),
					"dirY": rad_to_deg(asin(clampf(s.vel.normalized().y, -1.0, 1.0))),
					"y0": s.global_position.y,
					"ymax": s.global_position.y,
					"dist": flat,
				}
			var rec: Dictionary = shells[id]
			rec["ymax"] = maxf(float(rec["ymax"]), s.global_position.y)

		if e.alive and e.hp <= 0:
			break

	var enemy_shots := 0
	var climb_max := 0.0
	var up_shots := 0
	for k in shells.keys():
		var r: Dictionary = shells[k]
		if r["owner"] != "enemy":
			continue
		enemy_shots += 1
		climb_max = maxf(climb_max, float(r["ymax"]) - float(r["y0"]))
		if float(r["dirY"]) > 3.0:
			up_shots += 1

	_rows.append({
		"etype": etype, "dist": d,
		"pitch": pitch_sum / maxf(pitch_n, 1),
		"ideal": rad_to_deg(atan2(-(e.aim_height - 1.1), d)),
		"shots": enemy_shots, "up": up_shots, "climb": climb_max,
		"php": p.hp, "dmg": 1000000 - p.hp,
	})
	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame


func _print_table() -> void:
	print("---- DUEL TABLE (enemy AI at point blank, both pinned) ----")
	print(" etype dist  bPitch  ideal  shots  up  climb  dmgToPlayer")
	for r in _rows:
		print("%6d %4.1f %7.1f %6.1f %6d %3d %6.2f %12d" % [
			r["etype"], r["dist"], r["pitch"], r["ideal"], r["shots"], r["up"],
			r["climb"], r["dmg"]])
