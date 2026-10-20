extends Node
## 调试：一次"点一下"之后逐帧打印开火相关的状态，用来定位"点一下打两发"。
##
## 打印：reload_t / _fire_buffer / is_action_pressed / is_action_just_pressed
## 用法：godot.exe --headless --path . res://tools/ClickTrace.tscn

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
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
	p.reload_t = 0.0
	await get_tree().physics_frame

	print("== press (physics frame %d)" % Engine.get_physics_frames())
	Input.action_press("fire")
	for i in 40:
		await get_tree().physics_frame
		if i == 0:
			Input.action_release("fire")
			print("== release (frame %d)" % Engine.get_physics_frames())
		print("f%02d rt=%.3f buf=%.3f press=%s just=%s" % [
			i, p.reload_t, p._fire_buffer,
			str(Input.is_action_pressed("fire")),
			str(Input.is_action_just_pressed("fire"))])
	get_tree().quit(0)
