extends Node
## 冒烟测试（开发期工具，不参与正式运行）：跳过标题菜单直接开一关，跑若干物理帧，
## 期间触发开火 / 切弹 / 冲刺 / 烟雾、暂停菜单与 HUD 重绘，捕捉运行时报错。
##
## 它需要主场景已经构建完毕，所以只能以 autoload 的形式挂载。用法是**临时**在
## project.godot 的 [autoload] 段加一行，跑完立刻删掉：
##
##     Smoke="*res://tools/smoke_test.gd"
##     godot.exe --headless --path .
##
## 千万不要把这一行留在 project.godot 里——它会抢走启动流程，让正式版跳过标题菜单。

var _frames := 0


func _ready() -> void:
	await get_tree().process_frame
	var main := get_tree().current_scene
	if main == null:
		print("SMOKE: no scene")
		get_tree().quit(1)
		return
	main._sel_diff = 1
	main._sel_stage = 0
	main._confirm_start()
	print("SMOKE: stage started, state=", main.state)


func _physics_process(_d: float) -> void:
	_frames += 1
	var main := get_tree().current_scene
	if main == null:
		return
	if _frames == 60:
		main.state = "play"
	if _frames == 120:
		if main.player != null and is_instance_valid(main.player):
			main.player.drive(1.0, 0.3, 1.0 / 120.0)
			main.player.aim_at(main.player.global_position + Vector3(10, 1, -10), 1.0 / 120.0)
			main.player.fire()
			main.player.toggle_shell()
			main.player._start_boost()
			main.player._drop_smoke()
			print("SMOKE: player ok speed=", main.player.speed_kmh(), " gear=", main.player.gear())
		else:
			print("SMOKE: player missing")
	if _frames == 150:
		main._set_pause(true)
		main._move_option(1)
		main._adjust_option(1)
		print("SMOKE: pause menu ok")
	if _frames == 160:
		main._set_pause(false)
	if _frames >= 200:
		print("SMOKE: done state=", main.state, " enemies=", main.enemies.size())
		get_tree().quit(0)
