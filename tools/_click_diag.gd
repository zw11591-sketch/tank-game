extends Node
## 临时诊断：一次点按为什么会打出两发。

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 1
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

	for round in 3:
		p.reload_t = 0.0
		await get_tree().physics_frame
		var before := p.shot_count
		var t0 := Time.get_ticks_msec()
		print("--- round %d reload=%.3f" % [round, p.reload_time])
		_click(true)
		for i in 12:
			await get_tree().physics_frame
			if p.shot_count != before:
				before = p.shot_count
				print("   SHOT at %dms frame=%d held=%s pend=%s latch=%s buf_edge=%s rt=%.3f" % [
					Time.get_ticks_msec() - t0, i, str(Input.is_action_pressed("fire")),
					str(p._pending_shot), str(p._fire_latch),
					str(Input.is_action_just_pressed("fire")), p.reload_t])
			if i == 3:
				_click(false)
				print("   release at %dms held=%s" % [Time.get_ticks_msec() - t0,
						str(Input.is_action_pressed("fire"))])
	get_tree().quit(0)


func _click(down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = Vector2(480, 480)
	Input.parse_input_event(ev)
