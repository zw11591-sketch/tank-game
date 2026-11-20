extends Node
## 验收：车库的出击闸门与"提示真的出现在玩家眼前"。
##
## 先前的问题：选了未解锁的战车按 Enter 没反应，因为
##   1) 提示写进 `banner_text`，而它只由战斗 HUD 绘制，车库与标题下 HUD 是隐藏的；
##   2) 车库文字里只写「未解锁 · 需 N 补给券」，不写"所以不能出击"。
## 表现就是"按了 Enter，什么都没发生"。
##
## 判据：
##   * 未解锁车 + 车库入口被拦，状态仍是 select，且提示同时进了车库文字；
##   * 未解锁车 + 非车库入口（探针 / 命令行）不被拦；
##   * 解锁后同一台车能进 ready；
##   * 默认车（游隼）永远放行；
##   * 暂停 / 结算正文的提示只追加一次，不污染底稿。
##
## 退出前把 `user://meta.cfg` 原样还原：探针不该改动玩家的真实存档。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会二次编码。
## 用法：godot.exe --headless --path . res://tools/GarageGateProbe.tscn

var _fail := 0
var _checks := 0
var _main: Node
var _tanks_before: Dictionary = {}


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_main = get_node_or_null("Main")
	if _main == null:
		print("GATE FAIL noMain")
		get_tree().quit(1)
		return
	var meta: Node = get_node_or_null("/root/Meta")
	_tanks_before = meta.unlocked.duplicate(true)

	_run_checks(meta)

	meta.unlocked = _tanks_before.duplicate(true)
	meta.save_cfg()
	# 退出前先把刚起的关卡拆掉再等几帧：车库探针会真的开两局，
	# 在倒计时中途直接 quit 会留下正在创建的粒子/材质，headless 的占位渲染器
	# 退出时报一句 "Parameter material is null"，看起来像探针失败。
	if _main.state == "ready" or _main.state == "play":
		_main.state = "title"
		_main._clear_battle()
		_main.hud.visible = false
	for i in 6:
		await get_tree().process_frame
	print("GATE VERDICT %s (%d checks, %d failed)" % [
		"OK" if _fail == 0 else "FAIL", _checks, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _ok(cond: bool, tag: String, extra := "") -> void:
	_checks += 1
	if not cond:
		_fail += 1
		print("FAIL %s %s" % [tag, extra])


func _run_checks(meta: Node) -> void:
	var roster = load("res://scripts/tank_roster.gd")
	var order: Array = roster.ORDER
	var locked_id := "hunter"
	var idx := order.find(locked_id)

	# 1) 前提：这台车必须处于未解锁状态，否则"被拦"这一项永远不成立。
	meta.unlocked.erase(locked_id)
	_ok(not meta.is_tank_unlocked(locked_id), "lockedByDefault")

	# 2) 车库入口：未解锁 -> 被拦，状态不前进，提示写进车库左栏。
	_main.state = "select"
	_main._enter_select()
	_main._sel_tank = idx
	_main._refresh_select()
	_main._confirm_start()
	_ok(_main.state == "select", "parkBlocks", "state=%s" % _main.state)
	_ok(_main._notice_t > 0.0, "parkNoticeTimer")
	_ok(String(_main._notice_text).contains("券"), "parkNoticeText",
			String(_main._notice_text))
	_ok(String(_main._select_l.text).contains("不能出击"), "garageMarked")
	_ok(String(_main._select_l.text).contains(String(_main._notice_text)),
			"garageShowsNotice")

	# 3) 非车库入口（探针 / 命令行）必须放行：既有探针都从 title 直接开局。
	_main.state = "title"
	_main._sel_tank = idx
	_main._confirm_start()
	_ok(_main.state != "title" and _main.state != "select", "probeBypass",
			"state=%s" % _main.state)

	# 4) 解锁后同一台车从车库能进 ready。
	_main.state = "select"
	_main._enter_select()
	_main._sel_tank = idx
	meta.unlocked[locked_id] = true
	_main._refresh_select()
	_ok(not String(_main._select_l.text).contains("不能出击"), "unlockedNoWarning")
	_main._confirm_start()
	_ok(_main.state == "ready", "unlockedStarts", "state=%s" % _main.state)

	# 5) 默认车永远放行（解锁表里不必有它）。
	meta.unlocked.erase("falcon")
	_main.state = "select"
	_main._enter_select()
	_main._sel_tank = order.find("falcon")
	_main._confirm_start()
	_ok(_main.state == "ready", "defaultStarts", "state=%s" % _main.state)

	# 6) 提示只追加一次，且不污染正文底稿。
	_main.state = "over"
	_main._show_menu("X", "BASE")
	_main._notice_text = "TIP"
	_main._notice_t = 5.0
	_main._attach_notice()
	_main._attach_notice()
	_ok(String(_main._menu_l.text).count("TIP") == 1, "noticeNotDuplicated",
			String(_main._menu_l.text))
	_ok(String(_main._menu_body) == "BASE", "bodyNotPolluted", String(_main._menu_body))