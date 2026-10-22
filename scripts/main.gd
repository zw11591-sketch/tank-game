extends Node3D
## 主协调器：标题 / 难度选关 / 关卡流程 / 波次生成 / 计分连击 / 道具 / 胜负判定。
## 所有子节点（战场、坦克、炮弹、道具、HUD）均在运行时构建。

const MAX_STAGE := 8
const MAX_LIVES := 3
const COMBO_WINDOW := 4.5
const COMBO_MAX := 5.0
const DROP_CHANCE := 0.34

## 场地补给：战斗中定时空投，与击杀掉落互不干扰。
## 有了它，玩家在没打死人的空窗期也有"去抢个增益"的事可做。
## 间隔压到 8~13 秒并允许场上同时存在 4 个，于是"场地上时不时能看到道具"
## 是常态而不是偶然——绕路去抢补给因此成了一条稳定的玩法线。
const FIELD_DROP_MIN := 8.0
const FIELD_DROP_MAX := 13.0
const FIELD_DROP_MAX_ON_GROUND := 4
## 空投找不到合适落点时的重试间隔。满场或地形太封闭时不该白等一整个周期。
const FIELD_DROP_RETRY := 2.5
## 单帧最多把一对重叠坦克分开这么远，避免解交时把车弹出去
const SEPARATE_STEP := 0.35
## 顶在一起多久之后开始加侧向滑移。纯径向分离遇到正面对顶会原地僵死：
## 推开多少、油门就顶回来多少，所以必须有一个切向分量让两车错开。
const SLIP_DELAY := 0.22
## 侧向滑移的速度上限（m/s）与增长率（m/s 每秒接触）。
##
## 这里刻意用"速度"而不是"位移比例"：早先的写法把切向量乘在重叠深度上，
## 而 move_and_slide 的 safe_margin 会把两辆车停在几乎零重叠的位置——
## 于是最需要错开的正面对顶恰好拿到接近 0 的侧滑，两车能顶死一秒以上。
## 改成按接触时长积分出一个侧移速度后，解交能力与重叠深度彻底解耦。
const SLIP_SPEED := 3.0
const SLIP_ACCEL := 6.0
## 卡死检测用的接触半径倍数。比分离阈值(1.02)宽，因为物理安全边距会把两车
## 停在刚好不重叠的位置：那时几何上"没有重叠"，但双方油门互顶，照样谁也动不了。
const JAM_K := 1.10
## 单帧位移低于这个值（米）就认为这辆车没在动。120Hz 下约合 0.6 m/s。
## 侧滑只在双方同时卡住时才介入，所以并排行驶、擦身而过都不会被干扰。
const JAM_STEP := 0.005
## 玩家在互推修正里承担的份额。给得很低，于是撞上敌人是把对方顶开。
const PLAYER_PUSH_SHARE := 0.16

var arena: Arena
var fx_root: Node3D
var rig: CameraRig
var hud: HUD

var player: Player = null
var enemies: Array = []
var powerups: Array = []
var damage_marks: Array = []
## 场上的烟幕云团：{ "pos": Vector3, "r": float, "t": float }。
## 隐蔽效果按"车在不在云里"判定，而不是给坦克挂一个计时状态——
## 后者会让烟幕跟着车走，开出去照样隐身。
var smoke_clouds: Array = []
const SMOKE_RADIUS := 5.6
const SMOKE_CLOUDS_MAX := 4
## 坦克两两接触的持续时长："pair key" -> 秒。侧向滑移的强度由它决定。
var _contact: Dictionary = {}
## 上一物理帧各坦克的位置：instance_id -> Vector3。
## 用来判断"这辆车真的没在动"——drive() 里的 _speed 是指令速度，顶住墙时它仍然很大，
## 所以不能拿它当卡死依据，必须看实际位移。
var _motion: Dictionary = {}

var score := 0
var high_score := 0
var stage := 1
var lives := MAX_LIVES
var difficulty := 1
## 当前地形（Arena.TERRAINS 下标）
var terrain := 0
## "随机地形"模式下本局的轮换起点
var _terrain_offset := 0

var state := "title"
var state_timer := 0.0
var banner_text := ""

## 受击暗角强度（0~1），由 on_player_hit 点亮、逐帧衰减。
var hit_vignette := 0.0

## 暂停前所处的状态。继续时必须回到这里，而不是无条件写回 "play"：
## 在 "ready" 下暂停会跳过整段倒计时，在 "clear" 下暂停会让 _update_play
## 把"敌人已清空"再判一次、把过关奖励重复加一遍。
var _state_before_pause := "play"
## 本关的过关奖励是否已经结算过。与状态恢复互补：同一关反复进出 clear 也只发一次。
var _stage_cleared := false

var combo_mult := 1.0
var _combo_t := 0.0
var _kills := 0

var spawn_queue: Array = []
var max_active := 3
var _spawn_t := 1.5
var _respawn_t := 0.0
var _banner_t := 0.0
var _fortify_t := 0.0
var _stage_damage_bonus := 0.0
var _field_t := 10.0
## 敌车发动机声的调度计时（见 _update_enemy_engines）
var _engine_t := 0.0
## 同时可闻的敌车发动机数量上限。发动机是最不紧急的一层声，
## 七台一起响会把语音位吃光，炮声与命中提示反而被丢掉。
const ENGINE_VOICES := 3
const ENGINE_RANGE := 46.0

var _menu: CanvasLayer
var _bg: TextureRect
var _title_l: Label
var _menu_l: Label
## 选车界面专用：左侧选项列 + 右侧 3D 转台与属性卡。
## 它们与 _menu_l 互斥显示——选车界面是"看车"的界面，居中一坨文字排不下这些内容。
var _select_l: Label
var _card: TankCard
var _preview_tex: TextureRect
var _preview_vp: SubViewport
var _preview_holder: Node3D
var _preview_model: Node3D
var _sel_row := 0
var _sel_diff := 1
var _sel_stage := 0
## 所选车型在 TankRoster.ORDER 里的下标
var _sel_tank := 0
## -1 表示"随机"：每关按关号轮换地形
var _sel_terrain := -1
## 暂停菜单里的设置项游标
var _opt_row := 0

const DIFF_NAMES := ["简单", "普通", "困难"]
const SELECT_ROWS := 4


func _ready() -> void:
	randomize()
	_load_high_score()

	# 暂停走 SceneTree.paused。主节点必须始终处理输入，否则按 Esc 之后
	# 连"继续"都收不到；战场里的东西则必须真的停住（炮弹还在飞、
	# 连击窗口还在流逝的暂停等于没暂停）。
	process_mode = Node.PROCESS_MODE_ALWAYS

	arena = Arena.new()
	arena.game = self
	add_child(arena)
	arena.process_mode = Node.PROCESS_MODE_PAUSABLE
	arena.generate(1)

	fx_root = Node3D.new()
	add_child(fx_root)
	fx_root.process_mode = Node.PROCESS_MODE_PAUSABLE
	Audio.set_listener_root(fx_root)
	# 开火、命中、爆炸的粒子着色器都在"第一次用到"时才编译上传，
	# 不预热的话第一发炮必然掉几帧——而那正是玩家判断"反馈跟不跟手"的那一下。
	# 预热发生在标题画面、地面以下 400 米处，所以玩家既看不见也感觉不到。
	Fx.prewarm(fx_root)

	rig = CameraRig.new()
	add_child(rig)
	# 相机也属于"战场"：暂停时不能继续跟随、不能继续吃鼠标
	rig.process_mode = Node.PROCESS_MODE_PAUSABLE

	hud = HUD.new()
	hud.game = self
	hud.visible = false
	add_child(hud)

	_build_menu()
	_enter_title()


