extends Node
## 临时诊断 3：逐个网格打印局部包围盒，核对车体轮廓测量有没有漏掉可见部件。

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	_main._sel_tank = 0
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	var p: Player = _main.player
	p.shield_t = 0.0
	for _i in 8:
		await get_tree().physics_frame

	print("PROBE measured w=%.3f f=%.3f b=%.3f" % [p._hull_half_w, p._hull_half_f, p._hull_half_b])
	var hull := AABB()
	var first := true
	for mi in _meshes(p):
		var box: AABB = p._xf_under(p, mi) * mi.get_aabb()
		var is_hull: bool = p._counts_as_hull(mi) and not p._under_gun(mi)
		var path := str(p.get_path_to(mi))
		print("MESH %-42s hull=%s x[%6.2f,%6.2f] y[%5.2f,%5.2f] z[%6.2f,%6.2f]" % [
			path, str(is_hull), box.position.x, box.position.x + box.size.x,
			box.position.y, box.position.y + box.size.y,
			box.position.z, box.position.z + box.size.z])
		if is_hull:
			hull = hull.merge(box) if not first else box
			first = false
	print("PROBE hullbox x[%.2f,%.2f] z[%.2f,%.2f]" % [
		hull.position.x, hull.position.x + hull.size.x,
		hull.position.z, hull.position.z + hull.size.z])
	get_tree().quit(0)


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D and n.mesh != null and n.visible:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
