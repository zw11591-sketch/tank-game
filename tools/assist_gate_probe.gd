extends Node
## 临时诊断：_assist_target 的门槛在近距离侧向瞄准时判了什么。
## 复刻 CloseAimProbe 的摆位，逐个打印 along / side / 轴线端点 / gap。

const DISTS := [3.0, 3.9, 5.0, 8.0]
const LATS := [-1.25, 0.0, 1.25]
const HEIGHTS := [1.1, 2.4]

var _main: Node
var _yaw := 0.0
var _p0 := Vector3.ZERO


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
	_p0 = p.global_position
	var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var side := Vector3(-fwd.z, 0.0, fwd.x)

	for d in DISTS:
		var ctr: Vector3 = _p0 + fwd * float(d)
		var e := Enemy.new()
		e.configure(1, 3, 1)
		e.max_hp = 1000000
		e.setup(_main, _main.arena, ctr)
		_main.add_child(e)
		_main.enemies.append(e)
		e.hp = 1000000
		e.set_physics_process(false)
		await get_tree().physics_frame
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		p.global_position = _p0
		p.rotation.y = _yaw
		await get_tree().physics_frame

		for lat in LATS:
			for h in HEIGHTS:
				p.global_position = _p0
				p.rotation.y = _yaw
				e.global_position = ctr
				e.rotation.y = _yaw + PI
				var face: Vector3 = ctr - fwd * 1.25 + side * float(lat) + Vector3(0, float(h), 0)
				var pivot: Vector3 = _p0 + Vector3(0, p.aim_height, 0)
				var to: Vector3 = face - pivot
				_main.rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
				_main.rig.aim_pitch = clampf(atan2(to.y, maxf(Vector2(to.x, to.z).length(), 0.5)),
						Tank.PITCH_MIN, Tank.PITCH_MAX)
				var from: Vector3 = p.barrel.global_position
				var af := Vector2(-sin(_main.rig.aim_yaw), -cos(_main.rig.aim_yaw))
				var ar := Vector2(-af.y, af.x)
				var rel := Vector2(ctr.x - from.x, ctr.z - from.z)
				var along := rel.dot(af)
				var sd := rel.dot(ar)
				var gap := p._spine_gap(e, from, af)
				var ends: Array = e.spine()
				print("d=%.2f lat=%+.2f h=%.1f | along=%.2f side=%+.2f gap=%.2f gate=%.2f assist=%s | front=%s rear=%s" % [
					d, lat, h, along, sd, gap, e.body_radius + 0.45,
					str(p._assist_target() != null),
					str(ends[0]), str(ends[1])])
		e.alive = false
		_main.enemies.erase(e)
		e.queue_free()
		await get_tree().physics_frame
	get_tree().quit(0)


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