# ---------------- 输入 ----------------
#
# 驾驶与火力的按键全部由 player.gd 自行轮询动作映射，这里只处理界面流转，
# 所以不再有 player.on_key() 这种转发链路。

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# 鼠标被捕获期间（倒计时、战斗、肃清结算）都允许环视
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			rig.handle_mouse(event.relative)
		return
	if event.is_echo():
		return

	if event.is_action_pressed("toggle_display"):
		Settings.cycle_display_mode()
		_refresh_mouse_mode()
		return

	match state:
		"title":
			if event.is_action_pressed("ui_accept"):
				_enter_select()
		"select":
			if event.is_action_pressed("ui_up"):
				_sel_row = posmod(_sel_row - 1, SELECT_ROWS)
				_refresh_select()
			elif event.is_action_pressed("ui_down"):
				_sel_row = posmod(_sel_row + 1, SELECT_ROWS)
				_refresh_select()
			elif event.is_action_pressed("ui_left"):
				_adjust_selection(-1)
			elif event.is_action_pressed("ui_right"):
				_adjust_selection(1)
			elif event.is_action_pressed("ui_accept"):
				_confirm_start()
			elif event.is_action_pressed("ui_cancel"):
				_enter_title()
		"ready", "play", "clear":
			if event.is_action_pressed("pause"):
				_set_pause(true)
		"pause":
			if event.is_action_pressed("pause") or event.is_action_pressed("ui_accept"):
				_set_pause(false)
			elif event.is_action_pressed("back_to_title"):
				_enter_title()
			elif event.is_action_pressed("ui_up"):
				_move_option(-1)
			elif event.is_action_pressed("ui_down"):
				_move_option(1)
			elif event.is_action_pressed("ui_left"):
				_adjust_option(-1)
			elif event.is_action_pressed("ui_right"):
				_adjust_option(1)
		"over", "win":
			if event.is_action_pressed("restart"):
				_confirm_start()
			elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_accept"):
				_enter_title()


## 鼠标捕获只跟状态挂钩：战斗相关状态一律捕获，菜单与结算一律放开。
## 这样倒计时阶段也能先把炮塔转到想要的方向。
func _refresh_mouse_mode() -> void:
	var want: bool = state == "ready" or state == "play" or state == "clear"
	var mode := Input.MOUSE_MODE_CAPTURED if want else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != mode:
		Input.mouse_mode = mode


func _set_pause(on: bool) -> void:
	if on:
		_state_before_pause = state
		state = "pause"
		# 暂停必须真的把战场停住：炮弹还在飞、冷却还在走、连击窗口还在流逝的
		# 暂停只是"看不见"，不是"没发生"。
		get_tree().paused = true
		_refresh_mouse_mode()
		_show_menu("", _pause_text())
		_bg.modulate = Color(0.35, 0.35, 0.4, 0.92)
	else:
		state = _state_before_pause
		get_tree().paused = false
		_refresh_mouse_mode()
		_hide_menu()


func _move_option(d: int) -> void:
	var rows: Array = Settings.option_rows()
	_opt_row = posmod(_opt_row + d, rows.size())
	Audio.play("switch")
	_show_menu("", _pause_text())


func _adjust_option(d: int) -> void:
	Settings.adjust(_opt_row, d)
	Audio.play("switch")
	_show_menu("", _pause_text())


func _pause_text() -> String:
	var lines: Array = ["— 暂 停 —", ""]
	var rows: Array = Settings.option_rows()
	for i in rows.size():
		lines.append("%s %-12s %s" % [
			"▶" if i == _opt_row else "  ", rows[i]["name"], rows[i]["value"],
		])
	lines.append("")
	lines.append("↑↓ 选项   ←→ 调整   Esc/Enter 继续   Q 返回标题")
	lines.append("")
	lines.append(_controls_text())
	return "\n".join(lines)


## 暂停菜单与标题页的操作说明用紧凑排版（3 行宽句）：这两处受高度约束，
## 暂停菜单本身已有 17 行设置项，多三行就会把整块文字顶出画面。
static func _controls_text() -> String:
	return InputSetup.controls_text(Settings.drive_relative, true)


## 车库左栏受宽度约束，用逐条短句的完整排版。
static func _garage_controls_text() -> String:
	return InputSetup.controls_text(Settings.drive_relative)


# ---------------- 每帧 ----------------

func _process(delta: float) -> void:
	# 暂停期间整棵树都停了，这里也停掉横幅、连击窗口与加固计时：
	# 否则玩家在暂停菜单里待 20 秒，回来时连击已经断了、加固也过期了。
	if state == "pause":
		return

	if _banner_t > 0.0:
		_banner_t -= delta
		if _banner_t <= 0.0:
			banner_text = ""

	hit_vignette = maxf(0.0, hit_vignette - delta * 1.6)

	# 烟幕寿命。暂停时这里不跑，所以暂停不会白白烧掉烟幕时间。
	if smoke_clouds.size() > 0:
		var clouds: Array = []
		for c in smoke_clouds:
			c["t"] = float(c["t"]) - delta
			if float(c["t"]) > 0.0:
				clouds.append(c)
		smoke_clouds = clouds

	_update_damage_marks(delta)

	# 车库转台：只在选车界面转，且只在真有展品时转
	if state == "select" and _preview_model != null and is_instance_valid(_preview_model):
		_preview_holder.rotation.y += delta * 0.5

	if _combo_t > 0.0:
		_combo_t -= delta
		if _combo_t <= 0.0:
			combo_mult = 1.0

	if _fortify_t > 0.0:
		_fortify_t -= delta
		if _fortify_t <= 0.0:
			arena.set_fortify(false)

	match state:
		"ready":
			state_timer -= delta
			if state_timer <= 0.0:
				state = "play"
				_refresh_mouse_mode()
				_banner("出击！", 1.2)
		"play":
			_update_play(delta)
		"clear":
			state_timer -= delta
			if state_timer <= 0.0:
				if stage >= MAX_STAGE:
					_win()
				else:
					stage += 1
					_start_stage()


