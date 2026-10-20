extends Node
## 临时验收：夜战市区能不能看见敌人。
##
## 无头模式不出图，所以这里开真实窗口，跑到敌人推进到交战距离后，
## 把相机摆到最近一辆敌车的方向上截图。
## old=true 时把光照手动改回修复前的数值（sun 0.42 / ambient 0.34 / fog 0.0095 近黑），
## 于是同一个局面有「修复前/修复后」两张可以并排比的图。
##
## 顺便把敌车所在屏幕区域与其周边背景的亮度算出来：
## 看得见不是主观判断，而是这两个数字的差。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"

var _f := 0
var _busy := false
var _old := false


func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1600, 900)
	Settings.apply_display()
	DirAccess.make_dir_recursive_absolute(DIR)
	seed(20261016)
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 3
	main._sel_terrain = 9
	main._confirm_start()


func _physics_process(_d: float) -> void:
	if _busy:
		return
	_f += 1
	if _f == 900:
		_busy = true
		await _shot("NIGHT_after")
		_apply_old()
		_busy = false
	elif _f == 960:
		_busy = true
		await _shot("NIGHT_before")
		get_tree().quit()


## 把光照改回修复前的数值
func _apply_old() -> void:
	var arena = _main().arena
	arena._env.ambient_light_energy = 0.34
	arena._env.fog_light_color = Color(0.08, 0.10, 0.16)
	arena._env.fog_density = 0.0095
	arena._env.volumetric_fog_albedo = Color(0.08, 0.10, 0.16).lightened(0.15)
	arena._env.volumetric_fog_density = clampf(0.0095 * 3.4, 0.006, 0.03)
	arena._sun.light_energy = 0.42
	arena._sun.light_color = Color(0.56, 0.66, 1.00)
	arena._fill.light_energy = 0.3
	arena._fill.light_color = Color(0.30, 0.40, 0.72)


func _shot(tag: String) -> void:
	var main := _main()
	var p = main.player
	# 相机转向最近的一辆敌车，让它落在画面中央
	var best = null
	var bd := 1e9
	for e in main.enemies:
		if not is_instance_valid(e) or not e.alive:
			continue
		var d: float = p.global_position.distance_to(e.global_position)
		if d < bd:
			bd = d
			best = e
	if best != null:
		var to: Vector3 = best.global_position - p.global_position
		main.rig.aim_yaw = atan2(-to.x, -to.z)
		main.rig.aim_pitch = 0.0
	for _i in 8:
		await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	img.save_png(DIR + tag + ".png")

	# 敌车所在屏幕位置周边的亮度 vs 画面同高度两侧背景的亮度
	var lum_t := -1.0
	var lum_b := -1.0
	if best != null:
		var sp: Vector2 = main.rig.cam.unproject_position(
				best.global_position + Vector3(0, 1.0, 0))
		lum_t = _patch_lum(img, sp, 26)
		lum_b = 0.5 * (_patch_lum(img, sp + Vector2(280, 0), 26)
				+ _patch_lum(img, sp - Vector2(280, 0), 26))
	print("SHOT ", tag, " dist=", snappedf(bd, 0.1),
			" enemyLum=", snappedf(lum_t, 0.0001),
			" bgLum=", snappedf(lum_b, 0.0001),
			" contrast=", snappedf(absf(lum_t - lum_b) / maxf(lum_b, 0.0001), 0.001))


## 以 c 为中心、半边长 r 的方块的平均亮度
func _patch_lum(img: Image, c: Vector2, r: int) -> float:
	var sum := 0.0
	var n := 0
	for y in range(int(c.y) - r, int(c.y) + r):
		for x in range(int(c.x) - r, int(c.x) + r):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)
