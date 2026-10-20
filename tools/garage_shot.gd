extends Node
## 渲染验收：选车界面（车库）逐个车型截图。
##
##   godot.exe --path . res://tools/GarageShot.tscn
##
## 无头模式不执行 Control._draw()，也不渲染 SubViewport，所以转台与属性卡
## 在无头自检里是测不到的。这里开一个真实窗口，把选择界面的游标依次停在
## 名册里的每一台车上各截一张图——于是"转台有没有模型、属性卡有没有字"
## 有图可查，而不是只凭"脚本没报错"。
##
## 自己实例化 Main.tscn，而不是挂成 autoload：挂 autoload 要改 project.godot，
## 而引擎在退出时会把项目文件重写一遍（本机上实测会把临时加的那一行冲掉），
## 于是"临时挂一个调试 autoload"既不可靠，也违反"调试用的 autoload 不留"的约定。
## 自己建场景则完全不碰 project.godot。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"

var _main: Node
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
	print("SHOT start")
	_main._enter_select()
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
	# 转台模型是运行时实例化的，而 SubViewport 要等若干帧才把世界建好，
	# 所以不能立刻截图——留 30 帧让模型、光照与 _draw 都就位。
	if _f < 30:
		return
	_report()
	await _shot("garage_%d_%s" % [_idx, TankRoster.ORDER[_idx]])
	if _idx + 1 < TankRoster.ORDER.size():
		_pick(_idx + 1)
	else:
		get_tree().quit(0)


## 逐车型打印名册数值：截图只能看出"有没有"，数值要靠这里核对。
## 同时报告转台是否真的拿到了模型——模型缺失时 _show_tank 会静默跳过，
## 那正是最需要被看见的一种失败。
func _report() -> void:
	var id: String = TankRoster.ORDER[_idx]
	var s := TankRoster.spec(id)
	var d := TankRoster.dims(String(s["model"]))
	var inst_ok: bool = _main._preview_model != null and is_instance_valid(_main._preview_model)
	print("SHOT %-8s model=%-15s preview=%s hp=%d spd=%.1f reload=%.2f dmg=%d af=%.2f turret=%.1f limit=%.2f r=%.2f len=%.1f" % [
		id, str(s["model"]), "OK" if inst_ok else "MISSING",
		int(s["hp"]), float(s["speed"]), float(s["reload"]), int(s["damage"]),
		float(s["af"]), float(s["turret"]), float(s["turret_limit"]),
		float(d["radius"]), float(d["length"]),
	])
	_fit_report()


## 断言左栏每一行都排得下。AUTOWRAP 只在超宽时才折，而中文没有空格，
## 折点会落在任意字符上——"第三人称↔第一人称"就曾被切成"第一人 / 称"。
## 所以"没有断词"等价于"没有超宽"，这件事可以直接量出来，不必每次靠看图。
##
## 三件事必须一起成立，否则"OK"是假的：
##   1. 量的是**车库用的那份文本**（逐条短句），不是暂停菜单的紧凑版；
##   2. 可用宽度要扣掉 Label 的左右内边距，AUTOWRAP 折行用的是扣完后的宽度；
##   3. 量的是当前生效的字号（由 _fit_garage_text 按栏宽反算），不是设计值。
func _fit_report() -> void:
	var f := ThemeDB.fallback_font
	var l: Label = _main._select_l
	var fs: int = l.get_theme_font_size("font_size")
	var pad: float = l.get_theme_stylebox("normal").get_minimum_size().x
	var w: float = l.size.x - pad
	var txt: String = l.text
	var worst := 0.0
	var over := 0
	var lines := txt.split("\n")
	for i in lines.size():
		var need := f.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		worst = maxf(worst, need)
		if need > w:
			over += 1
			print("FIT over line=%d %.0f/%.0f OVER" % [i, need, w])
	# 汇总一行，便于 grep 一个数就知道离溢出还有多少余量
	print("FIT summary fs=%d pad=%.0f width=%.0f widest=%.0f lines=%d over=%d %s" % [
		fs, pad, w, worst, lines.size(), over, "OK" if over == 0 else "FAIL",
	])


func _shot(tag: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")
	print("SHOT saved %s.png" % tag)
	_busy = false
