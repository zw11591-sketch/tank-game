extends Node
## 诊断：物理点查询在玩家车体上到底覆盖到哪。
##
## 用法：godot.exe --headless --path . res://tools/HitProbe.tscn

var _main: Node


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

	await get_tree().physics_frame
	var p: Player = _main.player
	var fwd: Vector3 = -p.global_transform.basis.z
	print("player pos=%s  fwd=%s  layer=%d  mask=%d" % [
		str(p.global_position), str(fwd), p.collision_layer, p.collision_mask])
	print("shapes:")
	for c in p.get_children():
		if c is CollisionShape3D:
			print("   %s r=%.2f h=%.2f rel=%s" % [
				(c.shape as CylinderShape3D).resource_name if false else "cyl",
				(c.shape as CylinderShape3D).radius, (c.shape as CylinderShape3D).height,
				str(c.global_position - p.global_position)])
	print("point query along forward (y=1.6):")
	var space := p.get_world_3d().direct_space_state
	for i in 13:
		var d := float(i) * 0.3
		var at: Vector3 = p.global_position + fwd * d + Vector3(0, 1.6, 0)
		var q := PhysicsPointQueryParameters3D.new()
		q.position = at
		q.collision_mask = Tank.LAYER_TANK
		var hits := space.intersect_point(q)
		print("   d=%.1f  hits=%d  %s" % [d, hits.size(),
			(str(hits[0]["collider"].name) if hits.size() > 0 else "-")])

	print("_point_in_tank() as called by shot_origin:")
	for i in 7:
		var d := 0.8 + float(i) * 0.2
		var at: Vector3 = p.global_position + fwd * d + Vector3(0, 1.72, 0)
		print("   d=%.2f  in=%s" % [d, str(p._point_in_tank(at))])

	print("ray from forward 0.5 toward forward 8:")
	var from: Vector3 = p.global_position + fwd * 0.5 + Vector3(0, 1.6, 0)
	var rq := PhysicsRayQueryParameters3D.create(
			from, p.global_position + fwd * 8.0 + Vector3(0, 1.6, 0),
			Tank.LAYER_WORLD | Tank.LAYER_TANK)
	var hit := space.intersect_ray(rq)
	print("   hit=%s" % (str(hit) if not hit.is_empty() else "none"))
	get_tree().quit(0)
