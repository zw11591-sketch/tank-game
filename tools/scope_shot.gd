extends Node
## 渲染验收：狙击镜里的"边瞄准边射击"。
##
## 无头模式不执行 Control._draw()，所以镜内的锁定读数与提前量标尺在自检里看不到。
## 这里开一个真实窗口、举镜、让一辆敌车横向匀速驶过 40 m 外，拍两张：
##
##   * tools/shots/scope_lock.png —— 准星持续压在敌车上、火控锁定成立后的画面：
##     期望有镜筒圆框、"火控锁定"、"自动补偿 x.x m · y.yys"，以及目标前方那个
##     橙色圆环（炮弹该去的位置，由火控自动补偿）。
##   * tools/shots/scope_lead.png —— 准星移开车身几米、锁定已掉、标尺仍保留的瞬间：
##     期望圆环还在，文案回到"提前量 x.x m · y.yys"（提示玩家自己把准星压上去）。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
##
## 用法：godot.exe --path . res://tools/ScopeShot.tscn

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"
const TARGET_SPEED := 12.0
## 锁定前的截图帧（120 Hz 下 0.167 s）：进度条走到约四成、文案还是"提前量"。
const LEAD_FRAMES := 20
## 锁定成立后的截图帧（0.4 s 约 48 帧，留冗余）。
const LOCK_FRAMES := 70
const DUMMY_HP := 1000000

var _main: Node
var _armed := false
var _done := false
var _f := 0
var _t := 0.0
var _enemy: Enemy
var _tgt0 := Vector3.ZERO
var _vel := Vector3.ZERO


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1600, 900)
	Settings.apply_display()
	DirAccess.make_dir_recursive_absolute(DIR)
	_main = get_node("Main")
	_main._sel_tank = 1
	_main._sel_diff = 1
	_main._sel_stage = 2
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.spawn_queue = [1]
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 8:
		await get_tree().physics_frame
	_main.state = "play"
	var p: Player = _main.player
	if p != null:
		p.shield_t = 0.0
		p.hp = p.max_hp
	var lane := _open_lane(p, _main.arena)
	var yaw := float(lane["yaw"])
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var side := Vector3(cos(yaw), 0.0, -sin(yaw))
	_tgt0 = p.global_position + fwd * 40.0
	_vel = side * TARGET_SPEED

	_enemy = Enemy.new()
	_enemy.configure(1, 3, 1)
	_enemy.max_hp = DUMMY_HP
	_enemy.setup(_main, _main.arena, _tgt0)
	_main.add_child(_enemy)
	_main.enemies.append(_enemy)
	_enemy.team = 1
	_enemy.hp = DUMMY_HP
	_enemy.set_physics_process(false)
	# 位置由本脚本逐帧摆，但 `motion_velocity()` 读的是朝向 × `_speed`：
	# 不手动给这两项，敌车在画面上在动、对火控却是一辆静止车，提前量标尺直接不画。
	_enemy.rotation.y = yaw - PI * 0.5
	_enemy._speed = TARGET_SPEED
	# 举镜：player.tick() 每帧都读这个动作，按下去之后镜头才会切到炮手视角
	Input.action_press("aim_scope")
	_armed = true


func _physics_process(delta: float) -> void:
	if not _armed or _done:
		return
	_f += 1
	_t += delta
	_enemy.global_position = _tgt0 + _vel * fmod(_t, 6.0)
	var at: Vector3 = _enemy.global_position + Vector3(0, 1.05, 0)
	# 一直跟瞄：和玩家把准星压在车上不放是同一件事
	_aim_at(at)

	if _f == LEAD_FRAMES:
		_capture("scope_lead")
		var p0: Player = _main.player
		print("SHOT scope_lead.png  sniper=%s  lock=%s  ratio=%.2f"
				% [str(_main.rig.sniper), str(p0.scope_lock_ready), p0.scope_lock_ratio])
	elif _f >= LOCK_FRAMES:
		_done = true
		_capture("scope_lock")
		var p: Player = _main.player
		print("SHOT scope_lock.png  sniper=%s  lock=%s  lead=%.2fm"
				% [str(_main.rig.sniper), str(p.scope_lock_ready), p.scope_lead_len])
		Input.action_release("aim_scope")
		await get_tree().process_frame
		get_tree().quit(0)


func _aim_at(at: Vector3) -> void:
	var p: Player = _main.player
	var d: Vector3 = at - p.barrel.global_position
	_main.rig.aim_yaw = atan2(-d.x, -d.z)
	_main.rig.aim_pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()),
			Tank.PITCH_MIN, Tank.PITCH_MAX)
	# 准星射线按角度缓存，手动改角度之后必须重打一次
	_main.rig.invalidate_aim()


func _capture(tag: String) -> void:
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")


## 找一条最长的直线走廊（1 m 步进扫 96 m）
func _open_lane(p: Player, arena: Arena) -> Dictionary:
	var best := {"yaw": 0.0, "dist": 0.0}
	for step in 288:
		var yaw := deg_to_rad(float(step) * 1.25)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var clear := 0.0
		for i in range(4, 96):
			var pos: Vector3 = p.global_position + dir * float(i)
			var c := Arena.to_cell(pos)
			if c.x < 1 or c.y < 1 or c.x > Arena.GRID_W - 2 or c.y > Arena.GRID_H - 2:
				break
			if arena.blocks_tank(c.x, c.y):
				break
			clear = float(i)
		if clear > float(best["dist"]):
			best = {"yaw": yaw, "dist": clear}
	return best
