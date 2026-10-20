extends Node
## 临时诊断：车体贴墙、炮塔转向墙时，炮管有没有伸进砖墙。正俯视截图。
## 截图存 tools/shots/visclip/。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/visclip/"

var _main: Node
var _a: Arena
var _p: Player
var _cam: Camera3D


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 2      # anvil
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
	_p = _main.player
	_p.shield_t = 0.0
	_p.set_physics_process(false)
	_a = _main.arena
	DirAccess.make_dir_recursive_absolute(DIR)
	await _frames(2)

	_clear()
	for y in range(2, 22):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(4)

	_cam = Camera3D.new()
	_cam.fov = 40.0
	_cam.far = 200.0
	_main.add_child(_cam)
	_cam.current = true
	_main.hud.visible = false

	# 车心在 x=0.4（离墙面 1.6 m），车头朝 -Z，炮塔转向 +X（正对墙）
	_pose(Vector3(0.4, 0.0, Arena.cell_center(12, 12).z), 0.0, -PI * 0.5)
	await _shot("turret_into_wall")

	# 炮塔指向车头（沿墙平行）
	_pose(Vector3(0.4, 0.0, Arena.cell_center(12, 12).z), 0.0, 0.0)
	await _shot("turret_along_wall")

	print("PROBE visclip done")
	get_tree().quit(0)


func _pose(pos: Vector3, yaw: float, turret_yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos
	if _p.turret != null:
		_p.turret.rotation.y = turret_yaw
	_p._settle()
	_cam.global_transform = Transform3D(
			Basis(Vector3(1.0, 0.0, 0.0), -PI * 0.5),
			_p.global_position + Vector3(0.0, 18.0, 0.0))


func _shot(tag: String) -> void:
	for _i in 30:
		if _p.turret != null:
			pass
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(DIR + tag + ".png")
	print("PROBE shot %s pos=(%.2f,%.2f) hull_w=%.2f" % [
		tag, _p.global_position.x, _p.global_position.z, _p._hull_half_w])


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