func _update_play(delta: float) -> void:
	_cleanup()

	if player == null and lives > 0 and _respawn_t > 0.0:
		_respawn_t -= delta
		if _respawn_t <= 0.0:
			_spawn_player()

	_field_t -= delta
	if _field_t <= 0.0:
		# 没放下去（场上已满或这张图实在没有合适落点）就短间隔重试，
		# 否则白等一整个周期，玩家会觉得"这一关怎么没有补给"
		_field_t = randf_range(FIELD_DROP_MIN, FIELD_DROP_MAX) if _field_drop() else FIELD_DROP_RETRY

	_spawn_t -= delta
	if _spawn_t <= 0.0 and spawn_queue.size() > 0:
		if _count_active() < max_active:
			var t: int = spawn_queue[0]
			if _spawn_enemy(t):
				spawn_queue.remove_at(0)
				_spawn_t = 2.6 if t == 4 else 1.4
			else:
				_spawn_t = 0.6
		else:
			_spawn_t = 0.5

	_engine_t -= delta
	if _engine_t <= 0.0:
		_engine_t = 0.4
		_update_enemy_engines()

	if enemies_remaining() == 0 and not _stage_cleared:
		_stage_cleared = true
		state = "clear"
		state_timer = 3.4
		_refresh_mouse_mode()
		score += 1000 + stage * 250
		_banner("第 %d 关 肃清！ +%d" % [stage, 1000 + stage * 250], 3.4)
		Audio.play("power")


## 坦克互推：CharacterBody3D 之间不会相互推挤，两辆车一旦挤到一起就谁也动不了，
## 这就是"两个坦克叠在一起卡住"的根源。每物理帧做两件独立的事：
##
##   径向分离 —— 按重叠量沿连线把两车推开，只在真的重叠时才介入。
##   切向滑移 —— 双方都被顶住不动时，按接触时长积分出一个侧移速度让它们错开。
##
## 两者必须分开：正面对顶时推开多少、油门就顶回来多少，纯径向分离会原地僵死；
## 而物理安全边距又会把对顶的两车停在几乎零重叠处，所以侧滑的强度不能依赖
## 重叠深度，否则最需要它的工况恰好拿不到它（实测可顶死 1 秒以上）。
##
## 重叠量按"车身轴线段之间的最近距离"算，而不是两个中心的距离：
## 坦克长 4~6 米、宽 3 米，用圆去近似会漏掉丁字相撞与首尾相接——
## 那时两个中心离得很远，车体却实实在在压在一起，分离逻辑完全不介入，
## 两辆车就这么顶死在原地。这是"叠车卡住"剩下的那一半原因。
##
## 推完由 Tank.nudge 再过一遍网格约束，免得"解开叠车"反而把谁挤进了墙里。
func _physics_process(delta: float) -> void:
	if state != "play" and state != "ready" and state != "clear":
		_contact.clear()
		_motion.clear()
		return
	var list := all_tanks()
	var live: Dictionary = {}
	var now: Dictionary = {}
	for t in list:
		if is_instance_valid(t):
			now[t.get_instance_id()] = t.global_position

	for i in list.size():
		for j in range(i + 1, list.size()):
			var a: Tank = list[i]
			var b: Tank = list[j]
			if not is_instance_valid(a) or not is_instance_valid(b):
				continue
			var near := _closest_between(a, b)
			var d: Vector3 = near[1] - near[0]
			d.y = 0.0
			var sum := a.body_radius + b.body_radius
			# 留 2% 的间隙而不是压到贴合，车体之间就不会每帧抖一下
			var want := sum * 1.02
			var dist := d.length()
			if dist >= sum * JAM_K:
				continue

			var key := "%d:%d" % [a.get_instance_id(), b.get_instance_id()]
			var held: float = float(_contact.get(key, 0.0)) + delta
			live[key] = held

			var dir: Vector3
			if dist > 0.01:
				dir = d / dist
			else:
				# 完全重合（例如重生点撞上敌人）：随便挑一个方向把两辆车撕开
				dir = Vector3(randf() - 0.5, 0.0, randf() - 0.5).normalized()

			# 径向：只补真实重叠量，所以并排行驶不会被莫名推开
			var push := clampf(want - dist, 0.0, SEPARATE_STEP)
			# 切向：双方都被顶住不动，且已经顶了一会儿，才开始侧移
			var slide := 0.0
			if held > SLIP_DELAY and _is_jammed(a, b, now):
				slide = minf((held - SLIP_DELAY) * SLIP_ACCEL, SLIP_SPEED) * delta
			if push <= 0.0 and slide <= 0.0:
				continue
			var tangent := Vector3(-dir.z, 0.0, dir.x) * slide

			# 玩家只承担很小的一份修正：撞上去是把敌人顶开，而不是自己被弹回来。
			# 这既符合"是我在开车"的直觉，也保证玩家永远能从夹击里挤出来。
			var wa := b.body_radius / sum
			if a.is_player:
				wa = PLAYER_PUSH_SHARE
			elif b.is_player:
				wa = 1.0 - PLAYER_PUSH_SHARE
			var step_a := (-dir * push - tangent) * wa
			var step_b := (dir * push + tangent) * (1.0 - wa)
			var got_a: Vector3 = a.nudge(step_a)
			var got_b: Vector3 = b.nudge(step_b)
			# 一方被墙挡住挪不动：把它欠的那份转给另一方，总分离量因此不会打折，
			# 否则"一辆贴墙、一辆顶着它"这种最常见的夹角会永久卡住
			var lost_a := step_a.length() - got_a.length()
			if lost_a > 0.01:
				b.nudge(dir * lost_a)
			var lost_b := step_b.length() - got_b.length()
			if lost_b > 0.01:
				a.nudge(-dir * lost_b)
	_contact = live
	_motion = now


## 两辆车的车身轴线上最近的一对点（[a 上的点, b 上的点]）。
## 坦克不是圆而是长方体，所以"离得多近"只能按线段算：
## 侦察车一头撞在重型车腰上时，两个中心相距 4 米有余，车体却已经叠在一起。
static func _closest_between(a: Tank, b: Tank) -> PackedVector3Array:
	var sa: Array = a.spine()
	var sb: Array = b.spine()
	return Geometry3D.get_closest_points_between_segments(sa[0], sa[1], sb[0], sb[1])


## 两辆车这一帧是不是都几乎没动。只有同时卡住才需要侧滑介入——
## 单方被顶住（另一方正常绕过去）属于正常碰撞响应，插手反而会破坏手感。
func _is_jammed(a: Tank, b: Tank, now: Dictionary) -> bool:
	var ida := a.get_instance_id()
	var idb := b.get_instance_id()
	if not _motion.has(ida) or not _motion.has(idb):
		return false
	var ma: float = (Vector3(now[ida]) - Vector3(_motion[ida])).length()
	var mb: float = (Vector3(now[idb]) - Vector3(_motion[idb])).length()
	return ma < JAM_STEP and mb < JAM_STEP


## 敌车发动机声的调度：只打开离玩家最近的 3 台。
##
## 全开会让语音位被持续占据，而发动机声是最不紧急的一层——听不到身后那辆车
## 只是少一点预警，听不到炮声与命中提示却会让战斗读不出来。
func _update_enemy_engines() -> void:
	var p = player
	if p == null or not is_instance_valid(p) or not p.alive:
		for e in enemies:
			if is_instance_valid(e):
				e.set_engine_on(false)
		return
	var near: Array = []
	for e in enemies:
		if is_instance_valid(e) and e.alive:
			near.append([p.global_position.distance_to(e.global_position), e])
	near.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	for i in near.size():
		var e = near[i][1]
		if not is_instance_valid(e):
			continue
		e.set_engine_on(i < ENGINE_VOICES and float(near[i][0]) < ENGINE_RANGE)


