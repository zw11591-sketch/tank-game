extends Node
## 全局设置单例（Settings autoload）：显示模式与分辨率、画质档位、输入灵敏度。
##
## 核心职责之一是"窗口跟随显示器"：启动时读取当前显示器的原生分辨率并据此设窗口，
## 默认进独占全屏，所以游戏画面分辨率与显示器一致，3D 按原生像素渲染。
## HUD 则按 1920x1080 的设计空间等比缩放（见 project.godot 的 stretch 设置），
## 这样 1080p / 1440p / 4K 下界面比例一致、不会一块大一块小。

const CFG_PATH := "user://settings.cfg"

## 显示模式
enum Disp {
	EXCLUSIVE,    ## 独占全屏：延迟最低，分辨率等于显示器
	BORDERLESS,   ## 无边框全屏：切出去快，分辨率等于显示器
	WINDOWED,     ## 窗口
}

## 画质档位。LOW 等同改造前的轻量环境，HIGH 开满屏幕空间效果与全局光照。
enum Quality { LOW, MEDIUM, HIGH }

const DISP_NAMES := ["独占全屏", "无边框全屏", "窗口"]
const QUALITY_NAMES := ["低", "中", "高"]
const MSAA_NAMES := ["关", "2x", "4x", "8x"]

signal quality_changed(level: int)
signal display_changed()
## 音量变更。Audio 单例连它，于是设置不必知道总线怎么接的。
## 用信号而不是直接调 Audio：autoload 的初始化顺序是 Settings 先于 Audio，
## 直接调会在启动时撞上一个还不存在的单例。
signal audio_changed()

# ---- 显示 ----
var display_mode: int = Disp.EXCLUSIVE
var windowed_size := Vector2i(1600, 900)
var vsync := true
var fps_cap := 0                  ## 0 表示不限制

# ---- 渲染 ----
var render_scale := 1.0           ## 3D 渲染缩放，4K 下可降到 0.7 保帧率
var msaa := 2                     ## 0 关 / 1 2x / 2 4x / 3 8x
var taa := false
var quality: int = Quality.HIGH
var hud_scale := 1.0
## 画面曝光。显示器与房间亮度千差万别，同一套光照在别人屏幕上可能偏暗，
## 所以留一个总曝光让玩家自己对齐——它写进 Environment.tonemap_exposure，
## 不受画质档位影响，低画质下同样生效。
var brightness := 1.0

# ---- 音量 ----
## 线性音量 0..1，写进总线时转成 dB（见 audio.gd 的 apply_volumes）。
## 发动机单独一档：它是唯一长时间持续的声源，有人想留着炮声但调掉它。
var master_vol := 0.9
var sfx_vol := 1.0
var engine_vol := 0.8

# ---- 输入 ----
var mouse_sens := 1.0
var gamepad_sens := 1.0
var invert_y := false

# ---- 操控 ----
## 镜头相对驾驶：方向键读成"屏幕上的方向"——W 往画面上方走、S 往镜头方向退，
## 车体自己转向去对齐。玩家于是完全不必判断车头朝哪，这是"分不清车头车尾"的
## 根治办法。
##
## A/D 单独按下时例外：那是**原地转向**（见 Player._relative_drive）。
## 相对驾驶最初把 A/D 也读成"往屏幕左右走"，于是玩家想转车头时车只会横着蹭，
## 而且转到 90° 就停住——车体朝向就是装甲朝向（歼击车还只能靠车体指向目标），
## "按 A 转不过来"是玩家最直接的不适。现在只有"同时给了油门"才走屏幕方向。
## 关闭则整体回到传统履带转向：W/S 沿车体轴线、A/D 原地左右转车。
var drive_relative := true

## 上一次选定的车型（TankRoster.ORDER 里的 id）。存在这里而不是 main.gd 的成员里，
## 于是"换车"和"改分辨率"走同一条存档路径，不必再开一个配置文件。
## 空串表示还没选过，选车界面会退回名册的默认车。
var selected_tank := ""

# ---- 联机 ----
## 显示给其他玩家的名字。空串时退回系统用户名。
var player_name := ""
## ENet 服务端口（UDP）。房主监听这个端口，客户端直接连它。
var net_port := 45888
## 局域网房间发现端口（UDP 广播）。同一台机器开两个实例时要改其中一个。
var discovery_port := 45887
var net_max_players := 4
## 手动加入时记住的上一个 IP。
var last_server := ""

var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	InputSetup.register()
	# 关闭输入累积，鼠标移动逐事件送达，转塔手感更跟手
	Input.set_use_accumulated_input(false)
	load_cfg()
	apply_all()


