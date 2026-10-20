extends Node
## 验收：每张地形上，交战距离的敌车到底看不看得见。
##
## "看得见"不是主观感受，而是两个可以量出来的数：
##   1. 敌车所在像素块的平均亮度 —— 太低就是整块压成黑，车体细节无从读起；
##   2. 敌车与它紧邻背景的亮度差（韦伯对比度）—— 太低就是轮廓融进背景，
##      哪怕亮度够也挑不出"那里有一辆车"。
## 两者缺一不可：亮而无对比 = 白雾里的白车，暗而有对比 = 看得见但看不清。
##
## 做法：逐个地形开局，把一辆中型敌车放到玩家正前方 DIST 米、视线无遮挡处，
## 相机对准它，截一张图，量它和它左右两侧背景的亮度。
## 全程停在 "ready" 阶段，于是敌人不会开动，每张图的构图都可比。
##
## 截图需要真实窗口，无头模式出全黑图，所以这里开 1280x720 窗口跑。
## 打印标签全用 ASCII：中文经 PowerShell 管道会变乱码。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/vis/"
## 交战距离。中远距离才是"看不见敌人"真正发生的地方
const DIST := 45.0
## 生成后等多少帧再截图：SDFGI 要若干帧才收敛，太早截会偏暗
const SETTLE := 110
## 敌车像素块半边长。45 米处 3 米宽的车约占 32 像素，取 12 稳在车体内部
const PATCH := 12
## 背景取样环的内外半径（像素），贴着车体轮廓外侧
const BG_OFF := 70
## 敌车外接半径（米）。取样块与背景环都按它的投影尺寸缩放，
## 于是同一套判据在 26 米与 45 米上都成立
const HULL_RADIUS := 1.9
## 每张地形取几条视线方向
const LANES := 3
## 判据：敌车自身像素的平均亮度下限。低于它车体就压进黑场，
## 朝向、炮管、受击面都读不出来——玩家说的"太暗了，根本看不到敌人"就是这一条。
##
## 取 0.20：这是 arena.gd 里写的设计值。改造中曾把线放到 0.15 去迁就夜战市区，
## 但 0.15 的实测观感仍然是"一块深灰糊在背景上"，所以线不能再降，改成把暗图提亮。
const MIN_ENEMY_LUM := 0.20
## 观测项（不作判据）：敌车与紧邻轮廓外一圈背景的韦伯对比度。
## 亮度够而差值不够就是"迷彩生效"：车和地面同一个灰阶，轮廓挑不出来。
##
## 为什么只观测不判死：背景环取的是紧贴车体轮廓外侧 2.6~4.6 米的一圈，
## 那里经常落到另一块掩体、道具或明暗交界上，量出来的差值反映的是那一圈的
## 内容而不是车体的可辨识度——同一辆车换个朝向就能从 0.00 跳到 0.70（见 wAvg）。
## 所以它只打印出来看趋势，判据交给上面那条直接的亮度线。
const MIN_WEBER := 0.10
## 判据：整帧平均亮度下限。再暗的图也不该让玩家整屏只看见几块掩体
const MIN_SCENE_LUM := 0.15
## 放大验收图的裁剪半边长（像素）
const CROP := 48

var _rows: Array = []


func _main() -> Node:
	return get_node("Main")


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.brightness = 1.0
	Settings.quality = Settings.Quality.HIGH
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--quality="):
			Settings.quality = int(a.split("=")[1])
	print("QUALITY ", Settings.quality)
	Settings.apply_display()
	Settings.apply_render()
	DirAccess.make_dir_recursive_absolute(DIR)

	for t in Arena.TERRAINS.size():
		await _measure(t)

	print("---- VISIBILITY TABLE ----")
	print("   sceneLum >= %.2f  enemyLum >= %.2f  (worst of %d lanes x 2 headings)"
			% [MIN_SCENE_LUM, MIN_ENEMY_LUM, LANES])
	print("   wMin/wAvg = weber contrast (observed only, not a gate)")
	print("idx layout            sceneLum  eMin  eAvg   wMin  wAvg  dist verdict")
	var fails := 0
	for r in _rows:
		var bad := []
		if r["scene"] < MIN_SCENE_LUM:
			bad.append("BLACK")
		if r["emin"] < MIN_ENEMY_LUM:
			bad.append("DARK")
		# 韦伯对比度只标注、不判死（理由见 MIN_WEBER）：轮廓与背景同灰阶时打一个 flat
		if r["wmin"] < MIN_WEBER:
			bad.append("(flat)")
		var failed := false
		for b in bad:
			if b != "(flat)":
				failed = true
		if failed:
			fails += 1
		print("%2d  %-16s %7.4f %6.4f %6.4f %6.3f %5.3f %5.1f %s" % [
				r["idx"], r["layout"], r["scene"], r["emin"], r["eavg"],
				r["wmin"], r["wavg"], r["dist"],
				"ok" if bad.is_empty() else " ".join(bad)])
	print("VERDICT fail=%d / %d" % [fails, _rows.size()])
	get_tree().quit()


