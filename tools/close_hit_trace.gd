extends Node
## 诊断：贴脸（3~5 m）时**敌方 AI** 的炮弹为什么一发都打不中玩家。
##
## DuelProbe 的表里 etype1 × 3.0 m 一行是 `shots=68 / dmg=0`：68 发全部落空。
## 本探针只截第一发，逐项打印：
##   aim_point / 炮管方向 / 出发点 / 起点是否在玩家体内 / 第一段射线打到什么
##
## 用法：godot.exe --headless --path . res://tools/CloseHitTrace.tscn

const DISTS := [3.0, 3.5, 4.0, 6.0]

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
	p.hp = 1000000
	_yaw = _open_yaw(p, _main.arena)
	print("player aim_y=%.2f radius=%.2f  yaw=%.1f" % [
		p.aim_height, p.body_radius, rad_to_deg(_yaw)])
	var p0: Vector3 = p.global_position

	for d in DISTS:
		await _run(p, p0, float(d))
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
	return 0.0


func _run(p: Player, p0: Vector3, d: float) -> void:
	var ctr: Vector3 = p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = 1000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = 1000
	e.rotation.y = _yaw + PI
	await get_tree().physics_frame

	var fired := false
	# 90 帧 = 0.75 s：AI 进入交战要 0.45 s 的反应延迟，窗口再短就一发都等不到。
	for f in 90:
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		e.reload_t = 0.0
		await get_tree().physics_frame
		if fired:
			continue
		for c in _main.get_children():
			if not (c is Shell):
				continue
			if c.shooter != e:
				continue
			fired = true
			var s: Shell = c
			var dir: Vector3 = s.vel.normalized()
			var from: Vector3 = s.global_position
			var to_p: Vector3 = p.global_position + Vector3(0, 1.2, 0) - from
			var q := PhysicsRayQueryParameters3D.create(
					from, from + dir * 40.0, Tank.LAYER_WORLD | Tank.LAYER_TANK)
			q.exclude = [e.get_rid()]
			var hit: Dictionary = get_viewport().world_3d.direct_space_state.intersect_ray(q)
			var dist_flat := Vector2(p.global_position.x - ctr.x, p.global_position.z - ctr.z).length()
			print("d=%.1f gap=%.2f | barrel=%.2f° aimpt=%s | from=%s | dirY=%.2f° | toPlayer=%s | 1stHit=%s" % [
				d, dist_flat - p.body_radius - e.body_radius,
				rad_to_deg(e.barrel.rotation.x), str(e.aim_point),
				str(from), rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))),
				str(to_p.normalized()), str(hit.get("collider", "none"))])
			print("    spawn inside player=%s  inside enemy=%s  travelToPlayer=%.2f" % [
				str(p._point_in_tank(from)), str(e._point_in_tank(from)), to_p.length()])

	# 统计 40 帧内的总伤害
	var dmg := 1000000 - p.hp
	p.hp = 1000000
	print("   -> dmg=%d" % dmg)
	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
