extends Node
## 诊断（逐发）：近距离下一发敌方 AP 弹从哪里出发、指向哪、第一段射线打到了谁。
##
## 用法：godot.exe --headless --path . res://tools/ShellTrace.tscn

const DISTS := [3.0, 4.0, 5.0, 6.0, 10.0]

var _main: Node
var _yaw := 0.0
var _p0 := Vector3.ZERO


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
	_p0 = p.global_position
	print("== player r=%.2f  pivot=%.2f  muzzle=%s" % [
		p.body_radius, p.aim_height, str(p.muzzle_pos() - p.barrel.global_position)])

	for d in DISTS:
		await _one(p, float(d))
	get_tree().quit(0)


func _one(p: Player, d: float) -> void:
	p.hp = 1000000
	var ctr: Vector3 = _p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = 1000000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.rotation.y = _yaw + PI
	await get_tree().physics_frame

	for f in 40:
		p.global_position = _p0
		p.rotation.y = _yaw
		p._speed = 0.0
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		await get_tree().physics_frame

	p.global_position = _p0
	p.rotation.y = _yaw
	e.global_position = ctr
	e.rotation.y = _yaw + PI
	var aim: Vector3 = _p0 + Vector3(0, 1.5, 0)
	e.aim_at(aim, 0.016)
	e.reload_t = 0.0
	var base: Vector3 = e.barrel.global_position
	var dir: Vector3 = e.aim_dir()
	var origin: Vector3 = e.shot_origin(dir)
	var span := base.distance_to(e.muzzle_pos())
	var reach := (aim - base).dot(dir)
	print("\n-- dist %.1f  base=%s  span=%.2f  reach=%.2f  origin->playerCtr=%.2f  originY=%.2f  dirY=%.1f" % [
		d, str(base), span, reach,
		Vector2(origin.x - _p0.x, origin.z - _p0.z).length(), origin.y,
		rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))])
	e.fire()

	var hp0: int = p.hp
	for f in 60:
		await get_tree().physics_frame
		var shells := []
		for c in _main.get_children():
			if c is Shell:
				shells.append(c.global_position)
		if shells.is_empty():
			break
		if f % 4 == 0:
			print("   f%02d shell=%s  php=%d" % [f, str(shells[0]), p.hp])
	print("   RESULT dmg=%d" % (hp0 - p.hp))

	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame


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