# ---------------- 应用 ----------------

func apply_all() -> void:
	apply_display()
	apply_render()


func screen_size() -> Vector2i:
	if _headless:
		return Vector2i(1920, 1080)
	return DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())


func apply_display() -> void:
	if _headless:
		return
	var scr := DisplayServer.window_get_current_screen()
	var ss := DisplayServer.screen_get_size(scr)

	match display_mode:
		Disp.EXCLUSIVE:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_size(ss)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		Disp.BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			DisplayServer.window_set_size(ss)
			DisplayServer.window_set_position(DisplayServer.screen_get_position(scr))
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			var sz := windowed_size.clamp(Vector2i(960, 540), ss)
			DisplayServer.window_set_size(sz)
			DisplayServer.window_set_position(DisplayServer.screen_get_position(scr) + (ss - sz) / 2)

	display_changed.emit()


func apply_render() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = clampf(render_scale, 0.5, 1.0)
		vp.msaa_3d = clampi(msaa, 0, 3)
		vp.use_taa = taa
	var w := get_window()
	if w != null:
		w.content_scale_factor = clampf(hud_scale, 0.6, 2.0)
	if not _headless:
		DisplayServer.window_set_vsync_mode(
			DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
		)
	Engine.max_fps = maxi(0, fps_cap)
	quality_changed.emit(quality)


func cycle_display_mode() -> void:
	display_mode = (display_mode + 1) % 3
	apply_display()
	save_cfg()


# ---------------- 设置项表（供暂停菜单遍历） ----------------

## 返回 [{ name, value_text }]，顺序即菜单顺序
func option_rows() -> Array:
	return [
		{"name": "显示模式", "value": DISP_NAMES[display_mode]},
		{"name": "分辨率", "value": "%d x %d%s" % [
			screen_size().x, screen_size().y,
			"（跟随显示器）" if display_mode != Disp.WINDOWED else "",
		]},
		{"name": "画质", "value": QUALITY_NAMES[quality]},
		{"name": "渲染缩放", "value": "%d%%" % int(round(render_scale * 100.0))},
		{"name": "抗锯齿", "value": MSAA_NAMES[clampi(msaa, 0, 3)]},
		{"name": "时间抗锯齿", "value": "开" if taa else "关"},
		{"name": "垂直同步", "value": "开" if vsync else "关"},
		{"name": "帧率上限", "value": "不限" if fps_cap <= 0 else str(fps_cap)},
		{"name": "界面缩放", "value": "%d%%" % int(round(hud_scale * 100.0))},
		{"name": "画面亮度", "value": "%d%%" % int(round(brightness * 100.0))},
		{"name": "总音量", "value": _vol_text(master_vol)},
		{"name": "音效音量", "value": _vol_text(sfx_vol)},
		{"name": "发动机音量", "value": _vol_text(engine_vol)},
		{"name": "鼠标灵敏度", "value": "%.2f" % mouse_sens},
		{"name": "手柄灵敏度", "value": "%.2f" % gamepad_sens},
		{"name": "鼠标 Y 轴反转", "value": "开" if invert_y else "关"},
		{"name": "驾驶方式", "value": "镜头相对（车体自动转向）" if drive_relative else "履带转向（传统）"},
	]


## 0 显示成"关"而不是"0%"：静音是一个状态，不是一个刻度。
func _vol_text(v: float) -> String:
	return "关" if v <= 0.001 else "%d%%" % int(round(v * 100.0))


## 调整第 row 项，d 为 -1 / +1
func adjust(row: int, d: int) -> void:
	match row:
		0:
			display_mode = posmod(display_mode + d, 3)
			apply_display()
		1:
			if display_mode == Disp.WINDOWED:
				var presets := [
					Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
					Vector2i(2560, 1440), Vector2i(3840, 2160),
				]
				var idx := presets.find(windowed_size)
				idx = posmod((0 if idx < 0 else idx) + d, presets.size())
				windowed_size = presets[idx]
				apply_display()
		2:
			quality = clampi(quality + d, 0, 2)
			quality_changed.emit(quality)
		3:
			render_scale = clampf(snappedf(render_scale + d * 0.05, 0.05), 0.5, 1.0)
			apply_render()
		4:
			msaa = clampi(msaa + d, 0, 3)
			apply_render()
		5:
			taa = not taa
			apply_render()
		6:
			vsync = not vsync
			apply_render()
		7:
			var caps := [0, 30, 60, 90, 120, 144, 165, 240]
			var i := caps.find(fps_cap)
			i = posmod((0 if i < 0 else i) + d, caps.size())
			fps_cap = caps[i]
			apply_render()
		8:
			hud_scale = clampf(snappedf(hud_scale + d * 0.05, 0.05), 0.6, 2.0)
			apply_render()
		9:
			brightness = clampf(snappedf(brightness + d * 0.05, 0.05), 0.6, 1.8)
			apply_render()
		10:
			master_vol = _bump_vol(master_vol, d)
			audio_changed.emit()
		11:
			sfx_vol = _bump_vol(sfx_vol, d)
			audio_changed.emit()
		12:
			engine_vol = _bump_vol(engine_vol, d)
			audio_changed.emit()
		13:
			mouse_sens = clampf(snappedf(mouse_sens + d * 0.05, 0.05), 0.1, 4.0)
		14:
			gamepad_sens = clampf(snappedf(gamepad_sens + d * 0.05, 0.05), 0.1, 4.0)
		15:
			invert_y = not invert_y
		16:
			drive_relative = not drive_relative
	save_cfg()


