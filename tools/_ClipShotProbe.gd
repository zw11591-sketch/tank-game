extends Node
## 临时诊断：把车"转到底/贴到墙"之后拍正俯视图，直接看车角有没有进砖墙。
## 截图存 tools/shots/clip/。打印标签全用 ASCII。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/clip/"
const STEP := 1.0 / 120.0

var _main: Node
var _cam: Camera3D
var _a: Arena
var _p: Player


func _ready() -> void:
	await get_tree().process_frame
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
	_p.set_physics_process(false)
	if _p._shield_mesh != null:
		_p._shield_mesh.visible = false
	for g in _p.get_children():
		if String(g.name).begins_with("Guide"):
			g.visible = false
	_a = _main.arena
	DirAccess.make_dir_recursive_absolute(DIR)
	await _frames(2)

	_cam = Camera3D.new()
	_cam.fov = 45.0
	_cam.far = 200.0
	_main.add_child(_cam)
	_cam.current = true
	_main.hud.visible = false

	# 1) 单格走廊：按住舵转到头
	_clear()
	for y in range(2, 24):
		_a.grid[y][11] = Arena.BRICK
		_a.grid[y][13] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	_reset(Arena.cell_center(12, 12), 0.0)
	for i in 300:
		_p.drive(0.0, 1.0, STEP)
	print("PROBE corridor pivot yaw=%.1f deep=%.3f" % [
		rad_to_deg(_p.rotation.y), _depth()])
	await _shot("pivot_in_corridor")

	# 2) 贴着单侧墙：一路开一路打舵
	_clear()
	for y in range(2, 24):
		_a.grid[y][12] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	_reset(Vector3(-2.15, 0.0, Arena.cell_center(11, 12).z), 0.0)
	for i in 600:
		_p.drive(1.0, 1.0, STEP)
	print("PROBE wall grind yaw=%.1f deep=%.3f pos=(%.2f,%.2f)" % [
		rad_to_deg(_p.rotation.y), _depth(), _p.global_position.x, _p.global_position.z])
	await _shot("grind_single_wall")

	# 3) 车鼻正对墙：全速顶上去
	_clear()
	for x in range(2, 24):
		_a.grid[14][x] = Arena.BRICK
	_a._rebuild_all()
	await _frames(2)
	_reset(Arena.cell_center(12, 10), 0.0)
	for i in 300:
		_p.drive(1.0, 0.0, STEP)
	print("PROBE nose ram yaw=%.1f deep=%.3f z=%.2f" % [
		rad_to_deg(_p.rotation.y), _depth(), _p.global_position.z])
	await _shot("nose_ram")

	get_tree().quit(0)


func _shot(tag: String) -> void:
	_cam.global_transform = Transform3D(
			Basis(Vector3(1.0, 0.0, 0.0), -PI * 0.5),
			_p.global_position + Vector3(0.0, 24.0, 0.0))
	for _i in 12:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(DIR + tag + ".png")
	print("PROBE shot %s saved" % tag)


func _reset(pos: Vector3, yaw: float) -> void:
	_p.global_position = pos
	_p.rotation.y = yaw
	_p._speed = 0.0
	_p.velocity = Vector3.ZERO
	_p._safe_pos = pos


func _clear() -> void:
	for n in _a._blocks.values():
		n.queue_free()
	_a._blocks.clear()
	_a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			_a.grid[y][x] = Arena.EMPTY


func _depth() -> float:
	var yaw: float = _p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var off := (_p._hull_half_f - _p._hull_half_b) * 0.5
	var center: Vector3 = _p.global_position + fwd * off
	var hl := (_p._hull_half_f + _p._hull_half_b) * 0.5
	var deep := 0.0
	for iz in 7:
		for ix in 7:
			var u := (float(ix) / 6.0 - 0.5) * 2.0
			var w := (float(iz) / 6.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * _p._hull_half_w) + fwd * (w * hl)
			var c := Arena.to_cell(pt)
			if not _a.blocks_tank(c.x, c.y):
				continue
			var cc := Arena.cell_center(c.x, c.y)
			var half := Arena.CELL * 0.5
			deep = maxf(deep, minf(half - absf(pt.x - cc.x), half - absf(pt.z - cc.z)))
	return deep


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame
