extends Node
## 临时验收：驾驶转向的"持续感"，以及墙面视觉比碰撞格宽多少。
##
## 玩家反馈两件事：
##   1. 左右转向不灵活；
##   2. 有时候还能看到坦克穿墙。
##
## 这里把两件事都量成数字：
##   * turn  —— 按住 W+A 时车头会不会**持续**转、松开 A 之后会不会被拉回去；
##              以及"原地 A 转完再按 W"会不会开回原来的方向。
##   * clip  —— 一格宽走廊里，墙面视觉比碰撞格宽出多少、车体视觉比碰撞轮廓宽多少。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --headless --path <proj> res://tools/SteerClipProbe.tscn

const STEP := 1.0 / 120.0

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	var main := get_node("Main")
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 90 and not _started:
		_started = true
		_run()


func _main() -> Node:
	return get_node("Main")


func _clear_all(a: Arena) -> void:
	for n in a._blocks.values():
		n.queue_free()
	a._blocks.clear()
	a.brick_hp.clear()
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			a.grid[y][x] = Arena.EMPTY
	a._rebuild_all()


func _release_all() -> void:
	for n in ["move_forward", "move_back", "turn_left", "turn_right"]:
		Input.action_release(n)


func _pose(main: Node, home: Vector3, yaw: float) -> void:
	var p: Player = main.player
	_pose_raw(p, home, yaw)


