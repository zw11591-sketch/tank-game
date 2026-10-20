extends Node
## 临时诊断：从玩家实际视角看"坦克与墙的相对位置"。
## 打印标签全用 ASCII；截图存 tools/shots/clipview/。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/clipview/"

var _main: Node
var _cam: Camera3D


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	DirAccess.make_dir_recursive_absolute(DIR)
	await get_tree().process_frame

	_cam = Camera3D.new()
	_cam.fov = 60.0
	_cam.far = 300.0
	_main.add_child(_cam)
	_cam.current = true
	_main.hud.visible = false

	await _shots()
	get_tree().quit(0)


func _shots() -> void:
	var a: Arena = _main.arena
	_clear(a)
	# 只在车右侧放一格墙：碰撞圆（1.5 米）离墙 0.5 米，视觉上却已经压进墙里
	a.grid[12][14] = Arena.BRICK
	a._rebuild_all()
	await _settle(6)

	var p: Player = _main.player
	_main.state = "ready"
	_main.state_timer = 1.0e9
	var home := Arena.cell_center(12, 12)
	print("PROBE tank=%s blocks=%d" % [p.tank_id, a._blocks.size()])
	_dump_aabb(p)

	await _shot("one_wall_front", home, 0.0, Vector3(3.0, 3.0, 8.0))
	await _shot("one_wall_side", home, 0.0, Vector3(8.5, 5.0, 4.0))

	# 单格走廊：两侧各 0.5 米余量
	_clear(a)
	for y in range(2, 22):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
	await _settle(6)
	await _shot("corr_back", home, 0.0, Vector3(0, 4.2, 7.0))
	await _shot("corr_yaw30", home, deg_to_rad(30.0), Vector3(0, 6.5, 8.0))


func _shot(tag: String, pos: Vector3, yaw: float, cam_off: Vector3) -> void:
	var p: Player = _main.player
	p.global_position = pos
	p.rotation.y = yaw
	p._speed = 0.0
	p.shield_t = 0.0
	_main.rig.aim_yaw = yaw
	_main.rig.aim_pitch = 0.0
	_cam.global_position = pos + cam_off
	_cam.look_at(pos + Vector3(0, 1.0, 0))
	for _i in 20:
		p.shield_t = 0.0
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(DIR + tag + ".png")
	print("PROBE shot %-10s pos=(%.2f,%.2f) yaw=%5.1f" % [tag, pos.x, pos.z, rad_to_deg(yaw)])


func _dump_aabb(p: Node) -> void:
	var model: Node3D = p.get_node_or_null("tank_player")
	for child in p.get_children():
		if child is Node3D and String(child.name).begins_with("tank_"):
			model = child
	# 逐节点打印，找出到底哪一件最靠外
	for n in _all(model):
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			var a: AABB = mi.global_transform * mi.get_aabb()
			var rel: Vector3 = mi.global_transform.origin - p.global_position
			print("PROBE node %-22s sizeX=%5.2f dx=%+5.2f | sizeZ=%5.2f minZ=%+5.2f maxZ=%+5.2f dz=%+5.2f" % [
				mi.name, a.size.x, rel.x, a.size.z, a.position.z, a.end.z, rel.z])


func _all(n: Node) -> Array:
	var out: Array = []
	if n == null:
		return out
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all(c))
	return out


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _clear(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
