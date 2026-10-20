extends Node
## 临时诊断：一次点击在物理帧里的完整状态轨迹。

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 2  # anvil
	_main._sel_diff = 0
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 8:
		await get_tree().physics_frame

	var p: Player = _main.player
	print("tank=%s reload=%.3f" % [p.tank_id, p.reload_time])

	p.reload_t = p.reload_time * 0.9
	await get_tree().physics_frame
	print("-- before click reload_t=%.4f alive=%s state=%s" % [p.reload_t, str(p.alive), str(_main.state)])

	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = Vector2(480, 480)
	Input.parse_input_event(ev)
	print("click pressed parsed")

	for i in 90:
		if i == 4:
			var up := InputEventMouseButton.new()
			up.button_index = MOUSE_BUTTON_LEFT
			up.pressed = false
			up.position = Vector2(480, 480)
			Input.parse_input_event(up)
			print("click released parsed")
		print("f%02d rt=%.4f buf=%.3f held=%s just=%s canfire=%s alive=%s"
				% [i, p.reload_t, p._fire_buffer,
				str(Input.is_action_pressed("fire")),
				str(Input.is_action_just_pressed("fire")),
				str(p.can_fire()), str(p.alive)])
		await get_tree().physics_frame
	get_tree().quit(0)