func _pose_raw(p: Player, home: Vector3, yaw: float) -> void:
	p.global_position = home
	p.rotation.y = yaw
	p._speed = 0.0
	p.velocity = Vector3.ZERO
	p.turn_blocked = false
	p.shield_t = 0.0
	p._pending_shot = false
	p.hp = 1000000
	if p.turret != null:
		p.turret.rotation.y = 0.0
	var rig: CameraRig = get_node("Main").rig
	rig.yaw = yaw
	rig.aim_yaw = yaw
	rig.aim_pitch = 0.0


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	var p: Player = main.player
	main.set_process(false)
	main.state = "play"
	main.state_timer = 1e9
	main.spawn_queue.clear()
	main.max_active = 0
	p.set_physics_process(false)
	Settings.drive_relative = true
	_clear_all(a)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var home := Arena.cell_center(12, 12)
	_pose(main, home, 0.0)

	# ---- 1. W 一直按着，中途按下 A ----
	print("PROBE turn tank=%s turn_speed=%.2f" % [p.tank_id, p.turn_speed])
	_release_all()
	Input.action_press("move_forward")
	for i in 120:
		await get_tree().physics_frame
		p.tick(STEP)
	print("PROBE turn W_only   t=1.00 hull%+7.1f aim%+7.1f spd%5.1f" % [
		rad_to_deg(p.rotation.y), rad_to_deg(main.rig.aim_yaw), p.speed()])
	Input.action_press("turn_left")
	var t0 := 1.0
	var next := 1.0
	for i in 300:
		await get_tree().physics_frame
		p.tick(STEP)
		var t := t0 + float(i + 1) * STEP
		if i % 30 == 29:
			print("PROBE turn W+A %4.2fs hull%+7.1f aim%+7.1f err%+7.1f spd%5.1f" % [
				t, rad_to_deg(p.rotation.y), rad_to_deg(main.rig.aim_yaw),
				rad_to_deg(angle_difference(p.rotation.y, main.rig.aim_yaw)),
				p.speed()])
		next = t
	Input.action_release("turn_left")
	for i in 120:
		await get_tree().physics_frame
		p.tick(STEP)
		if i % 30 == 29:
			print("PROBE turn rel%4.2fs hull%+7.1f aim%+7.1f err%+7.1f spd%5.1f" % [
				next + float(i + 1) * STEP, rad_to_deg(p.rotation.y),
				rad_to_deg(main.rig.aim_yaw),
				rad_to_deg(angle_difference(p.rotation.y, main.rig.aim_yaw)),
				p.speed()])
	_release_all()

	# ---- 2. 原地按 A 转完，再按 W：车会不会开回原来的方向 ----
	_pose(main, home, 0.0)
	Input.action_press("turn_left")
	for i in 96:
		await get_tree().physics_frame
		p.tick(STEP)
	Input.action_release("turn_left")
	var yaw_pivot := rad_to_deg(p.rotation.y)
	var aim_pivot := rad_to_deg(main.rig.aim_yaw)
	for i in 30:
		await get_tree().physics_frame
		p.tick(STEP)
	Input.action_press("move_forward")
	for i in 120:
		await get_tree().physics_frame
		p.tick(STEP)
		if i % 30 == 29:
			print("PROBE pivot W %4.2fs hull%+7.1f aim%+7.1f spd%5.1f d=(%+.2f,%+.2f)" % [
				float(i + 1) * STEP, rad_to_deg(p.rotation.y),
				rad_to_deg(main.rig.aim_yaw), p.speed(),
				p.global_position.x - home.x, p.global_position.z - home.z])
	_release_all()
	print("PROBE pivot done  afterA hull%+7.1f aim%+7.1f" % [yaw_pivot, aim_pivot])

	# ---- 3. 墙面 / 车体视觉尺寸 ----
	print("PROBE clip cell=%.2f" % Arena.CELL)
	for key in ["wall_brick_a", "wall_brick_b", "wall_brick_c",
			"wall_brick_dmg_a", "wall_brick_dmg_b", "wall_brick_dmg_c",
			"wall_steel_a", "wall_steel_b", "water_surface"]:
		var m: Mesh = Assets.mesh_of(key)
		if m == null:
			print("PROBE clip %-18s MISSING" % key)
			continue
		var box := m.get_aabb()
		print("PROBE clip %-18s size=(%.2f, %.2f, %.2f) center=(%.2f, %.2f, %.2f) over=%.2f" % [
			key, box.size.x, box.size.y, box.size.z, box.position.x, box.position.y,
			box.position.z, maxf(box.size.x, box.size.z) - Arena.CELL])

	# 单格宽走廊：x=11 / x=13 砌墙，车停在 x=12 的中线上
	for y in range(4, 21):
		a.grid[y][11] = Arena.BRICK
		a.grid[y][13] = Arena.BRICK
	a._rebuild_all()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var left_face := -1e9
	var right_face := 1e9
	for y in range(4, 21):
		var body: Node3D = a._blocks[Vector2i(11, y)]
		var mi := body.get_node_or_null("Visual") as MeshInstance3D
		if mi == null:
			continue
		var bb: AABB = mi.global_transform * mi.get_aabb()
		left_face = maxf(left_face, bb.position.x + bb.size.x)
		body = a._blocks[Vector2i(13, y)]
		mi = body.get_node_or_null("Visual") as MeshInstance3D
		if mi == null:
			continue
		bb = mi.global_transform * mi.get_aabb()
		right_face = minf(right_face, bb.position.x)
	var cell_lo := Arena.cell_center(11, 12).x + Arena.CELL * 0.5
	var cell_hi := Arena.cell_center(13, 12).x - Arena.CELL * 0.5
	print("PROBE clip corridor visibleFace x in [%.2f, %.2f], cellEdge x in [%.2f, %.2f], squeeze=%.2f/side" % [
		left_face, right_face, cell_lo, cell_hi,
		maxf(cell_lo - left_face, right_face - cell_hi)])
	_pose(main, Arena.cell_center(12, 12), 0.0)
	for i in 6:
		await get_tree().physics_frame
		p.tick(STEP)
	var hull := _hull_aabb(p)
	var vis_w := right_face - left_face
	print("PROBE clip tank %-12s hullVisual=(%.2f x %.2f) collisionD=%.2f over=%.2f/side" % [
		p.tank_id, hull.size.x, hull.size.z, p.body_radius * 2.0,
		maxf(hull.size.x - p.body_radius * 2.0, 0.0) * 0.5])
	print("PROBE clip tank in corridor: visibleSlot=%.2f hull=%.2f overlap=%.2f/side" % [
		vis_w, hull.size.x, maxf((hull.size.x - vis_w) * 0.5, 0.0)])
	get_tree().quit(0)


## 车体（Hull 子树，不含炮塔与炮管）在车体局部系里的包围盒尺寸
func _hull_aabb(t: Tank) -> AABB:
	var out := AABB()
	var first := true
	for mi in _meshes(t):
		if mi.name.begins_with("Shield") or mi.name.begins_with("Guide"):
			continue
		# 护盾球是自车身上唯一的 SphereMesh，而且平时不可见；它不是轮廓的一部分
		if not mi.visible or mi.mesh is SphereMesh:
			continue
		var n: Node = mi
		var is_gun := false
		while n != null and n != t:
			if String(n.name).begins_with("Turret") or String(n.name).begins_with("Barrel") \
					or String(n.name).begins_with("Muzzle"):
				is_gun = true
				break
			n = n.get_parent()
		if is_gun:
			continue
		var a: AABB = mi.get_aabb()
		var xf := Transform3D.IDENTITY
		var q: Node = mi
		while q != null and q != t:
			if q is Node3D:
				xf = (q as Node3D).transform * xf
			q = q.get_parent()
		a = xf * a
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and n.mesh != null:
		out.append(n)
	for c in n.get_children():
		if c is CollisionShape3D:
			continue
		out.append_array(_meshes(c))
	return out