func _update_damage_marks(delta: float) -> void:
	var i := damage_marks.size() - 1
	while i >= 0:
		damage_marks[i]["t"] -= delta
		if damage_marks[i]["t"] <= 0.0:
			damage_marks.remove_at(i)
		i -= 1


func _cleanup() -> void:
	var keep: Array = []
	for e in enemies:
		if is_instance_valid(e) and e.alive:
			keep.append(e)
	enemies = keep
	var kp: Array = []
	for p in powerups:
		if is_instance_valid(p):
			kp.append(p)
	powerups = kp


# ---------------- 界面流转 ----------------

func _enter_title() -> void:
	state = "title"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	_clear_battle()
	_show_menu("坦 克 大 战 3D", "TANK BATTLE 3D\n\n按 Enter 开始\n\n%s" % _controls_text())


func _enter_select() -> void:
	state = "select"
	_sel_row = 0
	# 默认停在存档里的车；没存过（首次游玩）就用名册的默认车
	var saved := TankRoster.ORDER.find(Settings.selected_tank)
	_sel_tank = saved if saved >= 0 else maxi(0, TankRoster.ORDER.find(TankRoster.DEFAULT_ID))
	_show_menu("选 择 战 车 与 关 卡", "")
	_refresh_select()


func _refresh_select() -> void:
	var marks: Array = []
	for i in SELECT_ROWS:
		marks.append("▶" if _sel_row == i else "  ")
	var tank: Dictionary = TankRoster.spec(TankRoster.ORDER[_sel_tank])
	var txt := "%s 战车   【%s】\n%s 难度   【%s】\n%s 关卡   【第 %d 关】\n%s 地形   【%s】\n\n↑↓ 选择   ←→ 切换\nEnter 出击   Esc 返回\n\n%s" % [
		marks[0], String(tank["full"]),
		marks[1], DIFF_NAMES[_sel_diff],
		marks[2], _sel_stage + 1,
		marks[3], _terrain_choice_name(),
		_garage_controls_text(),
	]
	if _select_l != null:
		_select_l.text = txt
	# 文本变了，字号要按新内容重新量一次（切驾驶方式会换掉第一行）
	_layout_garage()
	_show_tank(_sel_tank)


## 把转台与属性卡切到指定车型。切车是"换一个展品"，所以模型整个重建而不是改材质——
## 各车型的车体尺寸与部件都不同，改材质只能换色，换不了形。
func _show_tank(idx: int) -> void:
	var id: String = TankRoster.ORDER[clampi(idx, 0, TankRoster.ORDER.size() - 1)]
	var s: Dictionary = TankRoster.spec(id)
	if _card != null:
		_card.tank_id = id
		_card.queue_redraw()
	if _preview_model != null and is_instance_valid(_preview_model):
		_preview_model.queue_free()
	_preview_model = null
	var inst := Assets.instantiate(String(s["model"]))
	if inst == null:
		return          # 模型缺失（纯图元回退模式）时属性卡照常显示，只是没有展品
	Assets.paint(inst, s["hull_color"], s["accent_color"], 0.0)
	_preview_holder.add_child(inst)
	_preview_model = inst


func _terrain_choice_name() -> String:
	if _sel_terrain < 0:
		return "随机（每关轮换）"
	return Arena.TERRAINS[_sel_terrain]["name"]


## 当前实际生效的地形名，HUD 与开场横幅都用它
func terrain_name() -> String:
	return Arena.TERRAINS[terrain]["name"]


func _adjust_selection(d: int) -> void:
	match _sel_row:
		0:
			_sel_tank = posmod(_sel_tank + d, TankRoster.ORDER.size())
		1:
			_sel_diff = clampi(_sel_diff + d, 0, 2)
		2:
			_sel_stage = posmod(_sel_stage + d, MAX_STAGE)
		_:
			# 游标在 [-1, TERRAINS.size()-1] 上循环，-1 即"随机"
			var n: int = Arena.TERRAINS.size() + 1
			_sel_terrain = posmod(_sel_terrain + 1 + d, n) - 1
	Audio.play("switch")
	_refresh_select()


func _confirm_start() -> void:
	difficulty = _sel_diff
	score = 0
	stage = _sel_stage + 1
	lives = MAX_LIVES
	combo_mult = 1.0
	_kills = 0
	_stage_cleared = false
	get_tree().paused = false
	# 单局统计从零开始：结算页要报的是"这一局"，不是"到今天为止"
	Stats.begin_run()
	# 选车结果写进设置：下次开局直接停在上一次那台车上，不必每次重选
	Settings.selected_tank = TankRoster.ORDER[_sel_tank]
	Settings.save_cfg()
	# 地形轮换的起点每局随机：战场数量多于关卡数，固定从 0 开始会让后几张图永远见不到
	_terrain_offset = randi() % Arena.TERRAINS.size()
	hud.visible = true
	_hide_menu()
	_start_stage()


# ---------------- 关卡流程 ----------------

func _start_stage() -> void:
	# 选了具体地形就固定用它；选"随机"则从本局的随机起点开始按关号轮换，
	# 于是同一局不会重复战场，不同局之间又能走遍全部地形
	terrain = _sel_terrain if _sel_terrain >= 0 else (_terrain_offset + stage - 1) % Arena.TERRAINS.size()
	arena.generate(stage, terrain)
	# 混响跟着地形走：砖石回廊有尾音、雪原几乎没有。
	# 于是玩家闭着眼听一发炮也能判断出自己在哪张图上。
	Audio.set_space(String(Arena.TERRAINS[terrain]["layout"]))
	_clear_battle()
	_build_spawn_queue()
	_stage_cleared = false
	max_active = mini(2 + int(stage / 2.0), 6)
	_stage_damage_bonus = 0.0
	_fortify_t = 0.0
	_spawn_t = 2.0
	_respawn_t = 0.0
	_field_t = randf_range(FIELD_DROP_MIN, FIELD_DROP_MAX) * 0.45
	combo_mult = 1.0
	_spawn_player()
	state = "ready"
	state_timer = 2.6
	_refresh_mouse_mode()
	_banner("第 %d 关  ·  %s  ·  %s" % [stage, terrain_name(), DIFF_NAMES[difficulty]], 2.6)
	Audio.play("spawn")


func _build_spawn_queue() -> void:
	spawn_queue.clear()
	var n: int = mini(26, 9 + stage * 2)
	for i in n:
		var r := randf()
		var t := 1
		if stage >= 3 and r > 0.88:
			t = 3          # 火炮
		elif stage >= 2 and r > 0.68:
			t = 2          # 重型
		elif r > 0.42:
			t = 1          # 中型
		else:
			t = 0          # 侦察
		spawn_queue.append(t)
	if stage == 4 or stage == MAX_STAGE:
		spawn_queue.append(4)  # Boss 压轴


