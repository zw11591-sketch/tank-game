extends Node
## 渲染验收：近距离交战时玩家实际看到的画面。
##
## 无头模式只有数字，回答不了"炮口看起来是不是抬得太高"。这里开真实窗口，
## 把靶车摆在 6 m 与 12 m，按玩家会做的动作把准星压到敌车中心，截图。
##
## 用法：godot.exe --path . res://tools/CloseShot.tscn

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"
const DISTS := [6.0, 12.0]

var _f := 0
var _idx := 0
var _busy := false
var _main: Node
var _yaw := 0.0


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1600, 900)
	Settings.apply_display()
	DirAccess.make_dir_recursive_absolute(DIR)
	_main = get_node("Main")
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.player.shield_t = 0.0
	for _i in 30:
		await get_tree().physics_frame
	_yaw = _open_yaw(_main.player, _main.arena)
	print("SHOT yaw=%.1f" % rad_to_deg(_yaw))


func _physics_process(_d: float) -> void:
	if _busy or _main == null or _main.player == null:
		return
	_f += 1
	if _f == 40 and not _busy:
		_main.state = "play"
		_main.player.shield_t = 0.0
		if _idx < DISTS.size():
			_main.player.rotation.y = _yaw
			_main.rig.aim_yaw = _yaw
			_main.rig.aim_pitch = 0.0
			_main.rig.yaw = _yaw
			_place(DISTS[_idx])
	if _f == 130:
		_aim()
	if _f == 180:
		await _shot("CLOSE_%dm" % int(DISTS[_idx]))
		_idx += 1
		_f = 0
		if _idx >= DISTS.size():
			get_tree().quit(0)


func _place(d: float) -> void:
	var p: Player = _main.player
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = 1000000
	var pos: Vector3 = p.global_position + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	e.setup(_main, _main.arena, pos)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = 1000000
	e.rotation.y = _yaw + PI
	e.global_position = pos
	e.set_physics_process(false)


func _aim() -> void:
	var p: Player = _main.player
	var e: Tank = _main.enemies[_main.enemies.size() - 1]
	var target: Vector3 = e.global_position + Vector3(0, 1.1, 0)
	var pivot: Vector3 = p.global_position + Vector3(0, p.aim_height, 0)
	var to: Vector3 = target - pivot
	var flat := Vector2(to.x, to.z).length()
	_main.rig.aim_yaw = wrapf(atan2(-to.x, -to.z), -PI, PI)
	_main.rig.aim_pitch = clampf(atan2(to.y, maxf(flat, 0.5)),
			Tank.PITCH_MIN, Tank.PITCH_MAX)
	_main.rig.yaw = _main.rig.aim_yaw
	p.rotation.y = _main.rig.aim_yaw
	print("SHOT aim=%.2f barrel=%.2f" % [
		rad_to_deg(_main.rig.aim_pitch), rad_to_deg(p.barrel.rotation.x)])


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for i in [6, 12]:
			var pos: Vector3 = p.global_position + dir * float(i)
			var c := Arena.to_cell(pos)
			if arena.blocks_tank(c.x, c.y):
				ok = false
				break
			if not arena.has_line_of_sight(eye, pos + Vector3(0, 1.5, 0)):
				ok = false
				break
		if ok:
			return yaw
	return 0.0


func _shot(tag: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")
	print("SHOT saved %s.png" % tag)
	_busy = false
