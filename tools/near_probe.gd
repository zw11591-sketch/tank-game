extends Node
## 验收：近距离（2.5~9 m）交战时的实际弹道——炮口从哪里出发、飞得多高、有没有打中。
##
## 玩家反馈的现象是"两台坦克贴得很近时炮台抬得太高，炮弹直接飞上天"。
## 本探针把靶车摆在近距离，按玩家会做的动作把准星压到靶车的**下半车体**与**炮塔**上，
## 再走真正的开火路径（`Player.fire()`），逐行记录：
##
##   ideal   指向瞄准点所需的俯仰（未钳制）
##   aim     实际瞄准角（被 PITCH_MIN/MAX 钳过）
##   barrel  开火瞬间炮管俯仰
##   muzzle  炮口离地高度
##   inside  开火瞬间炮口是否已经在某辆坦克的碰撞体内部（1 = 在内部）
##   climb   整段飞行里炮弹相对炮口最高爬升了多少
##   hit     是否打中靶车
##
## 判据：每一行都必须 `hit=tank`；`climb` 大于 2 m 而没打中的行就是"打到天上"。
##
## 用法：godot.exe --headless --path . res://tools/NearProbe.tscn

const DISTS := [2.5, 3.0, 3.5, 4.0, 5.0, 6.5, 9.0]
## 瞄准点高度：1.1 = 车体中心，2.2 = 炮塔中心
const AIM_Y := [1.1, 2.2]
const SETTLE := 40
const DUMMY_HP := 1000000

var _main: Node
var _rows: Array = []
var _yaw := 0.0


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	Settings.selected_tank = "falcon"
	_main = get_node("Main")
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	# 让敌人计数永不为 0：清空靶车不该触发"肃清"而重建玩家
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 8:
		await get_tree().physics_frame

	var p: Player = _main.player
	_yaw = _open_yaw(p, _main.arena)
	if _yaw == INF:
		print("VERDICT no open firing lane")
		get_tree().quit(1)
		return
	p.rotation.y = _yaw
	_main.rig.aim_yaw = _yaw

	for d in DISTS:
		for ay in AIM_Y:
			_rows.append(await _run(p, float(d), float(ay)))

	_print_table()
	get_tree().quit(0 if _misses() == 0 else 1)


func _open_yaw(p: Player, arena: Arena) -> float:
	var eye: Vector3 = p.global_position + Vector3(0, 1.5, 0)
	for step in 72:
		var yaw := deg_to_rad(float(step) * 5.0)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var ok := true
		for d in [3.0, 6.0, 9.0]:
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


func _run(p: Player, d: float, aim_y: float) -> Dictionary:
	var ctr: Vector3 = p.global_position + Vector3(-sin(_yaw), 0.0, -cos(_yaw)) * d
	var e := Enemy.new()
	e.configure(1, 3, 1)
	e.max_hp = DUMMY_HP
	e.setup(_main, _main.arena, ctr)
	_main.add_child(e)
	_main.enemies.append(e)
	e.hp = DUMMY_HP
	e.rotation.y = _yaw + PI
	e.set_physics_process(false)
	await get_tree().physics_frame
	# 交警卫别把靶车推开
	e.global_position = ctr
	e.rotation.y = _yaw + PI
	p.rotation.y = _yaw
	_main.rig.aim_yaw = _yaw

	var target: Vector3 = ctr + Vector3(0, aim_y, 0)
	var pivot: Vector3 = p.global_position + Vector3(0, p.aim_height, 0)
	var to: Vector3 = target - pivot
	var flat := Vector2(to.x, to.z).length()
	var ideal := rad_to_deg(atan2(to.y, maxf(flat, 0.5)))
	_main.rig.aim_pitch = clampf(atan2(to.y, maxf(flat, 0.5)),
			Tank.PITCH_MIN, Tank.PITCH_MAX)
	for _i in SETTLE:
		e.hp = DUMMY_HP
		await get_tree().physics_frame

	# 炮管已经按这一帧的准星更新过，下一物理帧开火（与实战的输入顺序一致）
	var aim := rad_to_deg(_main.rig.aim_pitch)
	var barrel := rad_to_deg(p.barrel.rotation.x)
	# 真正发射的位置：近战里 fire() 会把出发点沿炮管收回，探针必须看同一个点
	var spawn: Vector3 = p.shot_origin(p.aim_dir())
	var inside := _muzzle_inside(p, spawn)
	var dist_to_ctr := Vector2(ctr.x - spawn.x, ctr.z - spawn.z).length()

	p.reload_t = 0.0
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
				climb = maxf(climb, c.global_position.y - spawn.y)
		if not any:
			break

	var row := {
		"dist": d, "aimY": aim_y, "ideal": ideal, "aim": aim, "barrel": barrel,
		"spawnY": spawn.y, "inside": inside, "spawnD": dist_to_ctr,
		"climb": climb, "hit": (e.hp < DUMMY_HP) and fired,
	}
	e.alive = false
	e.set_physics_process(true)
	_main.enemies.erase(e)
	e.queue_free()
	await get_tree().physics_frame
	return row


func _muzzle_inside(p: Player, at: Vector3) -> int:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = at
	q.collision_mask = Tank.LAYER_TANK
	q.collide_with_areas = false
	q.exclude = [p.get_rid()]
	return p.get_world_3d().direct_space_state.intersect_point(q).size()


func _misses() -> int:
	var n := 0
	for r in _rows:
		if not bool(r["hit"]):
			n += 1
	return n


func _print_table() -> void:
	print("---- NEAR RANGE FIRE TABLE ----")
	print("  pitch [%.1f, %.1f] deg" % [rad_to_deg(Tank.PITCH_MIN), rad_to_deg(Tank.PITCH_MAX)])
	print("  dist  aimY  ideal    aim barrel spawnY inside spawnD  climb  hit")
	for r in _rows:
		print("%5.1f %5.1f %6.1f %6.1f %6.1f %6.2f %6d %6.2f %6.2f  %s" % [
				r["dist"], r["aimY"], r["ideal"], r["aim"], r["barrel"],
				r["spawnY"], r["inside"], r["spawnD"], r["climb"],
				"tank" if bool(r["hit"]) else "MISS"])
	print("VERDICT miss=%d / %d %s" % [
			_misses(), _rows.size(), "OK" if _misses() == 0 else "FAIL"])
