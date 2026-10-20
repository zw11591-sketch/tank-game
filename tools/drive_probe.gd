extends Node
## 临时验收：镜头相对驾驶（Settings.drive_relative）。
##
## 分两部分：
##   1. 换算表 —— 直接喂给 Player._relative_drive()，核对每个方向键被译成的
##      油门/舵角。不依赖物理，结论是确定的。
##   2. 实跑 —— 每个方向都从同一块空地、同一个朝向、速度 0 起步，把真实位移
##      投到镜头坐标系里，看车究竟走向画面的哪一边。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"
## 每个方向按住多久（物理帧，120Hz）。0.8s 足够看出走向，又不至于绕出一个整圈
const BURST := 96

var _f := 0
var _busy := false
var _home := Vector3.ZERO
var _mark := Vector3.ZERO
var _mark_yaw := 0.0


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	Settings.drive_relative = true
	DirAccess.make_dir_recursive_absolute(DIR)
	var main := get_tree().current_scene
	main._sel_diff = 1
	main._sel_stage = 0
	main._confirm_start()


# ---------------- 1. 换算表 ----------------

func _table() -> void:
	var main := get_tree().current_scene
	var p: Player = main.player
	var hull: float = p.rotation.y
	print("PROBE table: row = camera yaw offset from hull nose, col = key")
	print("PROBE            W fwd            S back           A left           D right          W+A")
	for off_deg in [0.0, 30.0, -30.0, 90.0, 180.0]:
		main.rig.yaw = wrapf(hull + deg_to_rad(off_deg), -PI, PI)
		var cells: Array = []
		for key in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, -1), Vector2(0, 1), Vector2(1, -1)]:
			var c: Vector2 = p._relative_drive(key.x, key.y)
			cells.append("%-16s" % ("thr%+.2f st%+.2f" % [c.x, c.y]))
		print("PROBE cam%+6.0f  %s" % [off_deg, " ".join(cells)])
	main.rig.yaw = hull


# ---------------- 2. 实跑 ----------------

## 找一块 5x5 格全空的地面做试车场：否则车刚起步就撞墙，位移方向毫无意义
func _find_open() -> Vector3:
	var a = get_tree().current_scene.arena
	for y in range(3, Arena.GRID_H - 3):
		for x in range(3, Arena.GRID_W - 3):
			var ok := true
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if a.blocks_tank(x + dx, y + dy):
						ok = false
						break
				if not ok:
					break
			if ok:
				return Arena.cell_center(x, y)
	return Arena.cell_center(Arena.GRID_W / 2, Arena.GRID_H / 2)


## 重置到同一初始条件：同一块空地、朝向 0、速度 0、镜头与准星都对正车头。
## 否则上一次测试残留的转速与镜头偏角会污染结论。
func _reset_pose() -> void:
	var main := get_tree().current_scene
	var p: Player = main.player
	p.global_position = _home
	p.rotation.y = 0.0
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	main.rig.global_position = _home
	main.rig.yaw = 0.0
	main.rig.aim_yaw = 0.0
	_hold("")


## 以"此刻"的镜头朝向为测量基准开始按键。基准必须取按下那一刻的真实镜头朝向：
## 准星甩到侧面会把镜头拖走（CameraRig.FOLLOW_DEADZONE），用旧基准会得出假结论。
func _mark_now(key: String) -> void:
	var main := get_tree().current_scene
	_mark = main.player.global_position
	_mark_yaw = main.rig.yaw
	_hold(key)


func _begin(key: String) -> void:
	_reset_pose()
	_mark_now(key)


## 把位移投到起步那一刻的镜头坐标系：+上 = 画面上方，+右 = 画面右方
func _report(tag: String) -> void:
	var main := get_tree().current_scene
	var p: Player = main.player
	var d := p.global_position - _mark
	# 与 HUD.Radar._map 同一套换算：世界平面向量旋转 +yaw 进入镜头局部系，
	# 屏幕上 -Y 对应镜头正前方
	var flat := Vector2(d.x, d.z).rotated(_mark_yaw)
	print("PROBE %-15s screenUp%+6.2fm screenRight%+6.2fm gear%+d spd%5.1f camYaw%+7.1f hullYaw%+7.1f" % [
		tag, -flat.y, flat.x, p.gear(), p.speed_kmh(),
		rad_to_deg(_mark_yaw), rad_to_deg(p.rotation.y),
	])
	_hold("")


func _shot(tag: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")
	_busy = false


func _hold(a: String) -> void:
	for n in ["move_forward", "move_back", "turn_left", "turn_right"]:
		Input.action_release(n)
	if a != "":
		Input.action_press(a)


func _physics_process(_d: float) -> void:
	_f += 1
	var main := get_tree().current_scene
	if main == null or main.player == null or _busy:
		return
	var p: Player = main.player

	if _f == 150:
		main.state = "play"
		p.shield_t = 0.0
		_home = _find_open()
		_table()

	# W：应当朝画面上方走、挡位前进、车体不转
	if _f == 170:
		_begin("move_forward")
	if _f == 170 + BURST:
		_report("W_forward")
	# S：应当朝画面下方（退向镜头）走、挡位倒车、车体不该掉头
	if _f == 320:
		_begin("move_back")
	if _f == 320 + BURST:
		_report("S_reverse")
		_shot("R1_reverse")
	# A / D：应当朝画面左 / 右走
	if _f == 480:
		_begin("turn_left")
	if _f == 480 + BURST:
		_report("A_left")
	if _f == 640:
		_begin("turn_right")
	if _f == 640 + BURST:
		_report("D_right")
		_shot("R2_right")

	# 炮塔/准星甩到侧面后按 W：镜头会被准星拖走一截，车该走向"此刻画面的上方"
	if _f == 780:
		_reset_pose()
		main.rig.aim_yaw = -PI * 0.5
	if _f == 800:
		_mark_now("move_forward")
	if _f == 800 + BURST:
		_report("turretSide_W")
		_shot("R3_turret_side")

	# 第一人称：镜头与炮塔对齐，W 应当朝炮口方向开（即画面上方）
	if _f == 960:
		_reset_pose()
		main.rig.toggle_first_person()
		main.rig.aim_yaw = -PI * 0.5
	if _f == 1000:
		_mark_now("move_forward")
	if _f == 1000 + BURST:
		_report("firstPerson_W")
		_shot("R4_first_person")
	if _f == 1120:
		main.rig.toggle_first_person()

	# 关掉开关回到传统履带转向：A 应当原地转车、位移接近 0
	if _f == 1160:
		Settings.drive_relative = false
		_begin("turn_left")
	if _f == 1160 + BURST:
		_report("legacy_A_pivot")
	if _f == 1300:
		_begin("move_back")
	if _f == 1300 + BURST:
		_report("legacy_S")

	if _f == 1360:
		# 设置菜单新增的"驾驶方式"行：确认能读出、能切换、说明文本随之变化
		var rows: Array = Settings.option_rows()
		print("PROBE optRows=%d lastRowIsDrive=%s" % [
			rows.size(), str(rows[rows.size() - 1]["name"] == "驾驶方式")])
		Settings.adjust(rows.size() - 1, 1)
		print("PROBE afterToggle drive_relative=%s" % str(Settings.drive_relative))
		var txt := InputSetup.controls_text(Settings.drive_relative)
		print("PROBE controlsText len=%d mentionsAuto=%s" % [
			txt.length(), str(txt.contains("自动转向"))])

	if _f == 1400:
		get_tree().quit(0)
