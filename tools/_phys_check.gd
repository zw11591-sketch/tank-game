extends Node
## 临时诊断：确认探针里的物理碰撞到底有没有生效。

var _main: Node


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
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1.0e9
	_main.player.shield_t = 0.0

	var a: Arena = _main.arena
	var p: Player = _main.player
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	for x in range(2, 22):
		a.grid[16][x] = Arena.STEEL
	a._rebuild_all()
	print("PROBE blocks=%d blocksTank(10,16)=%s steel=%d pos0=(%.1f,%.1f)" % [
		a._blocks.size(), str(a.blocks_tank(10, 16)), Arena.STEEL,
		p.global_position.x, p.global_position.z])
	print("PROBE layer=%d mask=%d mode=%d" % [p.collision_layer, p.collision_mask, p.motion_mode])

	p.global_position = Vector3(-2.0, 0.0, -6.0)
	p.rotation.y = 0.0
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = p.global_position
	await get_tree().physics_frame
	for i in 120:
		p.drive(1.0, 0.0, 1.0 / Engine.physics_ticks_per_second)
		if i % 12 == 0:
			print("PROBE i=%3d pos=(%.1f,%.1f) spd=%.1f slides=%d" % [
				i, p.global_position.x, p.global_position.z, p._speed,
				p.get_slide_collision_count()])
	print("PROBE end pos=(%.1f,%.1f)" % [p.global_position.x, p.global_position.z])
	get_tree().quit(0)
