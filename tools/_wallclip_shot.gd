extends Node
## 临时诊断：单格走廊里，看得见的车体比碰撞轮廓宽多少。
## 打印标签全用 ASCII；截图存 tools/shots/clip/。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/clip/"

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
	_cam.fov = 50.0
	_cam.far = 200.0
	_main.add_child(_cam)
	_cam.current = true
	_main.hud.visible = false

	await _shots()
	get_tree().quit(0)


func _shots() -> void:
	var a: Arena = _main.arena
	_clear(a)
	for y in range(3, 22):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
	await _settle(6)

	var p: Player = _main.player
	var home := Arena.cell_center(12, 12)
	_main.state = "ready"
	_main.state_timer = 1.0e9
	print("PROBE tank=%s blocks=%d" % [p.tank_id, a._blocks.size()])

	await _shot("center0", home, 0.0, false)
	print("PROBE proj cell(11,12)=(%.0f,%.0f) cell(12,12)=(%.0f,%.0f) cell(13,12)=(%.0f,%.0f) cell(12,9)=(%.0f,%.0f)" % [
		_p(Arena.cell_center(11, 12).x, Arena.cell_center(11, 12).z),
		_p(Arena.cell_center(12, 12).x, Arena.cell_center(12, 12).z),
		_p(Arena.cell_center(13, 12).x, Arena.cell_center(13, 12).z),
		_p(Arena.cell_center(12, 9).x, Arena.cell_center(12, 9).z)])
	await _shot("center0_noblocks", home, 0.0, true)
	await _shot("hug0", home + Vector3(-1.45, 0, 0), 0.0, false)
	await _shot("center45", home, deg_to_rad(45.0), false)
	await _shot("hug45", home + Vector3(-1.45, 0, 0), deg_to_rad(45.0), false)

	var aabb := _visual_aabb(p)
	print("PROBE model=%s visual_xz=(%.2f, %.2f) body_r=%.2f body_len=%.2f" % [
		p.model_key(), aabb.size.x, aabb.size.z, p.body_radius, p.body_length])


func _shot(tag: String, pos: Vector3, yaw: float, hide_arena: bool) -> void:
	var p: Player = _main.player
	var a: Arena = _main.arena
	a.visible = not hide_arena
	p.global_position = pos
	p.rotation.y = yaw
	p._speed = 0.0
	p.shield_t = 0.0
	_main.rig.aim_yaw = yaw
	_main.rig.aim_pitch = 0.0
	# 真正的正俯视：用显式基向量，避免 look_at 在近乎垂直时给出任意 roll
	_cam.global_transform = Transform3D(
			Basis(Vector3(1.0, 0.0, 0.0), -PI * 0.5),
			pos + Vector3(0.0, 26.0, 0.0))
	for _i in 24:
		p.shield_t = 0.0
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(DIR + tag + ".png")
	var sp := _cam.unproject_position(pos + Vector3(0, 1.0, 0))
	print("PROBE shot %-15s pos=(%.2f,%.2f) yaw=%5.1f screen=(%.0f,%.0f) arena_vis=%s" % [
		tag, pos.x, pos.z, rad_to_deg(yaw), sp.x, sp.y, a.visible])


func _visual_aabb(root: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in _meshes(root):
		if mi.name.begins_with("Shield") or mi.name.begins_with("Guide"):
			continue
		var a: AABB = mi.global_transform * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and n.mesh != null:
		out.append(n)
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		out.append_array(_meshes(c))
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

func _p(x: float, z: float) -> Vector2:
	return _cam.unproject_position(Vector3(x, 0.2, z))
