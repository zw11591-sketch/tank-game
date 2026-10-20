extends Node
## 临时验收脚本：把这轮五条诉求逐条跑成可打印的结论。
##
##   1. 穿越障碍物   —— 把车按满油门怼进掩体，检查整条车身是否仍在空地上
##   2. 叠车卡死     —— 两辆车完全重合后放开物理，检查能否分开并恢复机动
##   3. 射击反馈     —— 预热是否生效、一秒内能打几发、弹道飞行耗时
##   4. 场地道具     —— 连续空投能否稳定落地、场上数量上限是否成立
##   5. 地形数量     —— 每张图都能生成、出生点互通、空投找得到落点
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：临时在 project.godot 的 [autoload] 加一行 Verify="*res://tools/verify_probe.gd"，
## 跑完立刻删掉。

var _f := 0
var _stage := 0
var _fire_count := 0
var _fire_window := 0


func _ready() -> void:
	await get_tree().process_frame
	var main := get_tree().current_scene
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()
	main.state = "play"
	print("PROBE boot terrains=%d fxWarm=%s" % [Arena.TERRAINS.size(), str(Fx._warm)])


# ---------------- 5. 地形：每张图都要能开局 ----------------

func _check_terrains() -> void:
	var main := get_tree().current_scene
	var a: Arena = main.arena
	for i in Arena.TERRAINS.size():
		var worst_ok := true
		var drop_ok := true
		for st in [1, 4, 8]:
			a.generate(st, i)
			if not a._spawns_connected():
				worst_ok = false
			if a.random_open_cell([a.base_position()], 15.0, [], 20.0) == Vector3.INF:
				drop_ok = false
		print("PROBE terrain%-3d layout=%-9s connected=%-5s dropSpot=%-5s" % [
			i, String(Arena.TERRAINS[i]["layout"]), str(worst_ok), str(drop_ok)])
	a.generate(1, 0)


# ---------------- 1. 把车怼进墙 ----------------

## 找一面墙，把车停在它正前方 3 米处对着它，满油门推 1.5 秒，看车身有没有进墙。
func _check_walls() -> void:
	var main := get_tree().current_scene
	var a: Arena = main.arena
	var p: Player = main.player
	var tested := 0
	var breached := 0
	var deepest := 0.0
	for y in range(2, Arena.GRID_H - 2):
		for x in range(2, Arena.GRID_W - 2):
			if not a.blocks_tank(x, y):
				continue
			# 墙的南侧要有两格空地，才放得下车并留出加速距离
			if a.blocks_tank(x, y + 1) or a.blocks_tank(x, y + 2):
				continue
			tested += 1
			if tested > 24:
				break
			var wall := Arena.cell_center(x, y)
			p.global_position = wall + Vector3(0, 0, Arena.CELL * 1.6)
			p.rotation.y = PI          # 车头指向 -Z 的反面，即朝墙（+Z 的反向）
			p.rotation.y = 0.0
			p.global_position = wall + Vector3(0, 0, Arena.CELL * 1.6)
			p._speed = 0.0
			p._safe_pos = p.global_position
			for _i in 180:
				p.drive(1.0, 0.0, 1.0 / 120.0)
			# 车头探进墙里多深：车鼻中心到墙面的距离
			var nose := p.global_position - p.global_transform.basis.z * p._nose_f
			var face := wall.z + Arena.CELL * 0.5
			deepest = maxf(deepest, face - (nose.z - p._nose_r))
			if not p._spine_clear():
				breached += 1
		if tested > 24:
			break
	print("PROBE walls tested=%d breached=%d noseIntoWall=%.2fm" % [tested, breached, deepest])


# ---------------- 2. 叠车 ----------------