func _measure(idx: int) -> void:
	var main := _main()
	var layout := String(Arena.TERRAINS[idx]["layout"])
	seed(20261016 + idx)
	main._sel_diff = 1
	main._sel_stage = 2
	main._sel_terrain = idx
	main._confirm_start()
	# 停在倒计时阶段：敌人不开动，构图可比
	main.state = "ready"
	main.state_timer = 1.0e9
	# HUD 会压在取样区上：横幅与准星的像素比任何车体都亮，
	# 量到的就不再是"敌人看不看得见"而是"字看不看得见"
	main.hud.visible = false

	for _i in 6:
		await get_tree().process_frame

	var p = main.player
	var arena: Arena = main.arena
	var eye: Vector3 = p.global_position + Vector3(0, 1.8, 0)

	# 找通畅的几条视线方向。只量一条等于抽签：背后正好是一面亮墙还是一片暗地，
	# 能把对比度结论整个翻过来，所以多取几条再平均。
	var lanes: Array = []
	for want_dist in [DIST, 38.0, 32.0, 26.0]:
		for step in 120:
			var yaw: float = deg_to_rad(float(step) * 3.0)
			var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var pos: Vector3 = p.global_position + dir * float(want_dist)
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > 22 or c.y > 22:
				continue
			if arena.blocks_tank(c.x, c.y):
				continue
			if not arena.has_line_of_sight(eye, pos + Vector3(0, 1.8, 0)):
				continue
			# 相邻几度其实是同一条路，取样要分散开
			var dup := false
			for l in lanes:
				if absf(angle_difference(float(l["yaw"]), yaw)) < deg_to_rad(40.0):
					dup = true
					break
			if dup:
				continue
			lanes.append({"yaw": yaw, "dist": float(want_dist)})
			if lanes.size() >= LANES:
				break
		if lanes.size() >= LANES:
			break
	if lanes.is_empty():
		push_warning("terrain %d: no clear lane" % idx)
		return

	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.setup(main, arena, p.global_position)
	main.add_child(e)
	main.enemies.append(e)

	var lum_min := 1.0
	var lum_sum := 0.0
	var web_min := 9.0
	var web_sum := 0.0
	var scene := 0.0
	var ok := 0
	var shown := false
	for lane in lanes:
		var yaw: float = float(lane["yaw"])
		var dir2 := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var epos: Vector3 = p.global_position + dir2 * float(lane["dist"])
		# 第三人称镜头跟的是车体朝向，所以要把车头也转到这条通路上，
		# 否则敌车会落在画面外，量到的只是一块背景
		p.rotation.y = yaw
		main.rig.aim_yaw = yaw
		main.rig.aim_pitch = 0.0
		main.rig.yaw = yaw

		# 车体朝向决定哪一面对着相机，受光面与阴影面能差好几倍，
		# 所以每条路都把车正对与侧对各量一次，判据取最坏的那次——
		# 实战里敌车背光驶过的那一瞬间，正是"看不见"真正发生的时刻。
		for q in 2:
			e.rotation.y = yaw + PI * 0.5 * float(q)
			# 相机状态每帧强制写死。_process 里的跟随是按真实帧时长收拢的，
			# 不写死的话同一张图、同一辆车会因为机器负载不同而落在不同的取样位置，
			# 判据就从"这张图亮不亮"变成"这次跑得快不快"——实测同一张图能漂 0.03。
			for _i in SETTLE:
				e.global_position = epos
				main.rig.global_position = p.global_position
				main.rig.yaw = yaw
				main.rig.aim_yaw = yaw
				main.rig.pitch = CameraRig.PITCH_BASE
				main.rig.arm.position = CameraRig.PIVOT_NORMAL
				main.rig.arm.spring_length = CameraRig.ARM_NORMAL
				await get_tree().process_frame

			var img := get_viewport().get_texture().get_image()
			var ctr: Vector3 = epos + Vector3(0, 1.1, 0)
			# 视线通畅是从玩家车位置判的，而相机在车后 12 米、高 5 米，
			# 两者并不是同一条线：相机被掩体挡住时，取样块与背景环会同时量到
			# 那面墙，对比度自己把自己抹成 0。所以要从相机实际位置再验一次。
			var space := get_viewport().world_3d.direct_space_state
			var vq := PhysicsRayQueryParameters3D.create(
					main.rig.cam.global_position, ctr,
					Tank.LAYER_WORLD | Tank.LAYER_TANK)
			vq.exclude = [p.get_rid()]
			var vhit := space.intersect_ray(vq)
			if vhit.is_empty() or vhit["collider"] != e:
				continue
			var sp: Vector2 = main.rig.cam.unproject_position(ctr)
			# 车在屏幕上有多大必须由投影算出来，不能写死像素：
			# 取样块写死就会在近处只量到车体中心一小片、在远处把背景也圈进来，
			# 而"背景环"一旦压在车身上，对比度会被自己抹平成 0。
			var side: Vector3 = main.rig.cam.global_transform.basis.x * HULL_RADIUS
			var rad: float = maxf(sp.distance_to(main.rig.cam.unproject_position(ctr + side)), 4.0)
			var pr := int(rad * 0.55)
			var r0 := int(rad * 1.35)
			var r1 := int(rad * 2.4)
			if sp.x < r1 or sp.x > img.get_width() - r1 \
					or sp.y < r1 or sp.y > img.get_height() - r1:
				continue
			if not shown:
				shown = true
				img.save_png(DIR + "%02d_%s.png" % [idx, layout])
				scene = _frame_lum(img)
				# 45 米外的敌车只有三十来个像素宽，整帧图上肉眼也分辨不出来，
				# 所以再存一张放大的局部图——"看得见"最终还是要靠眼睛判一次
				var crop := img.get_region(Rect2i(
						int(sp.x) - CROP, int(sp.y) - CROP, CROP * 2, CROP * 2))
				crop.resize(CROP * 8, CROP * 8, Image.INTERPOLATE_NEAREST)
				crop.save_png(DIR + "%02d_%s_zoom.png" % [idx, layout])
				var mark := img.duplicate() as Image
				_box(mark, sp, pr, Color(0, 1, 0))
				_box(mark, sp, r0, Color(1, 0, 1))
				_box(mark, sp, r1, Color(1, 0, 1))
				mark.save_png(DIR + "%02d_%s_mark.png" % [idx, layout])
			var le := _patch(img, sp, pr)
			# 背景取紧贴车体轮廓外的一圈：这才是"车从背景里挑不挑得出来"，
			# 取远处一块地面量的是另一回事
			var lb := _ring(img, sp, r0, r1)
			var wb := absf(le - lb) / maxf(lb, 0.0001)
			lum_min = minf(lum_min, le)
			lum_sum += le
			web_min = minf(web_min, wb)
			web_sum += wb
			ok += 1

	if ok > 0:
		_rows.append({
			"idx": idx, "layout": layout, "scene": scene,
			"emin": lum_min, "eavg": lum_sum / float(ok),
			"wmin": web_min, "wavg": web_sum / float(ok),
			"dist": float(lanes[0]["dist"]),
		})

	e.alive = false
	main.enemies.erase(e)
	e.queue_free()


