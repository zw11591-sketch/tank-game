extends Node
## 临时诊断：玩家反馈的两件事，各量成一个数字。
##   1. 车体**可见**轮廓压进墙里的深度（用模型真实包围盒，而不是名册尺寸）；
##   2. 五款车的原地转向耗时，以及转向时镜头的滞后角。
## 打印全 ASCII。

const STEP := 1.0 / 120.0
## 每款车车体的可见半宽 / 半长（前 -Z、后 +Z），由 _HullProbe 量得。
const VIS := {
	"tank_player": Vector3(1.77, 2.60, 2.61),
	"tank_scout": Vector3(1.63, 2.35, 2.26),
	"tank_heavy": Vector3(1.92, 2.85, 2.86),
	"tank_artillery": Vector3(1.74, 2.70, 3.33),
	"tank_destroyer": Vector3(1.77, 2.89, 2.90),
	"tank_boss": Vector3(2.33, 3.40, 3.49),
}

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()
	await get_tree().process_frame
	_main.state = "play"
	_main.state_timer = 1e9
	_main.player.shield_t = 0.0

	var p: Player = _main.player
	var a: Arena = _main.arena
	_clear(a)
	a._rebuild_all()
	await _frames(4)
	print("PROBE tank=%s rosterHalf=(%.2f, %.2f) settleHalf=(%.2f, %.2f) visFront/Back=(%.2f, %.2f)" % [
		p.tank_id, p.body_radius, p.body_length * 0.5,
		p._hull_half_w, p._hull_half_l, _vis(p).y, _vis(p).z])

	# ---- 1a. 车头正撞墙（0 / 20 / 45 度入射） ----
	for deg in [0.0, 20.0, 45.0]:
		await _ram(p, a, deg, 1.0)

	# ---- 1b. 倒车撞墙 ----
	await _ram(p, a, 0.0, -1.0)

	# ---- 1c. 贴着墙平行开，再持续打舵 ----
	await _wall_turn(p, a, 2.35)

	# ---- 2. 五款车：原地 90 度要多久、镜头落后多少度 ----
	for id in TankRoster.ORDER:
		await _pivot_all(id)

	get_tree().quit(0)


func _vis(p: Player) -> Vector3:
	return VIS.get(p.model_key(), Vector3(1.7, 2.2, 2.2))


func _clear(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


func _reset(p: Player, pos: Vector3, yaw := 0.0) -> void:
	p.global_position = pos
	p.rotation.y = yaw
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p._safe_pos = pos


## 可见矩形压进实心格的最大深度：在矩形上密采样，取最深的点
func _vis_depth(p: Player, a: Arena) -> float:
	var v := _vis(p)
	var yaw: float = p.rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	# 矩形的实际中心不在原点：车头 / 车尾伸出的长度不同
	var center: Vector3 = p.global_position + fwd * (v.y - v.z) * 0.5
	var hl := (v.y + v.z) * 0.5
	var deep := 0.0
	for iz in 9:
		for ix in 9:
			var u := (float(ix) / 8.0 - 0.5) * 2.0
			var w := (float(iz) / 8.0 - 0.5) * 2.0
			var pt: Vector3 = center + right * (u * v.x) + fwd * (w * hl)
			deep = maxf(deep, _point_depth(a, pt))
	return deep


func _point_depth(a: Arena, pt: Vector3) -> float:
	var c := Arena.to_cell(pt)
	if not a.blocks_tank(c.x, c.y):
		return 0.0
	var center := Arena.cell_center(c.x, c.y)
	var half := Arena.CELL * 0.5
	return minf(half - absf(pt.x - center.x), half - absf(pt.z - center.z))


## 撞墙：墙在第 4 行（z 更小），车从南侧朝 -Z 开过去。dir=1 用车头，dir=-1 用倒车。
func _ram(p: Player, a: Arena, deg: float, dir: float) -> void:
	for x in range(2, 22):
		a.grid[4][x] = Arena.STEEL
	a._rebuild_all()
	var start := Arena.cell_center(11, 10)
	_reset(p, start, 0.0)
	await _frames(2)
	p.rotation.y = deg_to_rad(deg)
	var deepest := 0.0
	var worst_settle := 0.0
	var frames := 0
	for i in 240:
		p.drive(dir, 0.0, STEP)
		var d := _vis_depth(p, a)
		worst_settle = maxf(worst_settle, p._hull_depth(p.rotation.y))
		deepest = maxf(deepest, d)
		if d > 0.05:
			frames += 1
	print("PROBE ram deg=%3.0f dir=%+.0f visDeep=%.2f settleDeep=%.2f frames>5cm=%3d/240 z=%.1f" % [
		deg, dir, deepest, worst_settle, frames, p.global_position.z])
	_clear(a)
	a._rebuild_all()
	await _frames(2)


func _wall_turn(p: Player, a: Arena, dist: float) -> void:
	for y in range(2, 22):
		a.grid[y][12] = Arena.BRICK
	a._rebuild_all()
	var c := Arena.cell_center(11, 14)
	var pos := Vector3(-dist, 0.0, c.z)
	_reset(p, pos, 0.0)
	await _frames(2)
	var deepest := 0.0
	var blocked := 0
	var yaw0: float = p.rotation.y
	for i in 300:
		p.drive(1.0, 1.0, STEP)
		deepest = maxf(deepest, _vis_depth(p, a))
		if p.turn_blocked:
			blocked += 1
	print("PROBE wallturn dist=%.2f turned=%.1f visDeep=%.2f blocked=%d/300" % [
		dist, rad_to_deg(absf(angle_difference(yaw0, p.rotation.y))), deepest, blocked])
	_clear(a)
	a._rebuild_all()
	await _frames(2)


func _pivot_all(id: String) -> void:
	var p := Player.new()
	p.tank_id = id
	add_child(p)
	await get_tree().process_frame
	p.game = _main
	p.arena = _main.arena
	var rig := CameraRig.new()
	add_child(rig)
	rig.target = p
	p.set_physics_process(false)

	_reset(p, Arena.cell_center(12, 12), 0.0)
	await _frames(4)
	var y0: float = p.rotation.y
	var lag := 0.0
	var t := 0.0
	var done := -1.0
	for i in 240:
		p.drive(0.0, 1.0, STEP)
		# 相对驾驶里 A/D 会把准星一起带着转（Player._carry_aim_with_steer），
		# 所以镜头不会被"准星死区"钳住，这里按同样的方式推进参照。
		rig.aim_yaw = p.rotation.y
		rig._follow(STEP)
		t = float(i + 1) * STEP
		if t > 0.3:
			lag = maxf(lag, rad_to_deg(absf(angle_difference(rig.yaw, p.rotation.y))))
		var turned := rad_to_deg(absf(angle_difference(y0, p.rotation.y)))
		if done < 0.0 and turned >= 90.0:
			done = t
	print("PROBE pivot %-6s turn=%.2f rate=%.0fdeg/s t90=%.2fs camLag=%.1f" % [
		id, p.turn_speed, rad_to_deg(p.turn_speed), done, lag])
	p.queue_free()
	rig.queue_free()
	await get_tree().process_frame
