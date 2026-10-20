extends Node
## 临时诊断：CloseAimProbe 里"侧向瞄准、低处"这一行为什么打空。
## 摆一辆靶车在正前方 d 米，准星压到它正面靠边的一点，开一炮，逐帧打印弹道。

const D := 5.0
const LAT := 1.25
const AIMY := 1.1

var _main: Node
var _yaw := 0.0


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
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
	p.rotation.y = _yaw
	var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var ctr: Vector3 = p0 + fwd * D
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = 1000000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = 1000000
	e.set_physics_process(false)
	await get_tree().physics_frame

	var face: Vector3 = ctr - fwd * 1.25 + side * LAT + Vector3(0, AIMY, 0)
	var pivot: Vector3 = p0 + Vector3(0, p.aim_height, 0)
	var to: Vector3 = face - pivot
	var flat := Vector2(to.x, to.z).length()
	var ideal := atan2(to.y, maxf(flat, 0.5))
	var rig: CameraRig = _main.rig
	rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
	rig.aim_pitch = clampf(ideal, Tank.PITCH_MIN, Tank.PITCH_MAX)
	rig.yaw = rig.aim_yaw
	rig.pitch = CameraRig.PITCH_BASE

	for i in 24:
		p.global_position = p0
		p.rotation.y = _yaw
		p._speed = 0.0
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		await get_tree().physics_frame

	print("player=%s ctr=%s face=%s" % [str(p0), str(ctr), str(face)])
	print("aim_yaw=%.2f deg aim_pitch=%.2f barrel=%.2f turret=%.2f" % [
		rad_to_deg(rig.aim_yaw), rad_to_deg(rig.aim_pitch),
		rad_to_deg(p.barrel.rotation.x), rad_to_deg(p.turret.rotation.y)])
	print("barrel_pos=%s aim_dir=%s aim_point=%s" % [
		str(p.barrel.global_position), str(p.aim_dir()), str(p.aim_point)])
	print("muzzle=%s shot_origin=%s" % [str(p.muzzle.global_position),
		str(p.shot_origin(p.aim_dir()))])
	print("assist=%s" % str(p._assist_target()))
	print("enemy=%s alive=%s layer=%d shapes=%d" % [
		str(e.global_position), str(e.alive), e.collision_layer,
		_shape_count(e)])
	for c in e.get_children():
		if c is CollisionShape3D:
			var cs := c as CollisionShape3D
			var cyl := cs.shape as CylinderShape3D
			print("   shape rel=%s global=%s r=%.2f h=%.2f" % [
				str(cs.position), str(cs.global_position), cyl.radius, cyl.height])
	var o0: Vector3 = p.shot_origin(p.aim_dir())
	var d0: Vector3 = p.aim_dir()
	var q0 := PhysicsRayQueryParameters3D.create(
			o0, o0 + d0 * 20.0, Tank.LAYER_WORLD | Tank.LAYER_TANK)
	q0.exclude = [p.get_rid()]
	print("probe ray from origin -> %s" % str(
			get_viewport().world_3d.direct_space_state.intersect_ray(q0)))

	p.reload_t = 0.0
	var fired: bool = p.fire()
	print("fired=%s hp=%d" % [str(fired), e.hp])
	for f in 40:
		await get_tree().physics_frame
		var lines: Array = []
		for c in _main.get_children():
			if not (c is Shell):
				continue
			var s: Shell = c
			var q := PhysicsRayQueryParameters3D.create(
					s.global_position, s.global_position + s.vel.normalized() * 4.0,
					Tank.LAYER_WORLD | Tank.LAYER_TANK)
			q.exclude = [p.get_rid()]
			var hit := get_viewport().world_3d.direct_space_state.intersect_ray(q)
			lines.append("pos=%s -> %s (%s)" % [str(s.global_position),
				str(hit.get("collider", "none")), str(hit.get("position", ""))])
		print("f%02d ehp=%d shells=%d %s" % [f, e.hp, lines.size(),
			("" if lines.is_empty() else str(lines[0]))])
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
		for d in [3.0, 6.0, 12.0, 18.0]:
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
