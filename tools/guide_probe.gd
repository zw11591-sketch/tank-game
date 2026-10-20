extends Node
## 临时验收：把车开到空地上、关掉护盾，在真实的默认视角下检查朝向标识是否一眼可辨。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"

var _f := 0
var _busy := false


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	DirAccess.make_dir_recursive_absolute(DIR)
	var main := get_tree().current_scene
	main._sel_diff = 1
	main._sel_stage = 0
	main._confirm_start()


func _shot(tag: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")
	var main := get_tree().current_scene
	var p: Player = main.player
	print("%-20s fp=%-5s gear=%+d speed=%5.1f hull=%+6.1f turret_rel=%+6.1f" % [
		tag, main.rig.first_person, p.gear(), p.speed_kmh(),
		rad_to_deg(p.rotation.y), rad_to_deg(p.turret.rotation.y)])
	_busy = false


func _physics_process(_d: float) -> void:
	_f += 1
	var main := get_tree().current_scene
	if main == null or main.player == null or _busy:
		return
	var p: Player = main.player

	if _f == 150:
		main.state = "play"
		p.shield_t = 0.0
	# 开到空地上再看，避免贴着墙取景
	if _f == 170:
		Input.action_press("move_forward")
	if _f == 290:
		Input.action_release("move_forward")
	if _f == 400:
		_shot("A_default_view")
	# 炮塔转到侧面：此时"炮管指向"与"车头指向"分离，正是容易混淆的情况
	if _f == 430:
		main.rig.aim_yaw = -PI * 0.5
	if _f == 560:
		_shot("B_turret_side")
	# 第一人称
	if _f == 600:
		main.rig.toggle_first_person()
	if _f == 730:
		_shot("C_first_person")
	if _f == 760:
		main.rig.toggle_first_person()
	# 倒车提示（默认视角下）
	if _f == 800:
		Input.action_press("move_back")
	if _f == 900:
		_shot("D_reverse")
	if _f == 930:
		Input.action_release("move_back")
	# 绕到车头前方看车头灯
	if _f == 1010:
		main.rig.set_process(false)
		main.rig.rotation.y = p.rotation.y + PI
		main.rig.arm.position = Vector3(0, 3.2, 0)
		main.rig.arm.spring_length = 10.0
		main.rig.arm.rotation.x = -deg_to_rad(14.0)
	if _f == 1050:
		_shot("E_front_view")
	if _f == 1080:
		get_tree().quit(0)