func _spawn_enemy(t: int) -> bool:
	var cells: Array = arena.spawn_cells().duplicate()
	cells.shuffle()
	for c in cells:
		var pos: Vector3 = Arena.cell_center(c.x, c.y)
		if not _area_clear(pos, 4.0):
			continue
		var e := Enemy.new()
		e.configure(t, stage, difficulty)
		e.setup(self, arena, pos)
		add_child(e)
		# 主节点是 ALWAYS（为了在暂停里还能读 Esc），所以动态生成的战场单位
		# 必须显式标成 PAUSABLE，否则它们会跟着主节点一起继续跑。
		e.process_mode = Node.PROCESS_MODE_PAUSABLE
		enemies.append(e)
		Fx.smoke_puff(fx_root, pos + Vector3(0, 0.45, 0), 0.8)
		Audio.play_3d("spawn", pos)
		if t == 4:
			_banner("⚠ 敌方指挥车出现！", 3.0)
			Audio.play("alert")
		return true
	return false


func _spawn_player() -> void:
	var pos := arena.player_spawn()
	player = Player.new()
	# 车型必须在 add_child() 之前写入：Player._ready() 按它装配碰撞体尺寸与全部属性
	player.tank_id = Settings.selected_tank if TankRoster.has(Settings.selected_tank) \
			else TankRoster.DEFAULT_ID
	player.rig = rig
	player.setup(self, arena, pos)
	add_child(player)
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	# 必须在 _ready() 之后，否则基础属性会覆盖难度调整
	player.apply_difficulty(difficulty)
	player.damage_mult = 1.0 + _stage_damage_bonus
	player.shield_t = 3.0
	rig.reset_to(player)
	# 玩家出生不再放烟：出生点就在相机正前方 2 米，一团 1.2 米半径的烟
	# 会直接糊住半个屏幕，开局三秒什么都看不清。护盾特效已经足够提示"车已就位"。
	Audio.play("spawn")


func _area_clear(pos: Vector3, r: float) -> bool:
	for t in all_tanks():
		if is_instance_valid(t) and t.global_position.distance_to(pos) < r * 2.0:
			return false
	return true


func _clear_battle() -> void:
	for e in enemies:
		if is_instance_valid(e):
			e.queue_free()
	enemies.clear()
	for p in powerups:
		if is_instance_valid(p):
			p.queue_free()
	powerups.clear()
	for c in get_children():
		if c is Shell:
			c.queue_free()
	if player != null and is_instance_valid(player):
		player.queue_free()
	player = null
	damage_marks.clear()
	smoke_clouds.clear()


func _count_active() -> int:
	var c := 0
	for e in enemies:
		if is_instance_valid(e) and e.alive:
			c += 1
	return c


func enemies_remaining() -> int:
	return _count_active() + spawn_queue.size()


func all_tanks() -> Array:
	var out: Array = []
	if player != null and is_instance_valid(player) and player.alive:
		out.append(player)
	for e in enemies:
		if is_instance_valid(e) and e.alive:
			out.append(e)
	return out


# ---------------- 供其它脚本调用的接口 ----------------

func spawn_shell(from: Tank, origin: Vector3, dir: Vector3, kind: int) -> void:
	var s := Shell.new()
	s.launch(self, arena, from, origin, dir, kind)
	add_child(s)
	s.process_mode = Node.PROCESS_MODE_PAUSABLE


func on_tank_destroyed(t: Tank) -> void:
	if t.is_player:
		_on_player_death()
		return

	_kills += 1
	Stats.add_kill()
	_combo_t = COMBO_WINDOW
	combo_mult = minf(COMBO_MAX, combo_mult + 0.5)
	Stats.note_combo(combo_mult)
	var gain := int(t.points * combo_mult)
	score += gain
	rig.add_trauma(0.25)
	Fx.damage_number(fx_root, t.global_position, "+%d" % gain, Color(1.0, 0.85, 0.3))
	if combo_mult > 1.4:
		_banner("连击 x%.1f" % combo_mult, 1.0)
	_maybe_drop(t.global_position, t.etype == 4)


func on_base_destroyed() -> void:
	if state == "over" or state == "win":
		return
	_banner("基地被摧毁！", 2.0)
	_game_over()


func on_player_hit(from_pos: Vector3, dmg: int) -> void:
	damage_marks.append({"pos": from_pos, "t": 1.4})
	rig.add_trauma(clampf(dmg / 160.0, 0.15, 0.6))
	hit_vignette = minf(1.0, hit_vignette + clampf(dmg / 200.0, 0.25, 0.8))
	combo_mult = 1.0
	_combo_t = 0.0


## 玩家自己的车身挡下了一发（跳弹 / 护盾）。与"挨打"相反，这是好消息，
## 但也必须给反馈：斜摆车身之所以值得练，唯一的原因就是玩家能看见它起作用。
## 原来 take_hit() 在这两种情况下直接 return，没有方向环、没有震屏、没有提示——
## 玩家只会以为"对方打偏了"。
func on_player_blocked(what: String, blocked := 0) -> void:
	var p = player
	if p == null or not is_instance_valid(p):
		return
	# 只有轻微震屏：这是"被打了一下但没穿"，不是受伤
	rig.add_trauma(0.12)
	Stats.add_blocked(blocked)
	if hud != null and hud.visible:
		hud.show_result("%s · 装甲挡住了" % what, Color(0.70, 0.85, 1.0))
	Audio.play("block", -2.0)


## 玩家炮弹产生结果时的统一反馈入口。
##
## result 是四种战斗结果之一：
##   "pen"    击穿   —— 清脆金属声 + 低频重击
##   "bounce" 跳弹   —— 上扬的"叮"
##   "kill"   击毁   —— 爆裂 + 短号角
##   "block"  被挡下 —— 沉闷钝响
## 原来四种情况共用一声 "steel" 加一声 "叮"，"打穿了"和"被弹开了"听起来
## 完全一样——这是街机节奏下最不该省的信息。
func on_shell_feedback(text: String, pos: Vector3, from_player: bool,
		result := "pen", amount := 0, etype := -1) -> void:
	if not from_player:
		return
	var col := Color(1.0, 0.9, 0.4)
	var ribbon := text
	match result:
		"bounce":
			col = Color(0.70, 0.80, 1.0)
			ribbon = "跳弹"
			Stats.add_bounce()
		"kill":
			col = Color(1.0, 0.55, 0.15)
			ribbon = "击毁！"
			Stats.add_damage(amount)
		"block":
			col = Color(0.70, 0.82, 1.0)
			ribbon = "装甲挡住"
		_:
			col = Color(1.0, 0.86, 0.30)
			ribbon = "击穿 " + text
			Stats.add_damage(amount)

	Fx.damage_number(fx_root, pos, text, col)
	if hud != null and hud.visible:
		hud.show_result(ribbon, col)
		if result == "kill":
			# 击杀栏记录"谁被打掉"，击毁那一瞬间的画面很乱，
			# 没有这一行玩家事后根本想不起来刚才那一发打的是哪辆车。
			hud.feed("击毁  %s" % _enemy_type_name(etype))
	Audio.play(result, -3.0)
	if player != null and is_instance_valid(player) and player.alive:
		# 跳弹也算"打到了"，但标记用冷色，与实打实的伤害区分开
		player.hit_flash = 0.3
		player.hit_ricochet = result == "bounce"


static func _enemy_type_name(t: int) -> String:
	match t:
		0: return "侦察车"
		2: return "重型坦克"
		3: return "自行火炮"
		4: return "指挥车"
		_: return "中型坦克"


