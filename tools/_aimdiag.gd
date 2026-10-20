extends Node
## 临时诊断：同一发瞄准重复多次，看命中是否随机丢（跳弹判定），
## 并打印每次的弹道终点与命中部位。

const CASES := [
	{"tank": 0, "d": 18.0, "lat": -1.25, "h": 1.1, "n": 10},
	{"tank": 0, "d": 18.0, "lat": 1.25, "h": 2.4, "n": 6},
	{"tank": 3, "d": 5.0, "lat": -1.25, "h": 1.1, "n": 10},
	{"tank": 1, "d": 12.0, "lat": 1.25, "h": 1.1, "n": 10},
	{"tank": 4, "d": 8.0, "lat": 1.25, "h": 2.4, "n": 10},
]

var _main: Node
var _yaw := 0.0
var _p0 := Vector3.ZERO


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	for c in CASES:
		await _run(int(c["tank"]), float(c["d"]), float(c["lat"]), float(c["h"]), int(c["n"]))
	get_tree().quit(0)


func _run(idx: int, d: float, lat: float, h: float, n: int) -> void:
	_main._sel_tank = idx
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
	_p0 = p.global_position
	print("\n===== %s d=%.1f lat=%.2f h=%.1f" % [p.tank_id, d, lat, h])

	var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var ctr: Vector3 = _p0 + fwd * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = 1000000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = 1000000
	e.set_physics_process(false)
	await get_tree().physics_frame

	var face: Vector3 = ctr - fwd * 1.25 + side * lat + Vector3(0, h, 0)
	var pivot: Vector3 = _p0 + Vector3(0, p.aim_height, 0)
	var to: Vector3 = face - pivot
	var rig: CameraRig = _main.rig
	rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
	rig.aim_pitch = clampf(atan2(to.y, maxf(Vector2(to.x, to.z).length(), 0.5)),
			Tank.PITCH_MIN, Tank.PITCH_MAX)
	rig.yaw = rig.aim_yaw
	p.rotation.y = rig.aim_yaw
	for _i in 24:
		_pin(p, e, ctr)
		await get_tree().physics_frame

	for k in n:
		_pin(p, e, ctr)
		e.hp = 1000000
		e.alive = true
		p.reload_t = 0.0
		var hp0: int = e.hp
		p.fire()
		var last := Vector3.ZERO
		var life := 0
		while life < 60 and _shell_count() > 0:
			await get_tree().physics_frame
			life += 1
			var s := _first_shell()
			if s != null:
				last = s.global_position
		print("  shot%d dmg=%3d aim=%.1f barrel=%.1f last=%s" % [
			k, hp0 - e.hp, rad_to_deg(rig.aim_pitch), rad_to_deg(p.barrel.rotation.x), str(last)])
		await get_tree().physics_frame

	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
	_main._clear_battle()
	await get_tree().physics_frame


func _pin(p: Player, e: Enemy, ctr: Vector3) -> void:
	p.global_position = _p0
	p._speed = 0.0
	e.global_position = ctr
	e.rotation.y = _yaw + PI


func _shell_count() -> int:
	var c := 0
	for ch in _main.get_children():
		if ch is Shell:
			c += 1
	return c


func _first_shell() -> Shell:
	for ch in _main.get_children():
		if ch is Shell:
			return ch
	return null


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for dd in [3.0, 6.0, 12.0, 18.0]:
			var pos: Vector3 = p.global_position + dir * dd
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
	return 0.0
