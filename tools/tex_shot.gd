extends Node
## 贴图验收：把车库转台的相机推到 1.5 米以内，逐个车型拍装甲表面的特写。
##
##   godot.exe --path . res://tools/TexShot.tscn
##
## 为什么单开一个工具：GarageShot 的机位是"整车入镜"，一台车只占两百来像素，
## 拼缝、铆钉、划痕这些**几厘米级**的细节在那个尺度下全糊成一团，
## 于是"贴图有没有接上、法线方向对不对、图案有没有明显的平铺接缝"
## 这三个最容易出错的地方都没有证据可看。特写就是给它们留的证据。
##
## 每台车拍两张：车体侧面（看拼缝与迷彩）与炮塔/炮管（看金属件与焊缝）。
## 转台在 main.gd 的 _process 里持续自转，所以截图前把角度钉死，
## 否则两张图的朝向来自不同帧，没法对比。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"

## 侧面：贴着车体看迷彩与拼缝。转台角固定为 0，于是车体侧面正对相机、
## 侧面装甲板在 x=±1.7，相机放在 3.35 就是离装甲板 1.6 米。
const SIDE_POS := Vector3(3.35, 1.00, 0.75)
const SIDE_LOOK := Vector3(0.0, 0.90, 0.15)
## 炮管：看金属件的轧制纹与划痕。车头朝 -Z，炮口在 z≈-4.0、高度 ≈1.95。
const GUN_POS := Vector3(1.75, 1.65, -2.30)
const GUN_LOOK := Vector3(0.0, 1.90, -2.30)
## 转台固定的角度。两张图必须来自同一朝向才可比。
const YAW := 0.0

var _main: Node
var _cam: Camera3D
var _idx := 0
var _f := 0
var _busy := false


func _ready() -> void:
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1600, 900)
	Settings.apply_display()
	DirAccess.make_dir_recursive_absolute(DIR)
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)
	print("TEX start")
	_main._enter_select()
	# 转台默认只有 760x440，特写需要分辨率，不然看的是插值而不是贴图
	_main._preview_vp.size = Vector2i(1280, 860)
	_pick(0)


func _pick(i: int) -> void:
	_idx = i
	_f = 0
	_main._sel_row = 0
	_main._sel_tank = i
	_main._refresh_select()


func _physics_process(_d: float) -> void:
	if _busy:
		return
	_f += 1
	# 模型与光照要等若干帧才在 SubViewport 里就位
	if _f < 30:
		return
	if _cam == null:
		for c in _main._preview_vp.get_children():
			if c is Camera3D:
				_cam = c
		if _cam == null:
			print("TEX FATAL 找不到转台相机")
			get_tree().quit(1)
			return
	var key: String = TankRoster.ORDER[_idx]
	print("TEX %-8s model=%s" % [key, TankRoster.spec(key)["model"]])
	await _shot("%s_side" % key, SIDE_POS, SIDE_LOOK)
	await _shot("%s_gun" % key, GUN_POS, GUN_LOOK)
	if _idx + 1 < TankRoster.ORDER.size():
		_pick(_idx + 1)
	else:
		get_tree().quit(0)


func _shot(tag: String, cam_pos: Vector3, cam_look: Vector3) -> void:
	_busy = true
	_cam.position = cam_pos
	_cam.look_at(cam_look, Vector3.UP)
	# 钉死转台角度：两张图必须来自同一个朝向才可比
	_main._preview_holder.rotation.y = YAW
	await RenderingServer.frame_post_draw
	_main._preview_holder.rotation.y = YAW
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + "tex_" + tag + ".png")
	print("TEX saved tex_%s.png" % tag)
	_busy = false