func deploy_smoke(pos: Vector3, dur: float) -> void:
	Fx.smoke_screen(fx_root, pos, dur)
	smoke_clouds.append({"pos": pos, "r": SMOKE_RADIUS, "t": dur})
	if smoke_clouds.size() > SMOKE_CLOUDS_MAX:
		smoke_clouds.pop_front()


## 这个点是否落在任意一团有效烟幕里（只看水平距离）。
## 敌人用它对玩家做视线判定，HUD 也可以用它显示"已隐蔽"。
func smoke_at(pos: Vector3) -> bool:
	for c in smoke_clouds:
		var p: Vector3 = c["pos"]
		var dx := p.x - pos.x
		var dz := p.z - pos.z
		var r: float = c["r"]
		if dx * dx + dz * dz <= r * r:
			return true
	return false


func apply_powerup(ptype: int) -> void:
	var d := PowerUp.info(ptype)
	Audio.play("pickup")
	score += 300
	if player == null or not is_instance_valid(player) or not player.alive:
		return

	match ptype:
		PowerUp.Type.REPAIR:
			player.hp = mini(player.max_hp, player.hp + int(player.max_hp * 0.45))
		PowerUp.Type.ARMOR:
			player.armor_buff_t = 20.0
		PowerUp.Type.RAPID:
			player.rapid_buff_t = 20.0
		PowerUp.Type.SHIELD:
			player.shield_t = 8.0
		PowerUp.Type.AIRSTRIKE:
			_airstrike()
		PowerUp.Type.FORTIFY:
			arena.set_fortify(true)
			_fortify_t = 25.0
		PowerUp.Type.FIREPOWER:
			_stage_damage_bonus += 0.25
			player.damage_mult = 1.0 + _stage_damage_bonus
		PowerUp.Type.MULTISHOT:
			player.multi_t = 22.0
		PowerUp.Type.OVERDRIVE:
			player.overdrive_t = 20.0
	_banner("%s — %s" % [d["name"], d["desc"]], 2.0)
	Audio.play("power")


func _airstrike() -> void:
	Audio.play("alert")
	rig.add_trauma(0.9)
	for e in enemies.duplicate():
		if not is_instance_valid(e) or not e.alive:
			continue
		Fx.explosion(fx_root, e.global_position + Vector3(0, 1.0, 0), 2.2)
		e.take_hit(int(e.max_hp * 0.7) + 60, e.global_position + Vector3(0, 30, 0), Shell.Kind.HE)


func _maybe_drop(pos: Vector3, guaranteed: bool) -> void:
	if not guaranteed and randf() > DROP_CHANCE:
		return
	_spawn_powerup(pos, _roll_powerup(), false)


## 定时空投：在远离基地与玩家当前位置的空格里放一个增益箱。
## 掉落池偏向"直接提升战斗力"的那几种，于是去抢补给永远是划算的决策。
## 返回是否真的放下了一个。
func _field_drop() -> bool:
	if arena == null or powerups.size() >= FIELD_DROP_MAX_ON_GROUND:
		return false
	var avoid: Array = [arena.base_position()]
	if player != null and is_instance_valid(player) and player.alive:
		avoid.append(player.global_position)
	# 已经落地的补给彼此拉开 20 米，免得几个箱子挤在同一个角落
	var others: Array = []
	for pu in powerups:
		if is_instance_valid(pu):
			others.append(pu.global_position)
	var pos := arena.random_open_cell(avoid, 15.0, others, 20.0)
	if pos == Vector3.INF:
		return false
	var p := _spawn_powerup(pos, _roll_field_powerup(), true)
	Fx.smoke_puff(fx_root, pos + Vector3(0, 1.2, 0), 1.4)
	Audio.play("alert")
	_banner("补给空投：%s（雷达已标记）" % PowerUp.info(p.ptype)["name"], 2.4)
	return true


func _spawn_powerup(pos: Vector3, ptype: int, from_field: bool) -> PowerUp:
	var p := PowerUp.new()
	p.game = self
	p.ptype = ptype
	p.from_field = from_field
	p.position = pos
	add_child(p)
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	powerups.append(p)
	return p


func _roll_powerup() -> int:
	var pool: Array = [
		PowerUp.Type.REPAIR, PowerUp.Type.REPAIR,
		PowerUp.Type.ARMOR, PowerUp.Type.RAPID, PowerUp.Type.RAPID,
		PowerUp.Type.SHIELD, PowerUp.Type.FIREPOWER,
		PowerUp.Type.MULTISHOT, PowerUp.Type.OVERDRIVE,
		PowerUp.Type.AIRSTRIKE, PowerUp.Type.FORTIFY,
	]
	# 基地告急时提高加固与维修的权重
	if arena.base_hp < arena.base_max_hp * 0.5:
		pool.append(PowerUp.Type.FORTIFY)
		pool.append(PowerUp.Type.REPAIR)
	return pool[randi() % pool.size()]


## 场地补给的掉落池：以战斗力增益为主，残血时才掺进维修包
func _roll_field_powerup() -> int:
	var pool: Array = [
		PowerUp.Type.FIREPOWER, PowerUp.Type.FIREPOWER,
		PowerUp.Type.RAPID, PowerUp.Type.RAPID,
		PowerUp.Type.MULTISHOT, PowerUp.Type.MULTISHOT,
		PowerUp.Type.OVERDRIVE, PowerUp.Type.OVERDRIVE,
		PowerUp.Type.ARMOR, PowerUp.Type.SHIELD,
	]
	if player != null and is_instance_valid(player) and player.hp < player.max_hp * 0.6:
		pool.append(PowerUp.Type.REPAIR)
		pool.append(PowerUp.Type.REPAIR)
	if arena.base_hp < arena.base_max_hp * 0.6:
		pool.append(PowerUp.Type.FORTIFY)
	return pool[randi() % pool.size()]


# ---------------- 胜负 ----------------

func _on_player_death() -> void:
	player = null
	rig.target = null
	lives -= 1
	combo_mult = 1.0
	rig.add_trauma(1.0)
	if lives > 0:
		_respawn_t = 2.5
		_banner("战车被击毁，剩余 %d 辆" % lives, 2.0)
	else:
		_game_over()


func _game_over() -> void:
	state = "over"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	var won := false
	if score > high_score:
		high_score = score
		_save_high_score()
	Stats.end_run(_player_tank_id(), difficulty, score, won)
	_show_menu("战 败", _result_text(won))
	Audio.play("gameover")


func _win() -> void:
	state = "win"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	score += lives * 3000
	if score > high_score:
		high_score = score
		_save_high_score()
	Stats.end_run(_player_tank_id(), difficulty, score, true)
	_show_menu("全 线 胜 利", _result_text(true))
	Audio.play("victory")


## 当前使用的车型 id。玩家可能在关卡之间死掉（player == null），
## 所以不能从 player 上读，只能从设置里读——那才是这一局真正出击的车。
func _player_tank_id() -> String:
	return Settings.selected_tank if TankRoster.has(Settings.selected_tank) \
			else TankRoster.DEFAULT_ID


