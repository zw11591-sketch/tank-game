extends Node
## 诊断（逐帧）：近距交火时敌方 AI 的炮管俯仰为什么偏高。
##
## 打印：state / 距离 / 目标点高度 / 解算俯仰 / 实际 barrel.rotation.x /
##       炮管实际指向仰角 / 是否锁定 / 本帧是否开火。
##
## 用法：godot.exe --headless --path . res://tools/DuelTrace.tscn

const DIST := 3.5
const ETYPE := 1
const FRAMES := 90

var _main: Node
var _yaw := 0.0
var _p0 := Vector3.ZERO


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.selected_tank = "falcon"
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 10:
		await get_tree().physics_frame

	var p: Player = _main.player
	_yaw = _open_yaw(p, _main.arena)
	_p0 = p.global_position
	p.hp = 1000000

	var ctr: Vector3 = _p0 + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * DIST
	var e := Enemy.new()
	e.configure(ETYPE, 3, 1)
	e.max_hp = 1000000
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.rotation.y = _yaw + PI
	await get_tree().physics_frame

	print("== etype %d dist %.1f  e.aim_height=%.2f  state/aim trace" % [ETYPE, DIST, e.aim_height])
	print("  f  state  d    tgtY  ideal  barrel  dirY  lock  fire  posY")
	for f in FRAMES:
		p.global_position = _p0
		p.rotation.y = _yaw
		p._speed = 0.0
		e.global_position = ctr
		e.rotation.y = _yaw + PI
		e.reload_t = 0.0
		var hp0: int = p.hp
		await get_tree().physics_frame

		var pivot: Vector3 = e.global_position + Vector3(0, e.aim_height, 0)
		var aim: Vector3 = e.aim_point if e.aim_point != Vector3.INF else Vector3.ZERO
		var flat := Vector2(aim.x - pivot.x, aim.z - pivot.z).length()
		var ideal := rad_to_deg(atan2(aim.y - pivot.y, maxf(flat, 0.5))) if e.aim_point != Vector3.INF else 0.0
		var dir := e.aim_dir()
		print("%3d %6d %4.1f %6.2f %6.1f %6.1f %5.1f  %s  %s  %5.2f" % [
			f, e.state, e.global_position.distance_to(p.global_position),
			aim.y, ideal, rad_to_deg(e.barrel.rotation.x),
			rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))),
			"y" if not e.turret_blocked else "n",
			"y" if p.hp < hp0 else "-",
			e.global_position.y])
	get_tree().quit(0)


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [4.0, 8.0, 12.0]:
			var pos: Vector3 = p.global_position + dir * d
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