## 音量按 5% 步进。调用方负责在赋值之后 emit audio_changed，
## 于是音量是边调边听的——这是唯一必须立刻听到结果的设置。
func _bump_vol(v: float, d: int) -> float:
	return clampf(snappedf(v + d * 0.05, 0.05), 0.0, 1.0)


# ---------------- 存档 ----------------

func load_cfg() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		# 首次启动：窗口模式的默认尺寸取显示器的 75%，但默认走独占全屏
		var ss := screen_size()
		windowed_size = Vector2i(int(ss.x * 0.75), int(ss.y * 0.75))
		return
	display_mode = cf.get_value("display", "mode", display_mode)
	windowed_size = cf.get_value("display", "windowed_size", windowed_size)
	vsync = cf.get_value("display", "vsync", vsync)
	fps_cap = cf.get_value("display", "fps_cap", fps_cap)

	render_scale = cf.get_value("render", "scale", render_scale)
	msaa = cf.get_value("render", "msaa", msaa)
	taa = cf.get_value("render", "taa", taa)
	quality = cf.get_value("render", "quality", quality)
	hud_scale = cf.get_value("render", "hud_scale", hud_scale)
	brightness = cf.get_value("render", "brightness", brightness)

	master_vol = cf.get_value("audio", "master", master_vol)
	sfx_vol = cf.get_value("audio", "sfx", sfx_vol)
	engine_vol = cf.get_value("audio", "engine", engine_vol)

	mouse_sens = cf.get_value("input", "mouse_sens", mouse_sens)
	gamepad_sens = cf.get_value("input", "gamepad_sens", gamepad_sens)
	invert_y = cf.get_value("input", "invert_y", invert_y)
	drive_relative = cf.get_value("input", "drive_relative", drive_relative)
	selected_tank = cf.get_value("game", "selected_tank", selected_tank)

	player_name = String(cf.get_value("net", "player_name", player_name))
	net_port = clampi(int(cf.get_value("net", "port", net_port)), 1024, 65535)
	discovery_port = clampi(int(cf.get_value("net", "discovery_port", discovery_port)), 1024, 65535)
	net_max_players = clampi(int(cf.get_value("net", "max_players", net_max_players)), 2, 4)
	last_server = String(cf.get_value("net", "last_server", last_server))


func save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.set_value("display", "mode", display_mode)
	cf.set_value("display", "windowed_size", windowed_size)
	cf.set_value("display", "vsync", vsync)
	cf.set_value("display", "fps_cap", fps_cap)
	cf.set_value("render", "scale", render_scale)
	cf.set_value("render", "msaa", msaa)
	cf.set_value("render", "taa", taa)
	cf.set_value("render", "quality", quality)
	cf.set_value("render", "hud_scale", hud_scale)
	cf.set_value("render", "brightness", brightness)
	cf.set_value("audio", "master", master_vol)
	cf.set_value("audio", "sfx", sfx_vol)
	cf.set_value("audio", "engine", engine_vol)
	cf.set_value("input", "mouse_sens", mouse_sens)
	cf.set_value("input", "gamepad_sens", gamepad_sens)
	cf.set_value("input", "invert_y", invert_y)
	cf.set_value("input", "drive_relative", drive_relative)
	cf.set_value("game", "selected_tank", selected_tank)
	cf.set_value("net", "player_name", player_name)
	cf.set_value("net", "port", net_port)
	cf.set_value("net", "discovery_port", discovery_port)
	cf.set_value("net", "max_players", net_max_players)
	cf.set_value("net", "last_server", last_server)
	cf.save(CFG_PATH)