## 详细结算页。
##
## 原来只有"关卡 / 击毁 / 得分 / 最高分"四个数，玩家打完一局不知道自己
## 是怎么赢的、也不知道下一局该改什么。这里补上四个能指导决策的量：
## 伤害输出（火力是否用满）、挡下伤害（装甲和斜摆是否生效）、命中率
## （瞄得准不准）、跳弹次数（有没有在浪费炮弹），最后按阈值发勋章。
func _result_text(won: bool) -> String:
	var tank: Dictionary = TankRoster.spec(_player_tank_id())
	var acc := Stats.accuracy()
	var acc_txt := "—" if acc < 0.0 else "%d%%  (%d/%d)" % [
		int(round(acc * 100.0)), Stats.run_hits, Stats.run_shots]
	var lines: Array = []
	lines.append("%s难度   战车【%s】" % [DIFF_NAMES[difficulty], String(tank["full"])])
	lines.append("抵达第 %d 关       得分 %07d       最高 %07d" % [stage, score, high_score])
	lines.append("")
	lines.append("击毁        %d 辆" % Stats.run_kills)
	lines.append("伤害输出    %d" % Stats.run_damage)
	lines.append("挡下伤害    %d" % Stats.run_blocked)
	lines.append("命中率      %s" % acc_txt)
	lines.append("跳弹        %d 次" % Stats.run_bounces)
	lines.append("最高连击    x%.1f" % Stats.run_combo)
	lines.append("")
	var medals := _medals(won)
	lines.append("勋  章")
	lines.append("  " + ("   ".join(medals) if medals.size() > 0 else "—"))
	lines.append("")
	lines.append("生涯累计   击毁 %d   最高分 %07d   通关 %d 次" % [
		Stats.kills, Stats.best_score, Stats.wins])
	lines.append("")
	lines.append("R 重新出击   Esc 返回标题" if not won else "Enter 返回标题")
	return "\n".join(lines)


## 勋章阈值按"一局打满八关"的规模取：
## 击毁 20 辆≈ 整整两关的敌人，命中率 70% 要求瞄得准而不是靠扫射，
## 挡下 1200 伤害≈ 铁砧正面吃掉四发重型炮，连击 x3.0 需要连续 5 次击杀不挨打。
func _medals(won: bool) -> Array:
	var out: Array = []
	if won:
		out.append("★ 全线胜利")
	if Stats.run_kills >= 20:
		out.append("★ 钢铁洪流")
	var acc := Stats.accuracy()
	if acc >= 0.70 and Stats.run_hits >= 10:
		out.append("★ 神射手")
	if Stats.run_blocked >= 1200:
		out.append("★ 铁壁")
	if Stats.run_combo >= 3.0:
		out.append("★ 连击大师")
	return out


func _banner(text: String, dur := 2.0) -> void:
	banner_text = text
	_banner_t = dur


# ---------------- 菜单 UI ----------------

func _build_menu() -> void:
	_menu = CanvasLayer.new()
	_menu.layer = 8
	add_child(_menu)

	_bg = TextureRect.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_bg)

	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0, 0, 0, 0.45)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(scrim)

	_title_l = Label.new()
	_title_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_title_l.add_theme_font_size_override("font_size", 62)
	_title_l.add_theme_color_override("font_color", Color(1.0, 0.88, 0.32))
	_title_l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_title_l.add_theme_constant_override("outline_size", 12)
	_title_l.offset_top = 90
	_title_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_title_l)

	_menu_l = Label.new()
	_menu_l.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_menu_l.add_theme_font_size_override("font_size", 26)
	_menu_l.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	_menu_l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_menu_l.add_theme_constant_override("outline_size", 8)
	_menu_l.offset_top = 60
	_menu_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_menu_l)

	_build_garage()


## 选车界面（车库）：左列选项、右侧一台模型转台与属性卡。
##
## 转台是一个独立的 SubViewport：它有自己的 World3D，于是车模既不受战场光照/雾
## 影响，也不会被主相机拍到。更新模式默认关闭，只有停在选车界面时才打开——
## 一个后台一直在渲染的 3D 视口会白吃掉几个百分点的帧率，而它只在菜单里才有人看。
func _build_garage() -> void:
	_select_l = Label.new()
	_select_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_select_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 必须开自动换行：某一行万一超出栏宽，不做换行就会横向溢出到右栏，
	# 和属性卡的文字叠在一起（两张文字互相穿插，两边都读不出来）。
	# 但换行只是兜底、不是排版手段——它在**任意字符**处折，中文没有空格，
	# 断在词中间就会出现"第一人 / 称"这种断口。真正的约束是每行都排得下，
	# 由字号 20 与 InputSetup.controls_text() 的行长共同保证。
	_select_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_select_l.add_theme_font_size_override("font_size", 20)
	_select_l.add_theme_color_override("font_color", Color(0.93, 0.96, 1.0))
	_select_l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_select_l.add_theme_constant_override("outline_size", 7)
	_select_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_select_l)

	_preview_vp = SubViewport.new()
	_preview_vp.size = Vector2i(1200, 700)
	_preview_vp.transparent_bg = true
	_preview_vp.own_world_3d = true
	# 2K/4K 屏上 760x440 会被放大到发虚；1200x700 在同样的显示尺寸下
	# 仍有足够像素承载迷彩与焊缝，MSAA 再把炮管这类细长边缘的锯齿压住。
	_preview_vp.msaa_3d = Viewport.MSAA_4X
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_menu.add_child(_preview_vp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0, 0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.68, 0.80)
	e.ambient_light_energy = 0.72
	# 转台原来只有纯透明背景：金属件没有任何可反射的东西，只能靠高光，
	# 于是整台车看起来像塑料。给一个程序化天空当反射源，车顶与侧裙
	# 才会出现天空的冷色反光，金属与涂装的分界也才读得出来。
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.26, 0.38)
	sky_mat.sky_horizon_color = Color(0.42, 0.40, 0.36)
	sky_mat.ground_bottom_color = Color(0.05, 0.05, 0.055)
	sky_mat.ground_horizon_color = Color(0.18, 0.17, 0.16)
	sky_mat.sun_angle_max = 8.0
	sky_mat.sun_curve = 0.12
	sky.sky_material = sky_mat
	e.sky = sky
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# 转台上的车是"展品"而不是"战场上的目标"，所以给它一点辉光让金属边缘亮起来
	e.glow_enabled = true
	e.glow_intensity = 0.5
	# ACES 比 Filmic 更能压住高光，金属边缘不会一有反射就糊成白边
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 0.95
	env.environment = e
	_preview_vp.add_child(env)

	_preview_holder = Node3D.new()
	_preview_vp.add_child(_preview_holder)

	# 接影地面：没有地面，主光开不开阴影都看不出来；有了它，车底才"落"在展台上。
	var floor_mi := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 4.2
	disc.bottom_radius = 4.4
	disc.height = 0.12
	disc.radial_segments = 48
	floor_mi.mesh = disc
	floor_mi.position = Vector3(0, -0.06, 0)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.145, 0.150, 0.160)
	floor_mat.roughness = 0.42
	floor_mat.metallic = 0.20
	floor_mi.material_override = floor_mat
	_preview_vp.add_child(floor_mi)

	# 三点布光：主光压出体积、辅光提亮暗面、轮廓光把车从深色背景里勾出来。
	# 主光 1.05 而不是 1.5：转台背景是一块亮天空，金属件会同时收到直射光与
	# 天空反射，1.5 时车顶、舱盖、侧裙一起冲到 0.8 sRGB 以上，细节全被漂白。
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, 34, 0)
	key.light_energy = 1.30
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 14.0
	_preview_vp.add_child(key)

	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-22, -140, 0)
	rim.light_energy = 0.80
	rim.light_color = Color(0.72, 0.82, 1.0)
	_preview_vp.add_child(rim)

	# 正面补光：主光在右后方，车头正面原来只剩环境光，炮盾与首上装甲
	# 糊成一整块深绿。0.28 的暖色补光只抬暗面，不改变主光的方向感。
	var front := DirectionalLight3D.new()
	front.rotation_degrees = Vector3(-14, 196, 0)
	front.light_energy = 0.28
	front.light_color = Color(1.0, 0.92, 0.80)
	_preview_vp.add_child(front)

	var cam := Camera3D.new()
	cam.position = Vector3(4.25, 2.65, 5.35)
	cam.fov = 36.0
	# look_at() 读的是全局变换，节点必须在树里才能算——所以先 add_child 再瞄。
	# 顺序反了只会在启动时打一条 "Node not inside tree"，转台的机位也不会被设置。
	_preview_vp.add_child(cam)
	cam.look_at(Vector3(0, 1.02, 0), Vector3.UP)

	_preview_tex = TextureRect.new()
	_preview_tex.texture = _preview_vp.get_texture()
	_preview_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_preview_tex)

	_card = TankCard.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_card)