## 把一辆敌人瞬移到玩家身上完全重合，然后交给 main._physics_process 解交。
func _stack_tanks() -> void:
	var main := get_tree().current_scene
	var p: Player = main.player
	# 关卡刚开始时生成队列还没走到，这里直接要一辆敌人出来
	while main._count_active() < 2:
		if not main._spawn_enemy(1):
			break
	var e := _first_enemy()
	if e == null:
		print("PROBE stack no_enemy")
		return
	# 搬到一块空地上做试验，否则"分不开"与"被墙挡住"两种结论会混在一起
	var home := _find_open()
	# 最恶劣的工况：完全重合 + 同朝向 + 双方都在踩油门正面对顶
	p.global_position = home
	p.rotation.y = 0.0
	p._speed = 0.0
	p._safe_pos = home
	e.global_position = home
	e.rotation.y = 0.0
	e._speed = 0.0
	e._safe_pos = home
	print("PROBE stack start dist=%.2f tanks=%d" % [
		p.global_position.distance_to(e.global_position), main.all_tanks().size()])


## 一块 5x5 格全空的地面：试验结论不该被墙污染
func _find_open() -> Vector3:
	var a: Arena = get_tree().current_scene.arena
	for y in range(3, Arena.GRID_H - 3):
		for x in range(3, Arena.GRID_W - 3):
			var ok := true
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					if a.blocks_tank(x + dx, y + dy):
						ok = false
						break
				if not ok:
					break
			if ok:
				return Arena.cell_center(x, y)
	return Arena.cell_center(Arena.GRID_W / 2, Arena.GRID_H / 2)


func _first_enemy() -> Tank:
	var main := get_tree().current_scene
	for t in main.enemies:
		if is_instance_valid(t) and t.alive:
			return t
	return null


func _stack_report() -> void:
	var main := get_tree().current_scene
	var p: Player = main.player
	var e := _first_enemy()
	if e == null or p == null:
		print("PROBE stack report no_pair")
		return
	var d := p.global_position.distance_to(e.global_position)
	var need: float = p.body_radius + e.body_radius
	# 解交之后还得能开得动：回到空地满油门推 0.5 秒看实际位移
	p.global_position = _find_open()
	p._safe_pos = p.global_position
	p._speed = 0.0
	var was := p.global_position
	for _i in 60:
		p.drive(1.0, 0.0, 1.0 / 120.0)
	var moved := p.global_position.distance_to(was)
	print("PROBE stack after dist=%.2f need=%.2f separated=%s playerMoved=%.2fm" % [
		d, need, str(d >= need * 0.95), moved])


# ---------------- 3. 射击反馈 ----------------

func _fire_report() -> void:
	var main := get_tree().current_scene
	var p: Player = main.player
	print("PROBE fire reload=%.2fs shotsPerSec=%.1f apSpeed=%.0f flight40m=%.3fs buffer=%.2fs" % [
		p.reload_time, 1.0 / p.reload_time, Shell.AP_SPEED,
		40.0 / Shell.AP_SPEED, Player.FIRE_BUFFER])
	print("PROBE fire burstShots=%d in %.2fs (fxWarm=%s)" % [
		_fire_count, _fire_window / 120.0, str(Fx._warm)])


# ---------------- 4. 场地空投 ----------------

func _drop_report() -> void:
	var main := get_tree().current_scene
	var ok := 0
	for _i in 12:
		if main._field_drop():
			ok += 1
	print("PROBE drops attempts=12 landed=%d onGround=%d cap=%d minGap=%.1fs maxGap=%.1fs" % [
		ok, main.powerups.size(), main.FIELD_DROP_MAX_ON_GROUND,
		main.FIELD_DROP_MIN, main.FIELD_DROP_MAX])


func _physics_process(_d: float) -> void:
	_f += 1
	var main := get_tree().current_scene
	if main == null:
		return
	if main.player != null and is_instance_valid(main.player):
		main.player.shield_t = 0.0

	# 连射计数窗口：直接调 fire()，统计 2 秒里打出几发
	if _f > 360 and _f <= 600:
		_fire_window += 1
		if main.player != null and is_instance_valid(main.player) and main.player.fire():
			_fire_count += 1

	match _f:
		120:
			_stack_tanks()
			# 正面对顶才是最难解的工况：让玩家在整个解交窗口里一直踩着油门
			Input.action_press("move_forward")
		320:
			Input.action_release("move_forward")
			_stack_report()
		601:
			_fire_report()
		640:
			_drop_report()
		680:
			_check_walls()
		720:
			_check_terrains()
		760:
			print("PROBE done")
			get_tree().quit(0)