## 在验收图上画出取样框
func _box(img: Image, c: Vector2, r: int, col: Color) -> void:
	for d in range(-r, r + 1):
		for pt in [Vector2(c.x + d, c.y - r), Vector2(c.x + d, c.y + r),
				Vector2(c.x - r, c.y + d), Vector2(c.x + r, c.y + d)]:
			if pt.x >= 0 and pt.y >= 0 and pt.x < img.get_width() and pt.y < img.get_height():
				img.set_pixel(int(pt.x), int(pt.y), col)


## 以 c 为中心、内外半边长 r0..r1 的方环平均亮度（车体轮廓外的紧邻背景）
func _ring(img: Image, c: Vector2, r0: int, r1: int) -> float:
	var sum := 0.0
	var n := 0
	for y in range(int(c.y) - r1, int(c.y) + r1):
		for x in range(int(c.x) - r1, int(c.x) + r1):
			if absi(x - int(c.x)) < r0 and absi(y - int(c.y)) < r0:
				continue
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)


## 以 c 为中心、半边长 r 的方块平均亮度
func _patch(img: Image, c: Vector2, r: int) -> float:
	var sum := 0.0
	var n := 0
	for y in range(int(c.y) - r, int(c.y) + r):
		for x in range(int(c.x) - r, int(c.x) + r):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)


## 整帧平均亮度（降采样取样，够用且快）
func _frame_lum(img: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 6):
		for x in range(0, img.get_width(), 6):
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)