func _show_menu(title: String, body: String) -> void:
	_menu.visible = true
	_bg.modulate = Color(1, 1, 1, 1)
	var path := "res://assets/bg/select.jpg" if state == "select" else "res://assets/bg/title.jpg"
	if state == "pause":
		_bg.texture = null
	elif ResourceLoader.exists(path):
		_bg.texture = load(path)
	_title_l.text = title

	# 选车界面走另一套排版：居中那一坨文字排不下转台与属性卡，两者互斥显示
	var garage: bool = state == "select"
	_menu_l.visible = not garage
	_select_l.visible = garage
	_preview_tex.visible = garage
	_card.visible = garage
	_preview_vp.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if garage else SubViewport.UPDATE_DISABLED)
	if garage:
		_layout_garage()
	else:
		if body != "":
			_menu_l.text = body
		_fit_menu_text()


## 居中正文的字号按可用高度反算。
##
## 这块文字是"设置项 + 操作说明"一整块，行数会随设置项增删而变化，而它是
## VERTICAL_ALIGNMENT_CENTER 的全屏 Label：排不下时上下两端同时被裁掉，
## 玩家看不到最下面的设置项，也没有任何报错。1080p 设计空间下 26px 刚好够，
## 但窗口模式的最小预设 1280x720 视口只有 1029 高，多三行操作说明就会顶出去。
## 所以排不下就缩字号，排得下仍用设计值。
func _fit_menu_text() -> void:
	const DESIGN_FS := 26
	# 界面缩放 200% 时可见区域只剩约 456 px，25 行要压到 10px 才排得下。
	# 这一档在加自适应之前是硬溢出（26px × 25 行 ≈ 900 px），字号虽小，
	# 但"能看到全部设置项"比"字大"更重要。
	const MIN_FS := 10
	# 用视口的可见矩形，而不是 Label 自己的 size：size 由上一次布局算出，
	# 刚改完界面缩放（content_scale_factor）时它还是**旧值**，
	# 于是按它算出的"放得下"在新缩放下并不成立。
	var avail: float = get_viewport().get_visible_rect().size.y \
			- _menu_l.offset_top - 24.0
	var lines := _menu_l.text.split("\n").size()
	var f := ThemeDB.fallback_font
	# 解析式算高度，而不是问 Label 要 get_minimum_size()：改了字号覆盖之后
	# 最小尺寸要等下一次布局才刷新，在循环里读到的是**上一个**字号的值，
	# 于是循环会在"其实还排不下"的位置提前收敛。
	var fs := DESIGN_FS
	var spacing := int(round(fs * 0.15))
	while fs > MIN_FS:
		spacing = int(round(fs * 0.15))
		if (f.get_height(fs) + spacing) * lines <= avail:
			break
		fs -= 1
	# 行距收到 0 还排不下就继续缩字号，直到最小值
	while fs > MIN_FS and (f.get_height(fs) + spacing) * lines > avail:
		spacing = 0
		fs -= 1
	_menu_l.add_theme_font_size_override("font_size", fs)
	_menu_l.add_theme_constant_override("line_spacing", spacing)


func _hide_menu() -> void:
	_menu.visible = false
	# 关掉转台渲染：它在菜单不可见时应彻底不工作
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


## 车库的两栏布局。位置按当前可见区域的尺寸算，而不是写死 1920x1080——
## 项目用 stretch/aspect=expand，超宽屏下可见区域比设计空间更宽，
## 写死的坐标会把右栏推到屏幕外。
func _layout_garage() -> void:
	var vp := get_viewport().get_visible_rect().size
	var left_w := minf(560.0, vp.x * 0.34)
	var right_x := maxf(left_w + 40.0, vp.x * 0.45)
	var right_w := minf(700.0, vp.x - right_x - 60.0)

	_select_l.position = Vector2(60.0, 0.0)
	_select_l.offset_top = 0.0
	_select_l.offset_bottom = vp.y
	_select_l.size = Vector2(left_w, vp.y)
	_select_l.add_theme_constant_override("line_spacing", 8)

	_preview_tex.position = Vector2(right_x, vp.y * 0.18)
	_preview_tex.size = Vector2(right_w, right_w * 0.52)

	_card.position = Vector2(right_x, _preview_tex.position.y + _preview_tex.size.y + 6.0)
	_card.size = Vector2(right_w, vp.y - _card.position.y - 40.0)

	_fit_garage_text(left_w)


## 左栏字号按栏宽反算，从设计值 20 一路收到 12。
##
## 栏宽不是常数：界面缩放（`content_scale_factor`）把设计空间放大后，可见区域
## 反而变窄（缩放 200% 时左栏只有约 326 px）。写死一个字号必然在某档缩放下折行，
## 而 AUTOWRAP 折在词中间就读不通了。所以这里量到"最宽的一行刚好排得下"为止。
func _fit_garage_text(width: float) -> void:
	const DESIGN_FS := 20
	const MIN_FS := 12
	var f := ThemeDB.fallback_font
	var widest := 0.0
	for rel in [true, false]:
		for line in InputSetup.controls_text(rel).split("\n"):
			widest = maxf(widest, f.get_string_size(line,
					HORIZONTAL_ALIGNMENT_LEFT, -1, DESIGN_FS).x)
	var fs := DESIGN_FS
	while fs > MIN_FS and widest * (float(fs) / DESIGN_FS) > width - 8.0:
		fs -= 1
	_select_l.add_theme_font_size_override("font_size", fs)


# ---------------- 存档 ----------------

func _load_high_score() -> void:
	var path := "user://highscore3d.txt"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			high_score = f.get_32()


func _save_high_score() -> void:
	var f := FileAccess.open("user://highscore3d.txt", FileAccess.WRITE)
	if f != null:
		f.store_32(high_score)
