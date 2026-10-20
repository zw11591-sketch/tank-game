extends Node
## 调试：InputSetup.edge() 在 120Hz 物理帧下对一次点击的判定序列。
##
## 用法：godot.exe --headless --path . res://tools/EdgeProbe.tscn

func _ready() -> void:
	await get_tree().process_frame
	for _i in 4:
		await get_tree().physics_frame
	_click(true)
	for i in 14:
		await get_tree().physics_frame
		if i == 3:
			_click(false)
		print("f%02d t=%d just=%s pressed=%s edge=%s" % [
			i, Time.get_ticks_msec(),
			str(Input.is_action_just_pressed("fire")),
			str(Input.is_action_pressed("fire")),
			str(InputSetup.edge("fire"))])
	get_tree().quit(0)


func _click(down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = Vector2(480, 480)
	Input.parse_input_event(ev)
