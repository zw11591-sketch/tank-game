extends Node
## 临时诊断：用真实第三人称镜头拍"贴墙"时看得见的穿插。
## 截图存 tools/shots/visclip/。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/visclip/"

var _main: Node
var _a: Arena
var _p: Player


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
	_main.spawn_queue.clear()
	_main.max_active = 0
	for e in _main.enemies.duplicate():
		e.queue_free()
		_main.enemies.erase(e)
	_p = _main.player
	_p.shield_t = 0.0
	_a = _main.arena
	DirAccess.make_dir_recursive_absolute(DIR)
	await _frames(4)

	_clear()
	for y in range(2, 22):
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(4)

	# 1) 贴墙平行停：墙在 x=+2，车心 x=0.4（离墙面 1.6 m）
	_reset(Vector3(0.4, 0.0, Arena.cell_center(12, 12).z), 0.0)
	await _aim_at_wall()
	await _shot("hug_turret_into_wall")

	# 2) 全速正撞墙
	_reset(Arena.cell_center(12, 15), 0.0)
	for i in 240:
		_p.drive(1.0, 0.0, 1.0 / 120.0)
	await _aim_forward()
	await _shot("nose_into_wall")

	# 3) 一边开一边打舵（贴墙磨）
	_reset(Vector3(0.4, 0.0, Arena.cell_center(12, 18).z), 0.0)
	for i in 360:
		_p.drive(1.0, 1.0, 1.0 / 120.0)
	await _shot("grind_wall")

	print("PROBE visclip done")
	get_tree().quit(0)


func _aim_at_wall() -> void:
	# 炮塔指向 +X（墙的方向）
	for i in 120:
		_p.aim_at(Vector3(12.0, 1.6, _p.global_position.z), 1.0 / 120.0)
		await get_tree().physics_frame


func _aim_forward() -> void:
	# 炮塔转到车头方向（-Z）
	for i in 120:
		_p.aim_at(_p.global_position + Vector3(0, 1.6, -12.0), 1.0 / 120.0)
		await get_tree().physics_frame


func _shot(tag: String) -> void:
	# 把镜头摆到车后上方，模拟玩家视角
	var back := _p.global_transform.basis.z.normalized()
	var cam := _main.rig.get_node_or_null("Cam") as Camera3D
	if cam == null:
		cam = _main.get_viewport().get_camera_3d()
	for _i in 30:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(DIR + tag + ".png")
	print("PROBE shot %s pos=(%.2f,%.2f) yaw=%.1f" % [
		tag, _p.global_position.x, _p.global_position.z, rad_to_deg(_p.rotation.y)])


func _reset(pos: Vector3, yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos
	_main.rig.reset_to(_p)


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
