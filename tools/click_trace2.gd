extends Node
## 调试：复现 ClickProbe 里"点一下却没打出去"的行（anvil, frac=0.9）。
## 逐物理帧打印：state / alive / rt / buf / pressed / just。
##
## 用法：godot.exe --headless --path . res://tools/ClickTrace2.tscn

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 2
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
	# 第一行：frac=1.0，模拟 ClickProbe 的第一行
	await _row(p, 0.0)
	await _row(p, 0.1)
	get_tree().quit(0)


func _row(p: Player, remain: float) -> void:
	p.reload_t = p.reload_time * remain
	await get_tree().physics_frame
	print("== click  remain=%.3f rt=%.4f reload=%.3f state=%s alive=%s" % [
		remain, p.reload_t, p.reload_time, str(_main.state), str(p.alive)])
	_click(true)
	for i in 12:
		await get_tree().physics_frame
		if i == 3:
			_click(false)
		print("f%02d state=%s alive=%s rt=%.4f buf=%.3f press=%s just=%s" % [
			i, str(_main.state), str(p.alive), p.reload_t, p._fire_buffer,
			str(Input.is_action_pressed("fire")), str(Input.is_action_just_pressed("fire"))])
	for _i in 40:
		await get_tree().physics_frame
	print("   after 40f: rt=%.4f buf=%.3f" % [p.reload_t, p._fire_buffer])


func _click(down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = Vector2(480, 480)
	Input.parse_input_event(ev)
