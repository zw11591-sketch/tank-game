extends Node
## 验收：近距离"甩鼠标 + 立刻开火"时，炮弹是打在敌车身上还是从头顶飞走。
##
## 背景：炮管俯仰曾经按 `delta * 6` 平滑（时间常数约 0.17 秒）。玩家把准星压到
## 6 米外的敌车中心、几乎同时扣扳机时，炮管还停在上一帧的高度上——而为了打到
## 6 米外的车，炮口本来就得压到 -5.7°，甩鼠标的幅度最大、滞后也最大。
## 于是炮弹沿着"还没压下去"的炮管飞出去，从敌车头顶掠过、一路飞出一百多米：
## 屏幕上就是"炮台抬得太高、打到天上"。近战里这种事每次甩炮都会发生，所以是"总是"。
##
## 本探针复刻那一串动作：
##   1. 炮管先停在别处（水平 0°，或抬到上限 +6°）；
##   2. 把准星压到敌车中心，**同一帧**开火，不等炮管；
##   3. 记录开火瞬间炮管与准星的俯仰差、炮弹最高点、是否命中。
##
## 判据：每一行都必须打在靶车上（VERDICT hit=n/n）。炮管俯仰即时跟随之后，
## `barrel` 列应当与 `aimP` 列逐行相等；只要有一行 `miss`，就是回归。
##
## 用法：godot.exe --headless --path . res://tools/FlickProbe.tscn

const DISTS := [3.5, 5.0, 6.0, 8.0, 12.0, 20.0]
## 开火前炮管停在哪个俯仰（度）。0 = 平视远处，6 = 抬到上限。
## 6° 这一档最关键：它是"玩家刚把炮管抬到最高、马上又压向近处目标"的最坏情况。
const START_PITCH := [0.0, 6.0]
## 稳定等待帧数：物理帧 120 Hz，60 帧足够让炮塔与炮管停在任何起始姿态
const SETTLE := 60

var _main: Node
var _rows: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_main = get_node("Main")
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._sel_tank = maxi(0, TankRoster.ORDER.find(TankRoster.DEFAULT_ID))
	_main._confirm_start()
	_main.state = "play"
	# 让 enemies_remaining() 永远不为 0：清空靶车不应触发"肃清"，
	# 否则主流程会进入下一关并重建玩家，探针手里的引用就失效了。
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 8:
		await get_tree().physics_frame

	for d in DISTS:
		for sp in START_PITCH:
			var p: Player = _main.player
			var e := Enemy.new()
			e.configure(1, 3, 1)
			e.max_hp = 1000000
			var pos: Vector3 = p.global_position + Vector3(-sin(p.rotation.y), 0.0, -cos(p.rotation.y)) * d
			e.setup(_main, _main.arena, pos)
			_main.add_child(e)
			_main.enemies.append(e)
			e.hp = 1000000
			e.rotation.y = p.rotation.y + PI
			e.set_physics_process(false)
			await _settle(e)
			_rows.append(await _flick_fire(p, e, d, sp))
			e.hp = 1000000
			e.alive = false
			_main.enemies.erase(e)
			e.queue_free()
			await get_tree().physics_frame

	_print_table()
	get_tree().quit(0 if _hits() == _rows.size() else 1)


func _settle(e: Enemy) -> void:
	for _i in 30:
		e.hp = 1000000
		await get_tree().physics_frame


## 把炮管停在 start_pitch、甩到靶车中心并**同一帧**开火。
func _flick_fire(p: Player, e: Enemy, d: float, start_pitch_deg: float) -> Dictionary:
	var target: Vector3 = e.global_position + Vector3(0, 1.1, 0)
	var pivot: Vector3 = p.global_position + Vector3(0, p.aim_height, 0)
	var to: Vector3 = target - pivot
	var flat := Vector2(to.x, to.z).length()
	var want_pitch := clampf(atan2(to.y, maxf(flat, 0.5)), Tank.PITCH_MIN, Tank.PITCH_MAX)
	var want_yaw := wrapf(atan2(-to.x, -to.z), -PI, PI)

	# 1) 炮管先停在别处
	_main.rig.aim_yaw = want_yaw
	_main.rig.aim_pitch = deg_to_rad(start_pitch_deg)
	_main.rig.yaw = want_yaw
	p.rotation.y = want_yaw
	for _i in SETTLE:
		e.hp = 1000000
		await get_tree().physics_frame

	# 2) 甩到靶车中心，下一物理帧开火。
	#
	# 这里必须隔一帧而不是当场调 fire()：实战里开火键与鼠标位移是**同一批输入事件**，
	# 都在下一次物理帧被 player.tick() 读到，而 tick() 里 aim_at_angles() 排在开火之前。
	# 所以"点下左键的那一帧，炮管已经按这一帧的准星更新过了"是真实顺序；
	# 探针若跳过一次 tick 直接开火，测的就是一个玩家碰不到的状态。
	_main.rig.aim_pitch = want_pitch
	p.reload_t = 0.0
	await get_tree().physics_frame
	var barrel_at_fire := rad_to_deg(p.barrel.rotation.x)
	var dir: Vector3 = p.aim_dir()
	var muzzle: Vector3 = p.muzzle_pos()
	var fired: bool = p.fire()
	var climb := 0.0
	var guard := 0
	while guard < 240:
		guard += 1
		await get_tree().physics_frame
		var any := false
		for c in _main.get_children():
			if c is Shell:
				any = true
				climb = maxf(climb, c.global_position.y - muzzle.y)
		if not any:
			break

	return {
		"dist": d, "start": start_pitch_deg, "aim": rad_to_deg(want_pitch),
		"barrel": barrel_at_fire, "climb": climb,
		"hit": (e.hp < 1000000) and fired,
	}


func _hits() -> int:
	var n := 0
	for r in _rows:
		if bool(r["hit"]):
			n += 1
	return n


func _print_table() -> void:
	print("---- FLICK-FIRE TABLE (aim and fire on the same frame) ----")
	print("  dist startP  aimP  barrel  dPitch   climb  hit")
	for r in _rows:
		print("%5.1f %6.1f %5.1f %7.1f %7.1f %7.2f  %s" % [
				r["dist"], r["start"], r["aim"], r["barrel"],
				float(r["barrel"]) - float(r["aim"]), r["climb"],
				"tank" if bool(r["hit"]) else "MISS"])
	print("VERDICT hit=%d / %d %s" % [
			_hits(), _rows.size(), "OK" if _hits() == _rows.size() else "FAIL"])
