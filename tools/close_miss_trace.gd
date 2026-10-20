extends Node
## 诊断：贴脸（3~4 m）时敌方那一发炮弹飞到哪里去了、为什么零伤害。
##
## 每帧打印炮弹位置、玩家 hp/alive、以及"从炮弹位置沿速度方向 2.5 m"的射线结果。
## 用法：godot.exe --headless --path . res://tools/CloseMissTrace.tscn

var _main: Node
var _yaw := 0.0


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
	var p0: Vector3 = p.global_position
	p.hp = 1000000
	print("player pos=%s alive=%s shield=%.1f radius=%.2f shapes=%d" % [
		str(p0), str(p.alive), p.shield_t, p.body_radius, _shape_count(p)])
	for c in p.get_children():
		if c is CollisionShape3D:
			var cs := c as CollisionShape3D
			var cyl := cs.shape as CylinderShape3D
			print("   shape rel=%s r=%.2f h=%.2f" % [
				str(cs.position), cyl.radius, cyl.height])

	for d in [3.0, 4.0]:
		await _one(p, p0, float(d))
	get_tree().quit(0)


func _shape_count(t: Tank) -> int:
	var n := 0
	for c in t.get_children():
		if c is CollisionShape3D:
			n += 1
	return n


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
	return 0.0


func _one(p: Player, p0: Vector3, d: float) -> void:
	var ctr: Vector3 = p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = 1000000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.rotation.y = _yaw + PI
	await get_tree().physics_frame

	for _i in 40:
		p.global_position = p0
		p.rotation.y = _yaw
		p._speed = 0.0
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		await get_tree().physics_frame

	p.global_position = p0
	p.rotation.y = _yaw
	e.global_position = ctr
	e.rotation.y = _yaw + PI
	var aim: Vector3 = p0 + Vector3(0, 1.5, 0)
	e.aim_at(aim, 0.016)
	e.reload_t = 0.0
	var dir: Vector3 = e.aim_dir()
	var origin: Vector3 = e.shot_origin(dir)
	print("\n-- d=%.1f base=%s origin=%s dir=%s" % [
		d, str(e.barrel.global_position), str(origin), str(dir)])
	# 手动沿弹道扫一遍点查询，看出发点之后每一米在谁体内
	for i in 8:
		var at: Vector3 = origin + dir * (float(i) * 0.5)
		print("     +%.1fm at=%s inP=%s inE=%s" % [
			float(i) * 0.5, str(at), str(p._point_in_tank(at)),
			str(e._point_in_tank(at))])
	e.fire()

	var hp0: int = p.hp
	for f in 12:
		await get_tree().physics_frame
		var lines: Array = []
		for c in _main.get_children():
			if not (c is Shell):
				continue
			var s: Shell = c
			var q := PhysicsRayQueryParameters3D.create(
					s.global_position, s.global_position + s.vel.normalized() * 2.5,
					Tank.LAYER_WORLD | Tank.LAYER_TANK)
			q.exclude = [e.get_rid(), s.get_rid()]
			var hit := get_viewport().world_3d.direct_space_state.intersect_ray(q)
			lines.append("%s vel=%s dmg=%d  ray-> %s" % [
				str(s.global_position), str(s.vel), s.damage,
				str(hit.get("collider", "none"))])
		print("  f%02d php=%d alive=%s shells=%d %s" % [
			f, p.hp, str(p.alive), lines.size(),
			("" if lines.is_empty() else str(lines[0]))])
	print("  RESULT dmg=%d" % (hp0 - p.hp))

	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
