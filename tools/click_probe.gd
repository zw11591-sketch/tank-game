extends Node
## 验收：装填过程中"点一下鼠标"是否一定打出去一发，以及从点击到开火的延迟。
##
## 走**真实鼠标事件**（InputEventMouseButton + Input.parse_input_event），而不是
## Input.action_press()：只有前者才会复现"一次按下在连续两个物理帧里都被读到"
## 这条引擎行为（1600×900 / 120Hz 物理下实测：Inject 路径点一下会打两发）。
## 一次"点" = 按下后保持 4 个物理帧（约 33 ms）再松开，接近人手的一次点击。
##
## 统计：
##   frac   点击时装填进度（1 = 已经装好，0 = 刚打完一发）
##   wait   点击到开火的毫秒数
##   extra  之后的 60 帧里是否又自己多打了一发（点一下应当只有一发）
##
## 判据：每一行都必须 fired；wait ≤ 装填剩余 + 一帧；extra = 0。
##
## 用法：godot.exe --headless --path . res://tools/ClickProbe.tscn

const FRACS := [1.0, 0.9, 0.5, 0.25, 0.0]
const DIFFS := [0, 1, 2]
## 按住开火键的验收：按住 1 秒（120 物理帧）应当只打出约 4.5 发。
## 装填压到 0.05~0.09 s 之后，若没有这一档，按住就是 11~20 发/秒的机枪。
const HOLD_FRAMES := 120
const HOLD_MIN := 3
const HOLD_MAX := 7

var _main: Node
var _rows: Array = []
var _holds: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	for diff in DIFFS:
		for idx in TankRoster.ORDER.size():
			await _run_diff(diff, int(idx))
	_print_table()
	var bad := _fails()
	print("VERDICT fail=%d / %d %s" % [bad, _rows.size(), "OK" if bad == 0 else "FAIL"])
	get_tree().quit(0 if bad == 0 else 1)


func _run_diff(diff: int, idx: int) -> void:
	_main = get_node("Main")
	_main._sel_tank = idx
	_main._sel_diff = diff
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 8:
		await get_tree().physics_frame

	var p: Player = _main.player
	# 对着空地开火，避免炮弹立刻打中东西导致判据抖动
	for f in FRACS:
		p.reload_t = p.reload_time * (1.0 - float(f))
		await get_tree().physics_frame
		var t0 := Time.get_ticks_msec()
		# 判"这一下打出几发"用击发计数，而不是装填时间：装填已经压到 0.05 s，
		# 一次点按（4 帧）就够走完一整轮，按 reload_t 判定会把"打过一发"和
		# "正在装下一发"读混。
		var before := p.shot_count
		_click(true)
		var fired := false
		for _i in 4:
			await get_tree().physics_frame
			if p.shot_count > before:
				fired = true
		_click(false)

		var frames := 0
		while not fired and frames < 240:
			await get_tree().physics_frame
			frames += 1
			if p.shot_count > before:
				fired = true
				break
		var wait := Time.get_ticks_msec() - t0

		# 松手之后不应再补发：任何落在这 60 帧里的击发都是多余的
		var extra := 0
		var extra_pressed := false
		for _i in 60:
			await get_tree().physics_frame
			var shots: int = p.shot_count - before
			if shots > 1:
				extra = shots - 1
				extra_pressed = extra_pressed or Input.is_action_pressed("fire")
				print("EXTRA %s d%d f%.1f shots=%d pend=%s alive=%s state=%s"
						% [p.tank_id, diff, f, shots,
						str(p._pending_shot), str(p.alive), str(_main.state)])
				before = p.shot_count

		_rows.append({
			"tank": p.tank_id, "diff": diff, "frac": f, "reload": p.reload_time,
			"wait": wait, "fired": fired, "extra": extra, "held": extra_pressed,
		})

	await _run_hold(p, diff)

	_main._clear_battle()
	await get_tree().physics_frame


## 按住开火键 1 秒，数打了多少发。判据是一段区间而不是精确值：
## 时序受物理帧与装填取整影响，但"机枪"（十几发）与"持续火力"（约五发）不会混。
func _run_hold(p: Player, diff: int) -> void:
	p.reload_t = 0.0
	await get_tree().physics_frame
	var before := p.shot_count
	_click(true)
	for _i in HOLD_FRAMES:
		await get_tree().physics_frame
	_click(false)
	var shots: int = p.shot_count - before
	_holds.append({
		"tank": p.tank_id, "diff": diff, "sec": float(HOLD_FRAMES) / 120.0,
		"shots": shots,
	})
	# 松手之后不许再自己补发
	for _i in 30:
		await get_tree().physics_frame
	var late: int = p.shot_count - before - shots
	if late > 0:
		print("HOLD LATE %s d%d late=%d" % [p.tank_id, diff, late])
		_holds[-1]["shots"] = shots + late


func _click(down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	ev.position = Vector2(480, 480)
	Input.parse_input_event(ev)


func _fails() -> int:
	var n := 0
	for r in _rows:
		var deadline: int = int(ceil(float(r["reload"]) * 1000.0)) + 40
		if not bool(r["fired"]) or int(r["wait"]) > deadline or int(r["extra"]) > 0:
			n += 1
	for h in _holds:
		var shots: int = int(h["shots"])
		if shots < HOLD_MIN or shots > HOLD_MAX:
			n += 1
	return n


func _print_table() -> void:
	print("---- CLICK TO FIRE TABLE ----")
	print(" tank    diff frac reload  wait(ms) fired extra held")
	for r in _rows:
		print("%-7s %4d %4.1f %6.2f %8d %5s %5d %5s%s" % [
			r["tank"], r["diff"], r["frac"], r["reload"], r["wait"],
			"yes" if bool(r["fired"]) else "NO", r["extra"],
			"yes" if bool(r["held"]) else "no",
			"" if bool(r["fired"]) and int(r["extra"]) == 0 else "  FAIL"])
	print("---- HOLD TO FIRE TABLE (1.0 s held) ----")
	print(" tank    diff  shots  range")
	for h in _holds:
		var shots: int = int(h["shots"])
		var bad: bool = shots < HOLD_MIN or shots > HOLD_MAX
		print("%-7s %4d %6d  %d..%d%s" % [
			h["tank"], h["diff"], shots, HOLD_MIN, HOLD_MAX, "  FAIL" if bad else ""])
