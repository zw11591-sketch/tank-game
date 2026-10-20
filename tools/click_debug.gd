extends Node
## 临时诊断：复现 ClickProbe 里"点一下没反应"的那几行，逐帧打印输入状态。
##
## 顺序与 ClickProbe 完全一致：每款车 5 个装填进度都点一遍。

const FRACS := [1.0, 0.9, 0.5, 0.25, 0.0]

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_tank = 0  # lynx
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
	for f in FRACS:
		await _one(p, float(f))
	get_tree().quit(0)


func _one(p: Player, f: float) -> void:
	p.reload_t = p.reload_time * (1.0 - f)
	await get_tree().physics_frame
	print("\n==== f=%.2f rt=%.4f/%.4f state=%s alive=%s mouse=%d" % [
		f, p.reload_t, p.reload_time, str(_main.state), str(p.alive),
		int(Input.mouse_mode)])
	_click(true)
	var fired_at := -1
	for i in 40:
		var just: bool = Input.is_action_just_pressed("fire")
		var held: bool = Input.is_action_pressed("fire")
		if i == 4:
			_click(false)
		if fired_at < 0 and p.reload_t > p.reload_time * 0.9 and i > 0:
			fired_at = i
		print("  f%02d just=%s held=%s rt=%.4f buf=%.3f edge_ok=%s" % [
			i, str(just), str(held), p.reload_t, p._fire_buffer,
			str(Input.is_action_just_pressed("fire"))])
		await get_tree().physics_frame
	print("  -> fired_at=%d" % fired_at)
	# 与 ClickProbe 一样等装填过一半再继续
	var guard := 0
	while p.reload_t > p.reload_time * 0.5 and guard < 60:
		guard += 1
		await get_tree().physics_frame
	for _i in 60:
		await get_tree().physics_frame


func _click(down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = Vector2(480, 480)
	Input.parse_input_event(ev)
