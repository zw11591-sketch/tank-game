extends Node
## 取景验收：玩家车在画面里到底占多高、有没有被下缘切掉。
##
## 判据来自设计值：第三人称下车体高度占比应 >= 0.33，且包围盒下缘必须在
## 画面内（min_y >= 0，max_y <= 1）。只看截图容易把"车看起来挺大"当成达标，
## 实际可能是车尾伸出画面、只量到了上半截。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会变乱码。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"
const TERRAINS := [0, 9]
const SETTLE := 90

var _idx := 0
var _f := 0
var _busy := false
## 探针会临时改画面设置，而 Main 的开局流程会 save_cfg()。
## 不还回去，每跑一次验收就会把本地界面缩放/窗口尺寸改成探针的那套。
var _prev := {}


func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	_prev = {
		"hud_scale": Settings.hud_scale,
		"display_mode": Settings.display_mode,
		"windowed_size": Settings.windowed_size,
		"brightness": Settings.brightness,
		"quality": Settings.quality,
	}
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.brightness = 1.0
	Settings.quality = Settings.Quality.HIGH
	# 界面缩放钉在 100%：它存在 user:// 里，本地可能被调到 200%，
	# 那样输出图是 960x540 的设计空间放大 2 倍，HUD 会比默认设置大一倍。
	Settings.hud_scale = 1.0
	Settings.apply_display()
	Settings.apply_render()
	DirAccess.make_dir_recursive_absolute(DIR)
	_start(0)


func _start(i: int) -> void:
	_idx = i
	_f = 0
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 2
	main._sel_terrain = TERRAINS[i]
	main._confirm_start()


func _physics_process(_d: float) -> void:
	if _busy:
		return
	var main := _main()
	if main == null or main.arena == null or main.player == null:
		return
	_f += 1
	if _f == 40:
		main.state = "play"
		if main.player != null:
			main.player.shield_t = 0.0
	if _f == 120:
		_measure(main)
		# 关卡横幅是过场提示，截图前抹掉：它是 HUD 叠加层，既不在取景判据里，
		# 又正好压在画面中央，留在图里只会让"车体占比"这张参考图读不出重点。
		main.banner_text = ""
		main._banner_t = 0.0
		await _shot("FRAME_%d_%s" % [_idx, str(Arena.TERRAINS[TERRAINS[_idx]]["layout"])])
		if _idx + 1 < TERRAINS.size():
			_start(_idx + 1)
		else:
			_restore_settings()
			get_tree().quit(0)


## 把 `_ready()` 里临时改掉的画面设置写回去。
func _restore_settings() -> void:
	Settings.hud_scale = _prev["hud_scale"]
	Settings.display_mode = _prev["display_mode"]
	Settings.windowed_size = _prev["windowed_size"]
	Settings.brightness = _prev["brightness"]
	Settings.quality = _prev["quality"]
	Settings.apply_display()
	Settings.apply_render()
	Settings.save_cfg()


func _measure(main) -> void:
	var p = main.player
	var cam: Camera3D = main.rig.cam
	var vp: Vector2 = get_viewport().get_visible_rect().size
	# 车体包围盒：以坦克原点为底，高约 3.2 m（含炮塔/天线基座）
	var w: float = p.body_radius * 2.0
	var l: float = p.body_length
	var h := 3.2
	var c: Vector3 = p.global_position
	var xs := [-w * 0.5, w * 0.5]
	var zs := [-l * 0.5, l * 0.5]
	var ys := [0.0, h]
	var min_p := Vector2(1e9, 1e9)
	var max_p := Vector2(-1e9, -1e9)
	for x in xs:
		for y in ys:
			for z in zs:
				var world: Vector3 = c + Vector3(x, y, z)
				if cam.is_position_behind(world):
					continue
				var sp := cam.unproject_position(world)
				min_p.x = minf(min_p.x, sp.x)
				min_p.y = minf(min_p.y, sp.y)
				max_p.x = maxf(max_p.x, sp.x)
				max_p.y = maxf(max_p.y, sp.y)
	var cov := (max_p.y - min_p.y) / vp.y
	print("FRAME %-10s cov=%.3f  y=[%.3f..%.3f]  x=[%.3f..%.3f]  camY=%.2f arm=%.2f fov=%.1f" % [
		str(Arena.TERRAINS[TERRAINS[_idx]]["layout"]), cov,
		min_p.y / vp.y, max_p.y / vp.y, min_p.x / vp.x, max_p.x / vp.x,
		cam.global_position.y, main.rig.arm.spring_length, cam.fov])


func _shot(tag: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")
	print("FRAME saved %s.png" % tag)
	_busy = false
