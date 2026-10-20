extends Node
## 临时诊断：车体网格逐节点打印"相对车体原点的包围盒"，与 Tank._measure_hull()
## 的结果对照，确认可见车体是否被碰撞矩形包住。打印标签全用 ASCII。

var _main: Node
var _a: Arena


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.spawn_queue.clear()
	_main.max_active = 0
	for e in _main.enemies.duplicate():
		e.queue_free()
		_main.enemies.erase(e)
	var p: Player = _main.player
	p.shield_t = 0.0
	p.set_physics_process(false)
	p.global_position = Vector3(0, 0, 0)
	p.rotation.y = 0.0
	_a = _main.arena
	await get_tree().physics_frame
	await get_tree().physics_frame

	for id in TankRoster.ORDER:
		var pl := Player.new()
		pl.tank_id = id
		pl.setup(_main, _a, Arena.cell_center(12, 12))
		add_child(pl)
		await get_tree().physics_frame
		await get_tree().physics_frame
		pl.set_physics_process(false)
		print("PROBE === %s measure=(%.3f, %.3f/%.3f) hull=(%.3f, %.3f/%.3f)" % [
			id, pl._measure_hull().x, pl._measure_hull().y, pl._measure_hull().z,
			pl._hull_half_w, pl._hull_half_f, pl._hull_half_b])
		pl.global_position = Vector3.ZERO
		pl.rotation.y = 0.0
		await get_tree().physics_frame
		_dump(pl, pl, 0)
		pl.queue_free()
		await get_tree().physics_frame
	get_tree().quit(0)


func _dump(root: Player, n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	if n is MeshInstance3D and n.mesh != null:
		var mi := n as MeshInstance3D
		var a: AABB = root._xf_under(root, mi) * mi.get_aabb()
		var keep: bool = root._counts_as_hull(mi) and not root._under_gun(mi)
		print("PROBE %s%s type=%s aabb pos=(%.2f,%.2f,%.2f) size=(%.2f,%.2f,%.2f) counts=%s gun=%s" % [
			pad, String(n.name), String(mi.mesh.get_class()),
			a.position.x, a.position.y, a.position.z,
			a.size.x, a.size.y, a.size.z,
			str(keep), str(root._under_gun(mi))])
	for c in n.get_children():
		_dump(root, c, depth + 1)
