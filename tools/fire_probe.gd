extends Node
## 验收：近距离开火的命中情况。
##
## 玩家看到的准星射线从**炮塔耳轴**出发，而炮弹从**炮口**（耳轴前方约 3.8 m）出发。
## 两车贴近时（中心距 3~6 m，车体半径 1.5 m），炮口已经探进敌车车体内部：
## 从形状内部起射的射线不会报告命中，于是炮弹"穿车而过"继续飞——
## 玩家看到的就是"明明贴着打，炮弹却从头顶飞走了"。
##
## 本探针按距离逐档：瞄准敌车中心 → fire() → 采样炮弹最高点与最终位置，
## 并统计敌车掉血。
##
## 用法：godot.exe --headless --path . res://tools/FireProbe.tscn

const DISTS := [4.0, 5.0, 6.0, 8.0, 12.0, 18.0, 26.0]
const SETTLE := 40
const FLIGHT := 120
const DUMMY_HP := 1000000

var _main: Node
var _rows: Array = []


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.selected_tank = "falcon"
	_main = get_node("Main")
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "ready"
	_main.state_timer = 1.0e9
	for _i in 8:
		await get_tree().physics_frame

	var p: Player = _main.player
	var arena: Arena = _main.arena
	var yaw := _open_yaw(p, arena)
	if yaw == INF:
		print("VERDICT no open firing lane")
		get_tree().quit(1)
		return
	p.rotation.y = yaw

	for kind in [Shell.Kind.AP, Shell.Kind.HE]:
		p.shell_kind = kind
		for i in DISTS.size():
			var d: float = DISTS[i]
			var ctr: Vector3 = p.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * d
			var e := Enemy.new()
			e.configure(1, 3, 1)
			e.max_hp = DUMMY_HP
			e.setup(_main, arena, ctr)
			_main.add_child(e)
			_main.enemies.append(e)
			e.hp = DUMMY_HP
			e.rotation.y = yaw + PI
			await get_tree().physics_frame
			await get_tree().physics_frame
			e.global_position = ctr
			e.rotation.y = yaw + PI

			var target: Vector3 = e.global_position + Vector3(0, 1.1, 0)
			var pivot: Vector3 = p.global_position + Vector3(0, p.aim_height, 0)
			var to: Vector3 = target - pivot
			var flat := Vector2(to.x, to.z).length()
			_main.rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
			_main.rig.aim_pitch = clampf(atan2(to.y, maxf(flat, 0.5)),
					Tank.PITCH_MIN, Tank.PITCH_MAX)
			_main.rig.yaw = _main.rig.aim_yaw
			_main.rig.pitch = CameraRig.PITCH_BASE
			p.rotation.y = _main.rig.aim_yaw
			for _j in SETTLE:
				e.hp = DUMMY_HP
				p.reload_t = 0.0
				await get_tree().physics_frame
			e.global_position = ctr
			e.hp = DUMMY_HP

			var muzzle_dist: float = p.muzzle_pos().distance_to(p.global_position)
			var before := e.hp
			p.reload_t = 0.0
			var fired: bool = p.fire()
			_rows.append(await _track(p, e, d, kind, muzzle_dist, fired, before))

			e.alive = false
			_main.enemies.erase(e)
			e.queue_free()
			for c in _main.get_children():
				if c is Shell:
					c.queue_free()
			await get_tree().physics_frame

	_print_table()
	get_tree().quit(0)


func _track(p: Player, e: Enemy, dist: float, kind: int, muzzle_dist: float,
		fired: bool, before: int) -> Dictionary:
	var top := -1000.0
	var last := Vector3.ZERO
	var seen := 0
	for _i in FLIGHT:
		await get_tree().physics_frame
		for c in _main.get_children():
			if c is Shell:
				seen = maxi(seen, 1)
				top = maxf(top, c.global_position.y)
				last = c.global_position
	var lost := before - e.hp
	return {
		"dist": dist, "kind": kind, "muzzleD": muzzle_dist,
		"fired": fired, "dmg": lost, "top": top, "lastD": last.distance_to(p.global_position),
		"alive": seen,
	}


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for i in [3, 6, 10, 18, 26]:
			var pos: Vector3 = p.global_position + dir * float(i)
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
				ok = false
				break
			if arena.blocks_tank(c.x, c.y):
				ok = false
				break
			if not arena.has_line_of_sight(eye, pos + Vector3(0, 1.5, 0)):
				ok = false
				break
		if ok:
			return yaw
	return INF


func _print_table() -> void:
	print("---- POINT BLANK FIRE TABLE ----")
	print("  AP_SPEED %.0f  HE_SPEED %.0f  muzzle reach %.2f m"
			% [Shell.AP_SPEED, Shell.HE_SPEED,
			(_main.player.muzzle_pos().distance_to(_main.player.global_position))])
	print("  kind  dist  muzzle  fired  dmg   shellTop  lastDist")
	for r in _rows:
		var tag := "AP" if int(r["kind"]) == Shell.Kind.AP else "HE"
		print("  %-4s %5.1f %6.2f  %5s %6d %9.2f %9.1f%s" % [
				tag, r["dist"], r["muzzleD"],
				"yes" if r["fired"] else "no", r["dmg"], r["top"], r["lastD"],
				"  WHIFF" if int(r["dmg"]) <= 0 else ""])
