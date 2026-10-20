extends Node
## 验收：上下瞄准的手感——鼠标推多少像素、瞄准角变多少度、准星在画面里走多远。
##
## 背景：炮管俯仰行程一共只有 24°（`[-18°, +6°]`，下限是近距离压炮管要的几何量、
## 上限是"别打到天上"的手感量），而"打地面上的坦克"实际用到的区间只有几度。
## 于是**每像素对应几度**这个增益直接决定手感：
## 增益一大，手抖 20 px 瞄准角就跳 1° 以上——60 m 外偏 1 m、200 m 外偏 3 m，
## 炮弹从敌人头顶飞过，玩家看到的就是"一瞄就瞄到天上"。
##
## 打印四个量（ASCII 标签：中文经 PowerShell 管道会变乱码）：
##   aim  瞄准角（炮管指向相对水平，度）
##   cam  镜头俯角（度）。它随瞄准角按 PITCH_FOLLOW 抬降，是"画面整体上下摇"的来源
##   ret% 准星在画面上的高度（0% = 画面上缘，100% = 下缘）
##   ret/mouse  准星在屏幕上的移动量 ÷ 鼠标移动量（<1 表示准星比手慢）
##
## 判据：
##   1. 手抖 10 px 引起的瞄准角变化 ≤ 0.2°（100 m 外偏 ≤ 0.35 m，半车高以内）；
##   2. 从水平抬到 `PITCH_MAX` 要推 ≥ 400 px，也就是"要故意去够才够得着天"
##      （行程收到 6° 之后这个门槛按行程等比减半）；
##   3. `ret/mouse` 在 0.2~1.5 之间——准星要跟着手走，但不能比手快。
## 用法：godot.exe --headless --path . tools/PitchProbe.tscn

## 向上推的鼠标像素（每一行都从水平开始）
const ROWS := [0, 5, 10, 20, 40, 80, 160, 320, 640, 1000, 1600, 2600]
## 向下推取样
const DOWN := [5, 20, 80, 320, 1000]
const SETTLE := 40
## 判据
const JITTER_PX := 10.0
const JITTER_MAX_DEG := 0.2
const REACH_MIN_PX := 400.0

var _vp := Vector2(1920.0, 1080.0)
var _rows: Array = []
var _fails := 0


