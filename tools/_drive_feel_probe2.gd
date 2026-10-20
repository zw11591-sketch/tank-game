extends Node
## 临时诊断 2：在真实生成的关卡里乱开，统计车体压进墙的深度分布 + 模型实际轮廓核对。
## 全 ASCII 输出。

var _main: Node
var _a: Arena
var _p: Player
var _dt := 1.0 / 120.0


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
	_p = _main.player
	_p.shield_t = 0.0
	_a = _main.arena
	await _frames(10)

	print("PROBE hull w=%.3f f=%.3f b=%.3f" % [_p._hull_half_w, _p._hull_half_f, _p._hull_half_b])
	_mesh_check()

	# 真实地图乱开：3 组输入交替，各 6 秒
	var keys := [
		Vector2(1, 0), Vector2(1, 1), Vector2(1, -1),
		Vector2(1, 0), Vector2(1, -1), Vector2(1, 1),
		Vector2(0, 1), Vector2(1, 0), Vector2(-1, 1),
	]
	var worst := 0.0
	var worst_at := ""
	var over06 := 0
	var over12 := 0
	var over18 := 0
	var blocked := 0
	var total := 0
	for k in keys:
		for i in 720:
			_p.drive(k.x, k.y, _dt)
			total += 1
			var d := _p._hull_depth(_p.rotation.y)
			if _p.turn_blocked:
				blocked += 1
			if d > 0.06:
				over06 += 1
			if d > 0.12:
				over12 += 1
			if d > 0.18:
				over18 += 1
			if d > worst + 1e-4:
				worst = d
				var c := Arena.to_cell(_p.global_position)
				worst_at = "cell=%s pos=(%.1f,%.1f) yaw=%.0fdeg want=%s" % [
					str(c), _p.global_position.x, _p.global_position.z,
					rad_to_deg(_p.rotation.y), str(k)]
	print("PROBE drift frames=%d blocked=%d over6cm=%d over12cm=%d over18cm=%d worst=%.3f %s" % [
		total, blocked, over06, over12, over18, worst, worst_at])
	get_tree().quit(0)


## 模型所有可见网格（含炮塔/炮管）在车体局部坐标里的包围盒，核对 _hull_half_*。
func _mesh_check() -> void:
	var hull := AABB()
	var all := AABB()
	var first_h := true
	var first_a := true
	var turret_box := AABB()
	var first_t := true
	for mi in _meshes(_p):
		var box: AABB = _p._xf_under(_p, mi) * mi.get_aabb()
		all = all.merge(box) if not first_a else box
		first_a = false
		if not _p._counts_as_hull(mi):
			turret_box = turret_box.merge(box) if not first_t else box
			first_t = false
			continue
		hull = hull.merge(box) if not first_h else box
		first_h = false
	print("PROBE mesh hull  x[%.2f,%.2f] z[%.2f,%.2f]" % [
		hull.position.x, hull.position.x + hull.size.x,
		hull.position.z, hull.position.z + hull.size.z])
	print("PROBE mesh all   x[%.2f,%.2f] z[%.2f,%.2f]" % [
		all.position.x, all.position.x + all.size.x,
		all.position.z, all.position.z + all.size.z])
	if not first_t:
		print("PROBE mesh nongun x[%.2f,%.2f] z[%.2f,%.2f]" % [
			turret_box.position.x, turret_box.position.x + turret_box.size.x,
			turret_box.position.z, turret_box.position.z + turret_box.size.z])


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D and n.mesh != null and n.visible:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