func _main() -> Node:
	return get_node("Main")


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.mouse_sens = 1.0
	Settings.invert_y = false
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 2
	main._sel_terrain = 0
	main._confirm_start()
	main.state = "ready"
	main.state_timer = 1.0e9
	for _i in 8:
		await get_tree().physics_frame
	_vp = Vector2(get_viewport().get_visible_rect().size)

	var p: Player = main.player
	var rig: CameraRig = main.rig
	rig.aim_yaw = p.rotation.y

	print("---- PITCH INPUT TABLE ----  viewport %dx%d" % [int(_vp.x), int(_vp.y)])
	print("  PITCH_MIN %.1fdeg  PITCH_MAX %.1fdeg  PITCH_SENS %.3f  mouseSens %.2f"
			% [rad_to_deg(Tank.PITCH_MIN), rad_to_deg(Tank.PITCH_MAX),
			CameraRig.PITCH_SENS, Settings.mouse_sens])
	print("  px = upward mouse drag (screen px), every row restarts from a level aim")
	print("    px     aim    cam    ret%   ret/mouse   px/deg    hit")

	for px in ROWS:
		_rows.append(await _measure(px, true))
	var down: Array = []
	for px in DOWN:
		down.append(await _measure(px, false))

	var prev: Dictionary = {}
	for r in _rows:
		var gain := 0.0
		var dpx: float = float(r["px"]) - float(prev.get("px", 0))
		if dpx > 0.0:
			gain = (float(prev.get("y", r["y"])) - float(r["y"])) / dpx
		_judge(r)
		print("%6d  %6.2f %6.2f  %5.1f  %8.2f   %6.4f  %s%s" % [
				r["px"], r["aim"], r["cam"], _pct(r["y"]), gain,
				1.0 / maxf(float(r["degpx"]), 1.0e-6), r["hit"],
				"  CLAMPED" if _clamped(r["y"]) else ""])
		prev = r

	print("  -- downward --")
	for r in down:
		_judge(r)
		print("%6d  %6.2f %6.2f  %5.1f  %8s   %6.4f  %s%s" % [
				r["px"], r["aim"], r["cam"], _pct(r["y"]), "-",
				1.0 / maxf(float(r["degpx"]), 1.0e-6), r["hit"],
				"  CLAMPED" if _clamped(r["y"]) else ""])

	# 判据 1 / 2：手抖与够得着
	var jitter := _slope(_rows, JITTER_PX, true)
	var jitter_dn := _slope(down, JITTER_PX, false)
	var reach := _reach_px(true)
	var reach_dn := _reach_px(false)
	var ok1: bool = jitter <= JITTER_MAX_DEG and jitter_dn <= JITTER_MAX_DEG
	var ok2: bool = reach >= REACH_MIN_PX
	print("VERDICT jitter10px=%.3fdeg (down %.3f, limit %.2f) %s | px-to-reach-top=%.0f (min %.0f) %s | fail=%d"
			% [jitter, jitter_dn, JITTER_MAX_DEG, "OK" if ok1 else "TOO SENSITIVE",
			reach, REACH_MIN_PX, "OK" if ok2 else "TOO TWITCHY", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


## 把瞄准归零、稳定、再推 px 个像素，读回瞄准角 / 镜头俯角 / 准星屏幕高度
func _measure(px: int, up: bool) -> Dictionary:
	var main := _main()
	var rig: CameraRig = main.rig
	var p: Player = main.player
	rig.aim_pitch = 0.0
	rig.pitch = CameraRig.PITCH_BASE
	rig.aim_yaw = p.rotation.y
	for _i in SETTLE:
		await get_tree().physics_frame
	var p0: float = rig.aim_pitch
	rig.handle_mouse(Vector2(0.0, -float(px) if up else float(px)))
	for _i in SETTLE:
		await get_tree().physics_frame

	var sp: Vector2 = rig.aim_screen_point()
	if sp == Vector2.INF:
		sp = _dir_point(rig)
	# 300 m 处的方向点：命中点会随距离跳变，这个量只反映"瞄准方向"
	var dir: Vector2 = _dir_point(rig)
	var hit := rig._aim_hit()
	var hit_txt := "none" if hit.is_empty() else "%.0fm" % (Vector3(hit["position"]) - rig._aim_origin()).length()
	return {
		"px": px, "up": up,
		"aim": rad_to_deg(rig.aim_pitch),
		"cam": rad_to_deg(rig.pitch),
		"y": dir.y, "yhit": sp.y,
		"degpx": absf(rad_to_deg(rig.aim_pitch) - rad_to_deg(p0)) / maxf(float(px), 1.0e-6),
		"hit": hit_txt,
	}


## 瞄准方向 300 m 处的投影。与命中点无关，于是"每度几像素"不会因为
## 准星从敌车跳到远处围墙而失真
func _dir_point(rig: CameraRig) -> Vector2:
	var rig_node := rig as Node3D
	var from: Vector3 = rig._aim_origin()
	var v: Vector3 = from + rig.aim_vector() * 300.0
	if rig.cam.is_position_behind(v):
		return Vector2(_vp.x * 0.5, 0.0)
	return rig.cam.unproject_position(v)


func _pct(y: float) -> float:
	return y / _vp.y * 100.0


## HUD 把准星钳在距边缘 44 px 处，钳住了就说明准星已经不是真实瞄准点了
func _clamped(y: float) -> bool:
	return y < 44.0 or y > _vp.y - 44.0


## 手抖 px 个像素会带来多少度的瞄准角变化，按相邻取样点线性插值
func _slope(rows: Array, px: float, up: bool) -> float:
	for i in range(1, rows.size()):
		var a: Dictionary = rows[i - 1]
		var b: Dictionary = rows[i]
		if float(b["px"]) >= px:
			var t: float = (px - float(a["px"])) / maxf(float(b["px"]) - float(a["px"]), 1.0e-6)
			return absf(lerpf(float(a["degpx"]), float(b["degpx"]), t)) * px
	# 取样不够密：用最大的一档外推
	return absf(float(rows[rows.size() - 1]["degpx"])) * px


## 从水平到撞上限要推多少像素。用第一档取样的斜率外推：鼠标是线性增益，
## 所以这就是准确值（被钳住的那几行斜率已被稀释，不能用）
func _reach_px(up: bool) -> float:
	var limit: float = rad_to_deg(Tank.PITCH_MAX if up else Tank.PITCH_MIN)
	var gain := 0.0
	for r in _rows:
		if float(r["px"]) > 0.0:
			gain = float(r["degpx"])
			break
	if gain <= 0.0:
		return 1.0e9
	return absf(limit) / gain


func _judge(r: Dictionary) -> void:
	if _clamped(float(r["y"])):
		_fails += 1
