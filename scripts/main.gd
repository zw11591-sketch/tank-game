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
## 合作模式：场上全部真人车（房主侧包含所有客户端，客户端侧包含本地与远端队友）。
## `player` 始终是本机那名玩家的别名，HUD / 相机 / 输入都继续读它。
var players: Array = []
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
var _scrim: ColorRect
var _title_l: Label
var _menu_l: Label
## 标题页专用：徽标 + 两个主按钮 + 底部分组操作条。它只属于 state == "title"，
## 暂停 / 结算 / 选车仍走下面那套居中文字菜单。
var _title_ui: Control
var _title_col: VBoxContainer
var _title_bar: PanelContainer
var _title_drive_l: Label
var _title_foot: Label
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

## ---- 联机 ----
## 本关地图种子。单机沿用 Arena 的固定种子；联机时由房主下发，
## 客户端用同一个种子重建同一张图，于是不必同步几何。
var _stage_seed := 0
var _lobby_layer: CanvasLayer
var _lobby: NetLobby
## 客户端从快照读到的"剩余敌军"。客户端不跑出怪队列，HUD 只能信房主。
var net_remaining := -1
## 客户端上最近一次应用的基地加固状态，用来避免每帧重复重建围墙。
var net_fortify := false
## 客户端本发炮弹是否已经记过命中（uid -> true）。一发多弹 / HE 溅射可能
## 收到多条反馈，命中率只该加一次。
var _net_hit_claimed: Dictionary = {}
## 房主侧：等待重生的玩家 [{pid, t}]。
var _net_respawn: Array = []
## 房主侧：每个客户端最近一次上报的位置与时刻，用来做位移校验。
var _client_last: Dictionary = {}
## 位移校验累计拉回次数。联机排查时看一眼就知道"是网络抖还是有人在瞬移"。
var _net_pullbacks := 0
## 收到的客户端状态包数量。联机探针用它区分"客户端没发"与"房主没应用"。
var _net_client_updates := 0

const DIFF_NAMES := ["简单", "普通", "困难"]
const SELECT_ROWS := 4

## 车库标题的字号与顶边距。1080p 设计空间（界面缩放 100%）沿用 62px / y=90，
## 与改造前完全一致；界面缩放 200% 时可见区只剩 960x540，62px 的标题要占掉
## y 90~174，而左栏 15 行文字垂直居中后从 y 45 起排、最宽到 x 350，
## 两者在 x 263~350 直接叠在一起（标题压住"关卡 / 地形"两行）。
## 所以矮屏改用 40px 并压到顶部，把标题带下面整块让给左栏与右栏。
const GARAGE_TITLE_FS := 40
const GARAGE_TITLE_TOP := 24.0
const GARAGE_TITLE_FS_TALL := 62
const GARAGE_TITLE_TOP_TALL := 90.0
## 分档阈值：左栏 15 行按设计字号要 540 px，加上 62px 标题带（84）与呼吸量
## 至少要 700 px。低于 800 就说明这一档缩放已经排不开，改走紧凑排版。
const GARAGE_TALL_H := 800.0
const GARAGE_TITLE_GAP := 16.0


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
	# 标题页 / 车库的坐标都按"当前可见区域"算，窗口缩放与界面缩放改的是同一个量。
	# 不接这个信号，从 100% 切到 200% 后按钮与操作条仍停在旧尺寸上，右半截会掉出屏幕。
	get_viewport().size_changed.connect(_relayout_menu)
	# 联机：注册主协调器、监听房主事件、建好局域网大厅。大厅本身只是一个
	# 覆盖层，单机玩家永远不会看到它。
	Net.setup_game(self)
	Net.match_started.connect(_on_net_match_started)
	Net.match_ended.connect(_on_net_match_ended)
	Net.session_ended.connect(_on_net_session_ended)
	arena.cell_destroyed.connect(_on_arena_cell_destroyed)
	_build_lobby()
	_enter_title()
	# 启动参数最后处理：--host / --join 会在标题建好之后再进大厅，
	# 否则随后的 _enter_title() 会把刚建好的房间页关掉。
	_parse_cmdline()


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
			if event is InputEventKey and event.pressed and not event.echo \
					and (event as InputEventKey).keycode == KEY_L:
				_enter_lobby()
			elif event.is_action_pressed("ui_accept"):
				_enter_select()
		"lobby":
			if event.is_action_pressed("ui_cancel"):
				_leave_lobby_to_title()
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
				_leave_lobby_to_title()
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
				# 联机时不提供"再来一局"：那会在还连着房间的情况下起一局单机，
				# 名册、命数与种子都不同步。回标题即退出房间，重开由房主重新建房。
				if not Net.is_multiplayer():
					_confirm_start()
			elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_accept"):
				_leave_lobby_to_title()


## 鼠标捕获只跟状态挂钩：战斗相关状态一律捕获，菜单与结算一律放开。
## 这样倒计时阶段也能先把炮塔转到想要的方向。
func _refresh_mouse_mode() -> void:
	var want: bool = state == "ready" or state == "play" or state == "clear"
	var mode := Input.MOUSE_MODE_CAPTURED if want else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != mode:
		Input.mouse_mode = mode


func _set_pause(on: bool) -> void:
	if on:
		if state == "pause":
			return
		_state_before_pause = state
		state = "pause"
		# 联机时暂停是本地覆盖层：房主那边还在跑 AI 与炮弹，客户端也不能
		# 把整棵树停掉（停了就收不到快照了）。单机才真的冻结战场。
		if not Net.is_multiplayer():
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
	# 联机时这里只是本地覆盖层：战场仍在继续，说清楚免得玩家以为队友也停了。
	if Net.is_multiplayer():
		lines.append("联机中：仅自己打开菜单，战场仍在继续")
		lines.append("")
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
			# 客户端的倒计时与状态切换由房主快照驱动，本地再减一次会走得更快。
			if not Net.is_client():
				state_timer -= delta
				if state_timer <= 0.0:
					state = "play"
					_refresh_mouse_mode()
					_banner("出击！", 1.2)
		"play":
			_update_play(delta)
		"clear":
			if not Net.is_client():
				state_timer -= delta
				if state_timer <= 0.0:
					if stage >= MAX_STAGE:
						_win()
					else:
						stage += 1
						_start_stage()


func _update_play(delta: float) -> void:
	_cleanup()

	_engine_t -= delta
	if _engine_t <= 0.0:
		_engine_t = 0.4
		_update_enemy_engines()

	# 客户端只做表现：出怪、掉落、计分、关卡推进全部由房主负责。
	if Net.is_client():
		return

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

	# 房主侧：队友的重生计时。每个 peer 的命数独立，不能共用单机的 _respawn_t。
	var still: Array = []
	for item in _net_respawn:
		item["t"] = float(item["t"]) - delta
		if float(item["t"]) <= 0.0:
			_respawn_net_player(int(item["pid"]))
		else:
			still.append(item)
	_net_respawn = still

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
	# 互推只由房主/单机做。客户端上远端车由快照插值，本地车由玩家自己开；
	# 在这一层再推一次会和房主解算的方向打架，表现为两台车被看不见的手拽回去。
	if Net.is_client():
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
	# 车会被击毁后 queue_free，数组里必须清掉失效引用，
	# 否则 all_tanks() / human_rids() 每帧都要过滤一遍死对象。
	var kt: Array = []
	for t in players:
		if is_instance_valid(t) and t.alive:
			kt.append(t)
	players = kt
	if player != null and not is_instance_valid(player):
		player = null


# ---------------- 界面流转 ----------------

func _enter_title() -> void:
	state = "title"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	if _lobby != null:
		_lobby.close()
	_clear_battle()
	# 标题页的内容由 _title_ui 自己搭（徽标 / 主按钮 / 底部操作条），
	# 居中 Label 那一套只留给暂停与结算页，所以这里不再传说明文字。
	_show_menu("", "")


## 公开给大厅 / 菜单调用：先离开联机会话，再回标题。
func enter_title() -> void:
	_leave_lobby_to_title()


func _leave_lobby_to_title() -> void:
	if Net.is_multiplayer():
		Net.leave()
	if _lobby != null:
		_lobby.close()
	_enter_title()


func _enter_lobby() -> void:
	state = "lobby"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	_hide_menu()
	if _lobby != null:
		_lobby.open()


func _build_lobby() -> void:
	_lobby_layer = CanvasLayer.new()
	_lobby_layer.layer = 9
	add_child(_lobby_layer)
	_lobby = NetLobby.new()
	_lobby.game = self
	_lobby_layer.add_child(_lobby)


## 启动参数：用两个进程（或两台机器）快速验证联机，不必先点进大厅。
##   --host                 建房并进入大厅房间页
##   --join=192.168.1.23    直接连房主
##   --name=车长            覆盖显示名
##   --port=45888           覆盖 ENet 端口
##   --discovery-port=45887 覆盖房间发现端口（同机双开时必须改一个）
func _parse_cmdline() -> void:
	var want_host := false
	var join_ip := ""
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a == "--host":
			want_host = true
		elif a.begins_with("--join="):
			join_ip = a.trim_prefix("--join=")
		elif a.begins_with("--name="):
			Settings.player_name = a.trim_prefix("--name=")
		elif a.begins_with("--port="):
			Settings.net_port = clampi(int(a.trim_prefix("--port=")), 1024, 65535)
		elif a.begins_with("--discovery-port="):
			Settings.discovery_port = clampi(int(a.trim_prefix("--discovery-port=")), 1024, 65535)
	if not want_host and join_ip.is_empty():
		return
	_enter_lobby()
	if want_host:
		_lobby.host_from_cmdline()
	elif not join_ip.is_empty():
		_lobby.join_from_cmdline(join_ip)


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
	if Net.is_multiplayer():
		# 联机时地形与种子由房主在大厅里定，并在 start_match 时写进 match_info；
		# 单机仍然走下面的随机轮换。
		terrain = int(Net.match_info.get("terrain", 0))
		_stage_seed = int(Net.match_info.get("seed", Net.room_seed)) + stage * 7919
	else:
		terrain = _sel_terrain if _sel_terrain >= 0 else (_terrain_offset + stage - 1) % Arena.TERRAINS.size()
		_stage_seed = 0
	arena.generate(stage, terrain, _stage_seed)
	# 混响跟着地形走：砖石回廊有尾音、雪原几乎没有。
	# 于是玩家闭着眼听一发炮也能判断出自己在哪张图上。
	Audio.set_space(String(Arena.TERRAINS[terrain]["layout"]))
	_clear_battle()
	_build_spawn_queue()
	_stage_cleared = false
	max_active = _net_max_active()
	_stage_damage_bonus = 0.0
	_fortify_t = 0.0
	_spawn_t = 2.0
	_respawn_t = 0.0
	_field_t = randf_range(FIELD_DROP_MIN, FIELD_DROP_MAX) * 0.45
	combo_mult = 1.0
	_spawn_players_for_stage()
	net_fortify = false
	state = "ready"
	state_timer = 2.6
	_refresh_mouse_mode()
	_banner("第 %d 关  ·  %s  ·  %s" % [stage, terrain_name(), DIFF_NAMES[difficulty]], 2.6)
	Audio.play("spawn")
	# 房主把"下一关从哪里开始"发给客户端。客户端不跑 _start_stage，
	# 收到这条后自己按同一个种子重建同一张地图并落车。
	if Net.is_host():
		Net.broadcast_stage_start(stage, terrain, _stage_seed, difficulty)


## 同屏敌人上限按人数放宽，但只放宽"同时在场"的数量，不把波次总量翻倍——
## 四人局要的是更多同时压上来的目标，而不是把一关拖成两倍时长。
func _net_max_active() -> int:
	var base: int = mini(2 + int(stage / 2.0), 6)
	if not Net.is_multiplayer():
		return base
	var n: int = maxi(1, Net.players.size())
	return mini(base + (n - 1), 8)


## 合作模式的人数难度：每多一名玩家，敌车血量 +30%。
##
## 只加"同时在场"的数量（见 _net_max_active）会让四人局变成四把快刀切豆腐；
## 血量成长则让每辆车仍然需要被认真对待。两端都用同一份名册算，结果一致；
## 客户端的敌车是复制品，真正结算伤害的只有房主那份。
func _scale_enemy_for_coop(e: Enemy) -> void:
	if not Net.is_multiplayer() or e == null:
		return
	var n: int = maxi(1, Net.players.size())
	if n <= 1:
		return
	var m := 1.0 + 0.3 * (n - 1)
	e.max_hp = int(round(e.max_hp * m))
	e.hp = e.max_hp


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
		_scale_enemy_for_coop(e)
		e.setup(self, arena, pos)
		add_child(e)
		# 主节点是 ALWAYS（为了在暂停里还能读 Esc），所以动态生成的战场单位
		# 必须显式标成 PAUSABLE，否则它们会跟着主节点一起继续跑。
		e.process_mode = Node.PROCESS_MODE_PAUSABLE
		e.net_id = Net.alloc_enemy_id()
		e.team = 1
		Net.register_tank(e, e.net_id)
		enemies.append(e)
		if Net.is_host():
			Net.broadcast_enemy_spawn({
				"id": e.net_id, "type": t, "pos": pos, "hp": e.hp,
				"stage": stage, "diff": difficulty,
			})
		Fx.smoke_puff(fx_root, pos + Vector3(0, 0.45, 0), 0.8)
		Audio.play_3d("spawn", pos)
		if t == 4:
			_banner("⚠ 敌方指挥车出现！", 3.0)
			Audio.play("alert")
		return true
	return false


func _spawn_player(at := Vector3.INF, want_tank := "", pid := 0, local := true) -> Player:
	var pos := at
	if pos == Vector3.INF:
		pos = arena.player_spawn()
	# 重生点如果压着一具还没塌的残骸，先让它塌掉。新车会直接生成在静态碰撞体里，
	# 而 Tank._settle() 只按网格解交、看不见 LAYER_BLOCKER 上的残骸。
	arena.collapse_wreck_near(pos, Arena.CELL * 1.2)
	var p := Player.new()
	# 车型必须在 add_child() 之前写入：Player._ready() 按它装配碰撞体尺寸与全部属性
	p.tank_id = want_tank if TankRoster.has(want_tank) else (
			Settings.selected_tank if TankRoster.has(Settings.selected_tank) \
			else TankRoster.DEFAULT_ID)
	p.peer_id = pid if pid > 0 else (1 if Net.is_offline() else Net.local_pid())
	p.net_id = p.peer_id
	p.is_local = local
	p.is_remote = (not local) and Net.is_multiplayer()
	var row: Dictionary = Net.players.get(p.peer_id, {}) if Net.is_multiplayer() else {}
	p.rig = rig if local else null
	p.setup(self, arena, pos)
	add_child(p)
	# 必须在 _ready() 之后再写显示名：Player._ready() 会把它重置成"指挥官"，
	# 联机名册里的昵称会被这一步吞掉。
	p.display_name = String(row.get("name", "指挥官"))
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	# 必须在 _ready() 之后，否则基础属性会覆盖难度调整
	p.apply_difficulty(difficulty)
	p.damage_mult = 1.0 + _stage_damage_bonus
	p.shield_t = 3.0
	players.append(p)
	Net.register_tank(p, p.net_id)
	if local:
		player = p
		rig.reset_to(p)
		Audio.play("spawn")
	return p


## 按房主下发的名册把每一名玩家的车摆出来。房主与客户端都调它：
## 出生点由 Arena.player_spawn_index(i) 按同一个种子算出，不需要同步坐标。
func _spawn_players_for_stage() -> void:
	if Net.is_offline():
		_spawn_player()
		return
	var roster: Array = Net.match_info.get("players", [])
	for entry in roster:
		var e: Dictionary = entry
		var pid := int(e.get("pid", 0))
		var row: Dictionary = Net.players.get(pid, {})
		# 命数耗尽的玩家这一关不再落车；房主侧的重生事件会在下一关开局时重置。
		if not row.is_empty() and int(row.get("lives", 3)) <= 0:
			continue
		var pos := arena.player_spawn_index(int(e.get("spawn", 0)))
		var local := pid == Net.local_pid()
		_spawn_player(pos, String(e.get("tank_id", "")), pid, local)
	if player == null:
		_spectate()


## 命尽或重生等待中：把镜头交给一名还活着的队友。没有队友就保持自由镜头。
func _spectate() -> void:
	var best: Tank = null
	var best_d := 1.0e9
	var from: Vector3 = rig.global_position if rig != null else Vector3.ZERO
	for t in players:
		if t == player or not is_instance_valid(t) or not t.alive:
			continue
		var d := from.distance_squared_to(t.global_position)
		if d < best_d:
			best_d = d
			best = t
	if best != null:
		rig.target = best
	else:
		rig.target = null


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
	for t in players:
		if is_instance_valid(t):
			t.queue_free()
	players.clear()
	Net.clear_tanks()
	if player != null and is_instance_valid(player):
		player.queue_free()
	player = null
	_net_respawn.clear()
	_net_hit_claimed.clear()
	_client_last.clear()
	damage_marks.clear()
	smoke_clouds.clear()


func _count_active() -> int:
	var c := 0
	for e in enemies:
		if is_instance_valid(e) and e.alive:
			c += 1
	return c


func enemies_remaining() -> int:
	# 客户端没有出怪队列，只能读房主快照里的数字。
	if Net.is_client() and net_remaining >= 0:
		return net_remaining
	return _count_active() + spawn_queue.size()


func all_tanks() -> Array:
	var out: Array = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p)
	for e in enemies:
		if is_instance_valid(e) and e.alive:
			out.append(e)
	return out


## 离 pos 最近的存活真人。敌人 AI 用它选择目标。
func nearest_player(pos: Vector3) -> Tank:
	var best: Tank = null
	var best_d := 1.0e18
	for p in players:
		if not is_instance_valid(p) or not p.alive:
			continue
		var d := pos.distance_squared_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


## 玩家车体的 RID 列表。炮弹用它排除友伤：合作模式里队友不打队友，
## 于是"准星扫过队友"不会莫名其妙地跳一个"跳弹"。
func human_rids() -> Array:
	var out: Array = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p.get_rid())
	return out


## 某名 peer 的车。房主替客户端结算与重生时用。
func player_for_pid(pid: int) -> Player:
	for p in players:
		if is_instance_valid(p) and int(p.peer_id) == pid:
			return p
	return null


# ---------------- 供其它脚本调用的接口 ----------------

func spawn_shell(from: Tank, origin: Vector3, dir: Vector3, kind: int, uid := 0,
		visual := false) -> void:
	var s := Shell.new()
	s.launch(self, arena, from, origin, dir, kind, uid)
	s.visual_only = visual
	add_child(s)
	s.process_mode = Node.PROCESS_MODE_PAUSABLE


## Tank.fire() 的联机入口。Net 内部按角色分流：客户端上报意图，房主生成并广播。
func submit_shot(from: Tank, origin: Vector3, dir: Vector3, kind: int) -> void:
	if from == null:
		return
	Net.submit_shot(from, origin, dir, kind)


## 客户端收到房主的开火事件：生成纯表现炮弹。
## 远端射手还要补一次炮口焰与炮声——射出端只在它自己的机器上播过，
## 不然队友的炮在别人眼里就是"没有火光、没有声音"的幽灵炮弹。
func spawn_visual_shell(net_id: int, origin: Vector3, dir: Vector3, kind: int, uid: int) -> void:
	var shooter := Net.get_tank(net_id)
	spawn_shell(shooter, origin, dir, kind, uid, true)
	if shooter != null and not shooter.is_local:
		shooter.play_fire_fx(dir, kind)


func on_tank_destroyed(t: Tank) -> void:
	# 死亡由房主广播；客户端只按事件播表现，不会走到这条结算路径。
	if Net.is_host():
		Net.broadcast_death(t.net_id, t.global_position, t.rotation.y, 0)
	Net.unregister_tank(t.net_id)
	if t.is_player:
		_on_player_death(t)
		return

	_kills += 1
	# 合作模式下房主会替客户端结算伤害：只有本机玩家打掉的敌人进本机战绩，
	# 否则房主的"击毁"会被队友的战果灌水。客户端由 net_apply_feedback 记账。
	if not Net.is_multiplayer() or (t.last_shooter != null \
			and is_instance_valid(t.last_shooter) and t.last_shooter.is_local):
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


func on_player_hit(t: Tank, from_pos: Vector3, dmg: int) -> void:
	# 房主替队友模拟时也会走到这里。受击暗角、震屏属于"本机玩家"的表现，
	# 队友挨打不该在房主屏幕上抖一下。
	if t != null and t != player:
		return
	damage_marks.append({"pos": from_pos, "t": 1.4})
	rig.add_trauma(clampf(dmg / 160.0, 0.15, 0.6))
	hit_vignette = minf(1.0, hit_vignette + clampf(dmg / 200.0, 0.25, 0.8))
	combo_mult = 1.0
	_combo_t = 0.0


## 玩家自己的车身挡下了一发（跳弹 / 护盾）。与"挨打"相反，这是好消息，
## 但也必须给反馈：斜摆车身之所以值得练，唯一的原因就是玩家能看见它起作用。
## 原来 take_hit() 在这两种情况下直接 return，没有方向环、没有震屏、没有提示——
## 玩家只会以为"对方打偏了"。
func on_player_blocked(t: Tank, what: String, blocked := 0) -> void:
	if t != null and t != player:
		return
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


## Shell 的命中结果统一从这里分流：本机玩家的甩给自己，远端玩家的发回射手。
func net_shell_feedback(shooter: Tank, uid: int, text: String, pos: Vector3,
		result: String, amount: int, etype: int) -> void:
	if shooter == null or not is_instance_valid(shooter):
		return
	if shooter.is_local:
		on_shell_feedback(text, pos, true, result, amount, etype)
	elif Net.is_host():
		Net.send_shell_feedback(int(shooter.peer_id), uid, text, pos, result, amount, etype)


## 客户端收到"我这一发的结果"。命中率按击发去重：一发多弹或 HE 溅射
## 会来好几条反馈，但只能算一次命中。
func net_apply_feedback(uid: int, text: String, pos: Vector3, result: String,
		amount: int, etype: int) -> void:
	if not _net_hit_claimed.has(uid):
		_net_hit_claimed[uid] = true
		Stats.add_hit()
	# 击毁次数按"这条结果属于哪一发"记：一发多杀会来多条 kill，都是真实击毁。
	if result == "kill":
		Stats.add_kill()
	on_shell_feedback(text, pos, true, result, amount, etype)


func deploy_smoke(pos: Vector3, dur: float, owner := 0) -> void:
	Fx.smoke_screen(fx_root, pos, dur)
	smoke_clouds.append({"pos": pos, "r": SMOKE_RADIUS, "t": dur})
	if smoke_clouds.size() > SMOKE_CLOUDS_MAX:
		smoke_clouds.pop_front()
	if Net.is_host():
		Net.broadcast_smoke(pos, dur, owner)


## 客户端收到别人的烟幕。自己那团已经在本地放过了（owner 过滤在 Net 里）。
func net_add_smoke(pos: Vector3, dur: float) -> void:
	deploy_smoke(pos, dur, 0)


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


## 房主 / 单机：某名玩家捡到了一只补给箱。
func pickup_powerup(pu, t) -> void:
	if Net.is_client():
		return
	if not is_instance_valid(pu) or t == null or not is_instance_valid(t) or not t.alive:
		return
	var uid: int = int(pu.uid)
	var ptype: int = int(pu.ptype)
	powerups.erase(pu)
	pu.queue_free()
	if Net.is_host():
		Net.broadcast_powerup_taken(uid, int(t.peer_id), ptype)
	score += 300
	apply_powerup_to(t, ptype)


## 客户端收到"某人拿到了补给"。
func net_take_powerup(uid: int, pid: int, ptype: int) -> void:
	for pu in powerups:
		if is_instance_valid(pu) and int(pu.uid) == uid:
			powerups.erase(pu)
			pu.queue_free()
			break
	var owner := player_for_pid(pid)
	if owner != null:
		apply_powerup_to(owner, ptype)
	if ptype == PowerUp.Type.AIRSTRIKE:
		# 伤害是房主算的，客户端只补爆炸表现，否则屏幕上看不到支援落地。
		rig.add_trauma(0.9)
		for e in enemies:
			if is_instance_valid(e) and e.alive:
				Fx.explosion(fx_root, e.global_position + Vector3(0, 1.0, 0), 2.2)
	elif ptype == PowerUp.Type.FORTIFY:
		arena.set_fortify(true)
		net_fortify = true


func apply_powerup_to(t: Tank, ptype: int) -> void:
	if t == null or not is_instance_valid(t):
		return
	var d := PowerUp.info(ptype)
	Audio.play("pickup")
	if not t.alive:
		return

	match ptype:
		PowerUp.Type.REPAIR:
			t.hp = mini(t.max_hp, t.hp + int(t.max_hp * 0.45))
		PowerUp.Type.ARMOR:
			t.armor_buff_t = 20.0
		PowerUp.Type.RAPID:
			t.rapid_buff_t = 20.0
		PowerUp.Type.SHIELD:
			t.shield_t = 8.0
		PowerUp.Type.AIRSTRIKE:
			# 伤害只由房主结算；客户端在 net_take_powerup 里只补爆炸表现。
			if not Net.is_client():
				_airstrike()
		PowerUp.Type.FORTIFY:
			arena.set_fortify(true)
			_fortify_t = 25.0
		PowerUp.Type.FIREPOWER:
			_stage_damage_bonus += 0.25
			t.damage_mult = 1.0 + _stage_damage_bonus
		PowerUp.Type.MULTISHOT:
			t.multi_t = 22.0
		PowerUp.Type.OVERDRIVE:
			t.overdrive_t = 20.0
	_banner("%s — %s" % [d["name"], d["desc"]], 2.0)
	Audio.play("power")


func _airstrike() -> void:
	Audio.play("alert")
	rig.add_trauma(0.9)
	for e in enemies.duplicate():
		if not is_instance_valid(e) or not e.alive:
			continue
		Fx.explosion(fx_root, e.global_position + Vector3(0, 1.0, 0), 2.2)
		# 空袭没有炮弹上下文，击毁归属直接写成本机玩家（客户端不吃这条分支）。
		e.last_shooter = player
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
	p.uid = Net.alloc_powerup_id()
	p.position = pos
	add_child(p)
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	powerups.append(p)
	if Net.is_host():
		Net.broadcast_powerup_spawn({
			"uid": p.uid, "pos": pos, "ptype": ptype, "from_field": from_field,
		})
	return p


## 客户端收到房主空投 / 掉落：只建一只纯表现的箱子，等待拾取或超时事件。
func net_spawn_powerup(data: Dictionary) -> void:
	var uid := int(data.get("uid", 0))
	for pu in powerups:
		if is_instance_valid(pu) and int(pu.uid) == uid:
			return
	var p := PowerUp.new()
	p.game = self
	p.ptype = int(data.get("ptype", PowerUp.Type.REPAIR))
	p.from_field = bool(data.get("from_field", false))
	p.uid = uid
	p.visual_only = true
	p.position = data.get("pos", Vector3.ZERO)
	add_child(p)
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	powerups.append(p)


## 本机玩家还剩几辆战车。单机看 lives，联机看房主名册里的那一行。
## HUD 与结算页都读它，免得"队友的命数"被算到自己头上。
func my_lives() -> int:
	if Net.is_multiplayer():
		var row: Dictionary = Net.players.get(Net.local_pid(), {})
		return maxi(0, int(row.get("lives", 0)))
	return lives


# ---------------- 联机世界同步 ----------------
#
# 房主每 25 Hz 发一份快照，客户端只做两件事：把快照插值到远端车身上、
# 把房主的状态机投影到本地 HUD；客户端自己的车由本地输入推进，每 30 Hz
# 上报一次位置。战斗结算（伤害、死亡、拆墙、补给、基地）全部由房主决定。

## 房主：开场。stage / terrain / 名册都来自 Net.start_match，客户端随后
## 会收到单独的 net_stage_start，所以这里只有房主真正生成战场。
func net_begin_match(info: Dictionary) -> void:
	stage = int(info.get("stage", 1))
	terrain = int(info.get("terrain", 0))
	difficulty = int(info.get("difficulty", 1))
	score = 0
	lives = MAX_LIVES
	combo_mult = 1.0
	_kills = 0
	_stage_cleared = false
	get_tree().paused = false
	if _lobby != null:
		_lobby.close()
	_hide_menu()
	hud.visible = true
	if Net.is_host():
		Stats.begin_run()
		_start_stage()


## 客户端：按房主下发的关卡、地形与种子重建同一张地图。这里刻意不跑
## `_start_stage()`：出怪队列、计分、关卡推进都只属于房主。
func net_begin_stage(info: Dictionary) -> void:
	if not Net.is_client():
		return
	stage = int(info.get("stage", stage))
	terrain = int(info.get("terrain", terrain))
	difficulty = int(info.get("difficulty", difficulty))
	_stage_seed = int(info.get("seed", 0))
	arena.generate(stage, terrain, _stage_seed)
	Audio.set_space(String(Arena.TERRAINS[clampi(terrain, 0, Arena.TERRAINS.size() - 1)]["layout"]))
	_clear_battle()
	_stage_cleared = false
	max_active = _net_max_active()
	net_remaining = -1
	_fortify_t = 0.0
	_net_respawn.clear()
	_spawn_players_for_stage()
	state = "ready"
	state_timer = 2.6
	_hide_menu()
	hud.visible = true
	_refresh_mouse_mode()
	_banner("第 %d 关  ·  %s  ·  %s" % [stage, terrain_name(), DIFF_NAMES[difficulty]], 2.6)
	Audio.play("spawn")


func _net_tank_row(t: Tank) -> Dictionary:
	var turret_yaw := t.rotation.y
	if t.turret != null:
		turret_yaw += t.turret.rotation.y
	var pitch := 0.0
	if t.barrel != null:
		pitch = t.barrel.rotation.x
	return {
		"id": int(t.net_id),
		"pos": t.global_position,
		"yaw": t.rotation.y,
		"turret": turret_yaw,
		"pitch": pitch,
		"spd": t.speed(),
		"hp": t.hp,
	}


## 房主：打包这一帧的世界状态。敌人带一个 AI 状态位，客户端只用来
## 决定"该不该继续听发动机声"这类表现，不参与行为。
func net_collect_snapshot() -> Dictionary:
	if not Net.is_host():
		return {}
	var ps: Array = []
	for t in players:
		if is_instance_valid(t) and t.alive:
			ps.append(_net_tank_row(t))
	var es: Array = []
	for e in enemies:
		if not is_instance_valid(e) or not e.alive:
			continue
		var row := _net_tank_row(e)
		row["st"] = int(e.state)
		es.append(row)
	return {
		"p": ps,
		"e": es,
		"base": arena.base_hp,
		"fort": arena.is_fortified(),
		"state": state,
		"timer": state_timer,
		"score": score,
		"left": _count_active() + spawn_queue.size(),
	}


func _net_apply_row(t: Tank, row: Dictionary) -> void:
	t.apply_net_state(
		row.get("pos", t.global_position),
		float(row.get("yaw", t.rotation.y)),
		float(row.get("turret", t.rotation.y)),
		float(row.get("pitch", 0.0)),
		float(row.get("spd", 0.0)),
		int(row.get("hp", t.hp)),
		true)


## 客户端：把房主快照落到远端车、基地血条、加固状态与 HUD 数字上。
## 本地车只回写 hp——位置永远以本地输入为准。
func net_apply_snapshot(data: Dictionary) -> void:
	if not Net.is_client():
		return
	if state == "title" or state == "lobby":
		return
	for row in data.get("p", []):
		var t := Net.get_tank(int((row as Dictionary).get("id", 0)))
		if t != null:
			_net_apply_row(t, row)
	for row in data.get("e", []):
		var e := Net.get_tank(int((row as Dictionary).get("id", 0)))
		if e != null:
			_net_apply_row(e, row)
	if arena != null:
		arena.set_base_hp_net(int(data.get("base", arena.base_hp)))
		var fort := bool(data.get("fort", false))
		if arena.is_fortified() != fort:
			arena.set_fortify(fort)
			net_fortify = fort
	net_remaining = int(data.get("left", net_remaining))
	score = int(data.get("score", score))
	# 倒计时、肃清与结算页由房主的状态机驱动；客户端只跟随，不自行推进。
	#
	# 但本地暂停是一个纯覆盖层：房主还在跑，客户端也不能被快照从 "pause"
	# 拽回 "play"，否则按 Esc 打开的菜单会在下一帧被状态机关掉，
	# 再按 Esc 又打开——看起来就是暂停键失灵。
	if state == "pause":
		return
	var st := String(data.get("state", ""))
	if (st == "ready" or st == "play" or st == "clear") and st != state:
		state = st
		state_timer = float(data.get("timer", 0.0))
		_refresh_mouse_mode()


## 客户端：本机玩家的位置与姿态。房主拿它驱动"这个 peer 的车"，
## 再随快照转发给其他人。
func net_collect_local_state() -> Dictionary:
	if not Net.is_client():
		return {}
	var p := player
	if p == null or not is_instance_valid(p) or not p.alive:
		return {}
	if p.turret == null or p.barrel == null:
		return {}
	return {
		"pos": p.global_position,
		"yaw": p.rotation.y,
		"turret": p.rotation.y + p.turret.rotation.y,
		"pitch": p.barrel.rotation.x,
		"spd": p.speed(),
	}


## 房主：接收客户端上报的位置并做位移校验。
##
## 客户端权威移动换来了最好的手感，代价是房主不能盲信上报值。这里只拦
## "物理上不可能"的情况：按车型极速的 2.2 倍加上 2.5 米容差算出一帧内
## 允许的最大位移，超出就把位置拉回到合法圆上并记账。正常的网络抖动
## 远小于这个阈值，所以不会出现"跑着跑着被拽回来"的橡皮筋。
func net_apply_client_state(pid: int, data: Dictionary) -> void:
	var t := player_for_pid(pid)
	if t == null or not t.alive:
		return
	var pos: Vector3 = data.get("pos", t.global_position)
	if pos == Vector3.INF or not pos.is_finite():
		return
	var now := Time.get_ticks_msec() / 1000.0
	_net_client_updates += 1
	var last: Dictionary = _client_last.get(pid, {})
	if not last.is_empty():
		var from: Vector3 = last.get("pos", pos)
		var dt := clampf(now - float(last.get("t", now)), 0.001, 1.0)
		var max_d: float = t.move_speed * 2.2 * dt + 2.5
		if pos.distance_to(from) > max_d:
			pos = from + (pos - from).limit_length(max_d)
			_net_pullbacks += 1
	_client_last[pid] = {"pos": pos, "t": now}
	t.apply_net_state(pos,
		float(data.get("yaw", t.rotation.y)),
		float(data.get("turret", t.rotation.y)),
		float(data.get("pitch", 0.0)),
		float(data.get("spd", 0.0)),
		t.hp, true)


## 客户端：房主生成了一辆敌车。AI 只在房主那边跑，这里拿到的是复制品。
func net_spawn_enemy(data: Dictionary) -> void:
	if not Net.is_client():
		return
	var id := int(data.get("id", 0))
	if id == 0 or Net.get_tank(id) != null:
		return
	var e := Enemy.new()
	e.configure(int(data.get("type", 1)), int(data.get("stage", stage)),
			int(data.get("diff", difficulty)))
	_scale_enemy_for_coop(e)
	e.is_remote = true
	e.team = 1
	e.net_id = id
	e.setup(self, arena, data.get("pos", Vector3.ZERO))
	add_child(e)
	e.process_mode = Node.PROCESS_MODE_PAUSABLE
	Net.register_tank(e, id)
	e.apply_net_state(e.global_position, e.rotation.y, e.rotation.y, 0.0, 0.0,
			int(data.get("hp", e.hp)), true)
	enemies.append(e)


## 客户端：房主让某名玩家落车（开局或重生）。本地玩家的车会重新拿到镜头。
func net_spawn_player(data: Dictionary) -> void:
	if not Net.is_client():
		return
	var pid := int(data.get("pid", 0))
	if pid <= 0:
		return
	var old := player_for_pid(pid)
	if old != null:
		players.erase(old)
		Net.unregister_tank(old.net_id)
		old.free_for_net()
	var local := pid == Net.local_pid()
	var p := _spawn_player(data.get("pos", Vector3.ZERO),
			String(data.get("tank_id", "")), pid, local)
	p.hp = int(data.get("hp", p.max_hp))
	if local:
		_banner("战车已就绪，重新出击", 1.5)


## 客户端：某辆车被击毁。伤害与扣命已经在房主那边结算完了，
## 这里只播爆炸、留残骸、把本地引用摘干净。
func net_apply_death(net_id: int, pos: Vector3, yaw: float, _killer_id: int) -> void:
	if not Net.is_client():
		return
	var t := Net.get_tank(net_id)
	if t == null:
		return
	var was_local := t == player
	if t is Player:
		players.erase(t)
	else:
		enemies.erase(t)
	Net.unregister_tank(net_id)
	t.global_position = pos
	t.rotation.y = yaw
	if was_local:
		player = null
		rig.target = null
		_banner("战车被击毁，等待重生…", 2.0)
		_spectate()
	t.net_die()


## 客户端：房主拆掉了一格墙。走 Arena 的同一条 _clear_cell 路径，
## 于是碎砖、焦痕、寻路封格在两边看起来完全一样。
func net_apply_cell(cell: Vector2i) -> void:
	if arena != null:
		arena.apply_cell_destroyed(cell)


## 客户端：本地玩家挨了一发。血量的权威值随快照到达，这里只补方向指示
## 与暗角，否则客户端被打时会"毫无反馈地掉血"。
func net_apply_hit(data: Dictionary) -> void:
	if not Net.is_client():
		return
	var t := Net.get_tank(int(data.get("id", 0)))
	if t == null or t != player:
		return
	on_player_hit(t, data.get("from", t.global_position), int(data.get("dmg", 0)))


## 房主：远端玩家挨打时把事件发给射手本人（on_player_hit 只在 is_local
## 时调用，房主屏幕不该替队友抖一下）。
func net_note_player_hit(t: Tank, from_pos: Vector3, dmg: int) -> void:
	if Net.is_host() and t != null and t.is_player:
		Net.broadcast_hit({"id": int(t.net_id), "from": from_pos, "dmg": dmg})


## 客户端：房主宣布结算。分数以房主为准，客户端不再累加。
func net_end_match(won: bool, score_value: int) -> void:
	if not Net.is_client():
		return
	score = score_value
	Net.match_active = false
	state = "win" if won else "over"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	if _lobby != null:
		_lobby.close()
	if score > high_score:
		high_score = score
		_save_high_score()
	_show_menu("全 线 胜 利" if won else "战 败", _result_text(won))
	Audio.play("victory" if won else "gameover")


## 房主：一名玩家退出了房间。他的车从场上撤掉，名册同步给其余人。
## 光是撤掉房主这份还不够：其他客户端那边也有一辆"他的车"，必须显式通知，
## 否则那辆车会永远停在原地，被当成存活的队友继续画在雷达上。
func net_player_left(pid: int) -> void:
	var t := player_for_pid(pid)
	if t != null:
		players.erase(t)
		Net.unregister_tank(t.net_id)
		if t == player:
			player = null
			_spectate()
		t.free_for_net()
	_client_last.erase(pid)
	Net.broadcast_player_left(pid)
	Net.push_roster()


## 客户端：队友掉线。只收尸，不播爆炸——车是被"撤走"的，不是被击毁的。
func net_remote_player_left(pid: int) -> void:
	var t := player_for_pid(pid)
	if t != null:
		players.erase(t)
		Net.unregister_tank(t.net_id)
		if t == player:
			player = null
			rig.target = null
			_spectate()
		t.free_for_net()
	_client_last.erase(pid)


func _on_arena_cell_destroyed(cell: Vector2i) -> void:
	if Net.is_host():
		Net.broadcast_cell(cell)


func _on_net_match_started(_info: Dictionary) -> void:
	if _lobby != null:
		_lobby.close()
	_hide_menu()
	hud.visible = true
	get_tree().paused = false
	_refresh_mouse_mode()


func _on_net_match_ended(_won: bool, _score: int) -> void:
	# 结算页已经在 net_end_match / _game_over / _win 里画好了，
	# 这里只兜底把 HUD 收起来，避免同一次结算被画两遍。
	if hud != null:
		hud.visible = false


func _on_net_session_ended(reason: String) -> void:
	# 大厅里的连接失败由大厅自己显示状态；只有打到一半掉线才回标题。
	if state == "lobby" or state == "title":
		return
	_enter_title()
	_show_menu("连 接 中 断", "%s\n\n按 Enter 返回" % reason)


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

func _on_player_death(t: Player) -> void:
	players.erase(t)
	var was_local := t == player
	if was_local:
		player = null
		rig.target = null
		# 重生等待的 2.5 秒里先看队友，而不是让镜头悬在原地。
		_spectate()
	combo_mult = 1.0
	if was_local:
		rig.add_trauma(1.0)

	# 客户端：命数归房主管，这里只有表现。重生由 net_player_spawn 事件落车。
	if Net.is_client():
		if was_local:
			_banner("战车被击毁，等待重生…", 2.0)
		return

	var pid := int(t.peer_id)
	if pid <= 0:
		pid = 1
	var remaining := 0
	if Net.is_multiplayer():
		var row: Dictionary = Net.players.get(pid, {})
		remaining = int(row.get("lives", 1)) - 1
		row["lives"] = remaining
		row["alive"] = false
		Net.players[pid] = row
		Net.push_roster()
		# 房主本人的重生也走统一队列，于是结算逻辑只有一套。
		if remaining > 0:
			_net_respawn.append({"pid": pid, "t": 2.5})
	else:
		lives -= 1
		remaining = lives
		if lives > 0:
			_respawn_t = 2.5

	if remaining > 0:
		_banner("战车被击毁，剩余 %d 辆" % remaining, 2.0)
	else:
		_banner("最后一辆战车被击毁", 2.0)
		_check_team_wipe()


## 房主侧重生一辆车，并把"哪个 peer、在哪、多少血"广播给所有人。
## 客户端本地车与远端队友车都从这一条事件落车。
func _respawn_net_player(pid: int) -> void:
	var row: Dictionary = Net.players.get(pid, {})
	if row.is_empty():
		return
	var pos := _spawn_pos_for_pid(pid)
	var local := pid == Net.local_pid()
	# 重生是一次瞬移：清掉位移校验的基准点，否则客户端从死亡点报回出生点时
	# 会被房主当成"超速"一帧帧拉回来，在别人眼里就是队友贴着地面滑过去。
	_client_last.erase(pid)
	var p := _spawn_player(pos, String(row.get("tank_id", "")), pid, local)
	row["alive"] = true
	Net.players[pid] = row
	Net.broadcast_player_spawn({
		"pid": pid, "pos": pos, "hp": p.hp, "max_hp": p.max_hp,
		"tank_id": p.tank_id, "lives": int(row.get("lives", 0)),
	})
	Net.push_roster()


func _spawn_pos_for_pid(pid: int) -> Vector3:
	var roster: Array = Net.match_info.get("players", [])
	for entry in roster:
		var e: Dictionary = entry
		if int(e.get("pid", -1)) == pid:
			return arena.player_spawn_index(int(e.get("spawn", 0)))
	return arena.player_spawn()


## 全员命尽才判负。基地被毁另有自己的入口（on_base_destroyed）。
func _check_team_wipe() -> void:
	if Net.is_client() or state == "over" or state == "win":
		return
	if Net.is_multiplayer():
		for pid in Net.players.keys():
			var row: Dictionary = Net.players[pid]
			if int(row.get("lives", 0)) > 0:
				return
	else:
		if lives > 0:
			return
	_game_over()


func _game_over() -> void:
	state = "over"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	if _lobby != null:
		_lobby.close()
	var won := false
	if score > high_score:
		high_score = score
		_save_high_score()
	Stats.end_run(_player_tank_id(), difficulty, score, won)
	Net.match_active = false
	if Net.is_host():
		Net.broadcast_match_end(false, score)
	_show_menu("战 败", _result_text(won))
	Audio.play("gameover")


func _win() -> void:
	state = "win"
	get_tree().paused = false
	_refresh_mouse_mode()
	hud.visible = false
	if _lobby != null:
		_lobby.close()
	score += lives * 3000
	if score > high_score:
		high_score = score
		_save_high_score()
	Stats.end_run(_player_tank_id(), difficulty, score, true)
	Net.match_active = false
	if Net.is_host():
		Net.broadcast_match_end(true, score)
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
	if Net.is_multiplayer():
		lines.append("Enter 返回标题（离开房间）")
	else:
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

	_scrim = ColorRect.new()
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.45)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_scrim)

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

	_build_title_ui()
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


# ---------------- 标题页 ----------------
#
# 标题页不再是"一坨居中文字"，而是三层信息：
#   · 左上：英文小标 + 中文主标题 + 一句定位语；
#   · 左中：两个大按钮（单人 / 局域网），键位提示贴在按钮右侧；
#   · 底部：按"驾驶 / 瞄准 / 火力 / 战术 / 系统"分组的操作条。
# 右半屏刻意留空，让背景里的坦克与爆炸成为画面的一部分。
#
# 所有位置在 _layout_title() 里按可见区域算：界面缩放 200% 时 UI 空间只剩
# 960x540，固定坐标会让底部操作条压住按钮。窗口再矮就整体缩小并收起操作条。

func _build_title_ui() -> void:
	_title_ui = Control.new()
	_title_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_ui.visible = false
	_menu.add_child(_title_ui)

	# 左暗右亮的横向渐变代替全屏遮罩：标题与按钮这一侧需要压暗才读得清，
	# 而右半屏的坦克与落日是这张背景图的主角，不该被一层灰罩子统一压掉。
	# 渐变在 85% 屏宽处收到全透明，右侧完全没有多余的一层。
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.42, 0.86])
	grad.colors = PackedColorArray([
		Color(0.008, 0.012, 0.018, 0.92),
		Color(0.008, 0.012, 0.018, 0.62),
		Color(0.008, 0.012, 0.018, 0.0),
	])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill_from = Vector2(0.0, 0.5)
	grad_tex.fill_to = Vector2(1.0, 0.5)
	grad_tex.width = 512
	grad_tex.height = 8
	var shade := TextureRect.new()
	shade.texture = grad_tex
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.anchor_right = 0.85
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_ui.add_child(shade)

	_title_col = VBoxContainer.new()
	_title_col.add_theme_constant_override("separation", 0)
	_title_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_ui.add_child(_title_col)

	var eye := _title_label(_title_col, "T A N K   B A T T L E   3 D", 14,
			Color(0.96, 0.82, 0.45, 0.90))
	eye.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	eye.add_theme_constant_override("outline_size", 4)

	var title := _title_label(_title_col, "坦克大战 3D", 62, Color(1.0, 0.86, 0.32))
	title.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02, 0.97))
	title.add_theme_constant_override("outline_size", 12)

	var tag := _title_label(_title_col, "炮塔分离操控 · 可破坏战场 · 局域网合作", 15,
			Color(0.88, 0.92, 0.97))
	tag.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	tag.add_theme_constant_override("outline_size", 4)

	_title_gap(24.0)
	# 主操作：单人战役。青色实心 + 金色左条，和次要的联机入口一眼分开。
	var solo := _title_button(_title_col, "单人出击", "选择战车、关卡与难度",
			"Enter", true)
	solo.pressed.connect(func() -> void:
		Audio.play("switch")
		_enter_select())
	_title_gap(12.0)
	var lan := _title_button(_title_col, "局域网联机", "2–4 人合作守基地", "L", false)
	lan.pressed.connect(func() -> void:
		Audio.play("switch")
		_enter_lobby())
	_title_gap(14.0)
	_title_foot = _title_label(_title_col,
			"Esc 暂停与设置　·　F11 显示模式　·　F3 输入诊断", 12,
			Color(0.74, 0.80, 0.86))
	_title_foot.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_title_foot.add_theme_constant_override("outline_size", 3)

	# 底部操作条：五列分组，一列一件事。整块半透明垫在画面下沿，
	# 不遮挡战场主体，也让"键盘 / 手柄"两套按键能并排写出来。
	_title_bar = PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.bg_color = Color(0.02, 0.03, 0.045, 0.80)
	bs.border_color = Color(0.30, 0.44, 0.50, 0.55)
	bs.set_border_width_all(1)
	bs.set_corner_radius_all(6)
	bs.content_margin_left = 16.0
	bs.content_margin_right = 16.0
	bs.content_margin_top = 9.0
	bs.content_margin_bottom = 9.0
	_title_bar.add_theme_stylebox_override("panel", bs)
	_title_ui.add_child(_title_bar)

	var bar_col := VBoxContainer.new()
	bar_col.add_theme_constant_override("separation", 3)
	_title_bar.add_child(bar_col)

	var head := HBoxContainer.new()
	bar_col.add_child(head)
	var head_l := _title_label(head, "操 作 一 览", 12, Color(0.86, 0.92, 0.96, 0.85))
	head_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label(head, "键鼠 / 手柄", 11, Color(0.62, 0.70, 0.78))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	bar_col.add_child(row)
	for g in InputSetup.control_rows(Settings.drive_relative):
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 1)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(col)
		_title_label(col, "▍ " + String(g["label"]), 12, Color(0.55, 0.86, 0.92))
		var txt := _title_label(col, String(g["text"]), 13, Color(0.88, 0.92, 0.96))
		txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# 驾驶那一条随设置里的操控方案变（镜头相对 / 履带），记住它好热更新。
		if String(g["label"]) == "驾驶":
			_title_drive_l = txt


func _title_label(parent: Control, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _title_gap(h: float) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_col.add_child(c)


## 标题页的大按钮：整卡可点，左侧一条强调色，右侧是键位胶囊。
## 用 Button 承载整块而不是普通面板：鼠标划过有反馈、按下有位移，
## 玩家不需要"对准文字"才敢点。
func _title_button(parent: Control, title: String, hint: String, key: String,
		primary: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 66)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 焦点留给 Enter / L 的语义（始终是"单人 / 联机"），不让鼠标点击改变回车行为。
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	parent.add_child(b)
	_title_button_style(b, primary)

	var stripe := ColorRect.new()
	stripe.color = Color(1.0, 0.86, 0.32, 0.95) if primary \
			else Color(0.42, 0.52, 0.58, 0.75)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stripe.anchor_bottom = 1.0
	stripe.offset_right = 4.0
	b.add_child(stripe)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 18)
	pad.add_theme_constant_override("margin_right", 14)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	b.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(row)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	_title_label(col, title, 22 if primary else 21,
			Color(0.98, 1.0, 1.0) if primary else Color(0.90, 0.94, 0.98))
	_title_label(col, hint, 12,
			Color(0.74, 0.84, 0.88) if primary else Color(0.60, 0.68, 0.75))

	var cap := _title_keycap(row, key)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


func _title_button_style(b: Button, primary: bool) -> void:
	var bg := Color(0.10, 0.27, 0.31, 0.94) if primary \
			else Color(0.045, 0.06, 0.075, 0.90)
	var bd := Color(0.42, 0.82, 0.88, 0.95) if primary \
			else Color(0.28, 0.38, 0.44, 0.90)
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = bd
	s.set_border_width_all(1)
	s.set_corner_radius_all(5)
	s.content_margin_left = 0.0
	s.content_margin_right = 0.0
	s.content_margin_top = 0.0
	s.content_margin_bottom = 0.0
	b.add_theme_stylebox_override("normal", s)

	var hover := s.duplicate() as StyleBoxFlat
	hover.bg_color = bg.lightened(0.09)
	hover.border_color = bd.lightened(0.24)
	b.add_theme_stylebox_override("hover", hover)

	var pressed := s.duplicate() as StyleBoxFlat
	pressed.bg_color = bg.darkened(0.14)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", s)


func _title_keycap(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.90, 0.95, 1.0))
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.09, 0.11, 0.95)
	s.border_color = Color(0.36, 0.50, 0.56, 0.90)
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.content_margin_left = 9.0
	s.content_margin_right = 9.0
	s.content_margin_top = 2.0
	s.content_margin_bottom = 2.0
	l.add_theme_stylebox_override("normal", s)
	l.custom_minimum_size = Vector2(56, 26)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## 标题页排版。左栏从左上角排、底部操作条锚在屏幕下沿；三档尺寸：
## 720p 上下按原尺寸、更高的大屏放大到 1.5 倍、更矮的小屏整体缩小；
## 可见高度不足 470 时收起操作条，让页脚补一句。
## "按钮都在屏幕里"优先于"操作条一直在"。
func _layout_title() -> void:
	if _title_ui == null or _title_col == null or _title_bar == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var side := clampf(vp.x * 0.05, 24.0, 96.0)
	var bottom := clampf(vp.y * 0.05, 16.0, 56.0)
	var top := clampf(vp.y * 0.07, 18.0, 96.0)
	var s := 1.0
	if vp.y > 720.0:
		# 大屏上 62px 的标题丢进 1920 宽里只剩一个小角，构图会散。按高度
		# 放大到最多 1.5 倍，让标题、按钮与操作条的相对占比和 720p 那档一致。
		s = minf(vp.y / 720.0, 1.5)
	elif vp.y < 540.0:
		# 更矮就整体缩小：字号与按钮一起缩，优先保证它们都在屏幕里。
		s = maxf(vp.y / 540.0, 0.72)
	var col_w := minf(560.0, maxf((vp.x - side * 2.0) / s, 200.0))

	if _title_drive_l != null:
		_title_drive_l.text = String(InputSetup.control_rows(Settings.drive_relative)[0]["text"])

	# 底部操作条已经把"系统"那组列出来了；只有在矮屏收起操作条时，
	# 才让页脚出来补一句，免得同一屏里同一句话出现两次。
	var show_bar := vp.y >= 470.0
	_title_bar.visible = show_bar
	if _title_foot != null:
		_title_foot.visible = not show_bar

	_title_col.scale = Vector2(s, s)
	_title_col.position = Vector2(side, top)
	_title_col.size = Vector2(col_w, _title_col.get_combined_minimum_size().y)

	if _title_bar.visible:
		# 操作条与标题栏用同一个缩放：1080p 下按 1.5 倍画，字不会比标题小一号。
		# 锚点固定在左上，再按缩放后的宽高反推尺寸，右边缘才会刚好落在边距上。
		var bar_h := _title_bar.get_combined_minimum_size().y
		_title_bar.anchor_left = 0.0
		_title_bar.anchor_right = 0.0
		_title_bar.anchor_top = 0.0
		_title_bar.anchor_bottom = 0.0
		_title_bar.position = Vector2(side, vp.y - bottom - bar_h * s)
		_title_bar.size = Vector2((vp.x - side * 2.0) / s, bar_h)
		_title_bar.scale = Vector2(s, s)


func _show_menu(title: String, body: String) -> void:
	_menu.visible = true
	_bg.modulate = Color(1, 1, 1, 1)
	var path := "res://assets/bg/select.jpg" if state == "select" else "res://assets/bg/title.jpg"
	if state == "pause":
		_bg.texture = null
	elif ResourceLoader.exists(path):
		_bg.texture = load(path)
	_title_l.text = title

	# 标题页走单独的版式（左栏按钮 + 底部分组操作条）。它与居中文字互斥：
	# 两套都留着，标题就会被居中那坨 26px 的说明文字压住，页面上同时出现
	# 两份"按 Enter 出击"。
	var title_page: bool = state == "title"
	_title_ui.visible = title_page
	_title_l.visible = not title_page
	# 标题页自带左侧渐变，全屏遮罩只留一点压高光；其余界面仍用 0.45，
	# 让居中文字压在背景图上读得清。
	if _scrim != null:
		_scrim.color.a = 0.16 if title_page else 0.45

	# 选车界面走另一套排版：居中那一坨文字排不下转台与属性卡，两者互斥显示
	var garage: bool = state == "select"
	_menu_l.visible = not garage and not title_page
	_select_l.visible = garage
	_preview_tex.visible = garage
	_card.visible = garage
	_preview_vp.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if garage else SubViewport.UPDATE_DISABLED)
	if title_page:
		_layout_title()
	elif garage:
		_layout_garage()
	else:
		_title_l.add_theme_font_size_override("font_size", GARAGE_TITLE_FS_TALL)
		_title_l.offset_top = GARAGE_TITLE_TOP_TALL
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


## 可见区域变了（窗口缩放 / 界面缩放）就重排当前开着的菜单。
## 车库与标题页不做重排会保留旧坐标，暂停菜单则会保留旧字号。
func _relayout_menu() -> void:
	if _menu == null or not _menu.visible:
		return
	match state:
		"title":
			_layout_title()
		"select":
			_layout_garage()
		_:
			if _menu_l.visible:
				_fit_menu_text()


func _hide_menu() -> void:
	_menu.visible = false
	# 关掉转台渲染：它在菜单不可见时应彻底不工作
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


## 车库的两栏布局。位置按当前可见区域的尺寸算，而不是写死 1920x1080——
## 项目用 stretch/aspect=expand，超宽屏下可见区域比设计空间更宽，
## 写死的坐标会把右栏推到屏幕外。
##
## 标题带在这一档高度下先定下来：高屏沿用老构图（62px / y=90），矮屏换成紧凑档
## （40px / y=24）。标题字号与左栏起点必须出自同一档——只改其一，标题就会压住
## 左栏的"关卡 / 地形"两行（视觉缩放 200% 时可见区 960x540，正是这一档）。
func _layout_garage() -> void:
	var vp := get_viewport().get_visible_rect().size
	var left_w := minf(560.0, vp.x * 0.34)
	var right_x := maxf(left_w + 40.0, vp.x * 0.45)
	var right_w := minf(700.0, vp.x - right_x - 60.0)

	var compact := vp.y < GARAGE_TALL_H
	var title_fs: int = GARAGE_TITLE_FS if compact else GARAGE_TITLE_FS_TALL
	var title_top: float = GARAGE_TITLE_TOP if compact else GARAGE_TITLE_TOP_TALL
	_title_l.add_theme_font_size_override("font_size", title_fs)
	_title_l.offset_top = title_top

	# 标题带的下沿：标题的字高由当前字号算出，而不是写死一个 y。
	# 界面缩放到 200% 时可见区只有 540 高，标题带多吃 20 px，左栏就少排一行。
	var title_h := ThemeDB.fallback_font.get_height(title_fs)
	var content_top := title_top + title_h + GARAGE_TITLE_GAP
	var content_h := maxf(vp.y - content_top - 24.0, 120.0)

	_select_l.position = Vector2(60.0, content_top)
	_select_l.offset_top = content_top
	_select_l.offset_bottom = content_top + content_h
	_select_l.size = Vector2(left_w, content_h)

	# 转台仍然按屏幕高度的 18% 起排，只是不允许顶到标题带里面：
	# 1080p 设计空间下 18% 是 194，本来就低于标题带，构图与改动前一致；
	# 可见区只剩 540 高时 18% 是 97，也必须让到标题带下沿。
	var preview_y := maxf(content_top, vp.y * 0.18)
	# 转台最多占右栏可用高度的 45%：属性卡要按 NEED_H 排版，转台把高度全吃掉，
	# 卡片就只能缩到读不出来的字号。1080p 下 0.52 × 700 = 364，本来就低于这条线，
	# 构图不变；矮屏上则是转台让位给数值。
	var avail_h := maxf(vp.y - preview_y - 40.0, 120.0)
	var preview_h := minf(right_w * 0.52, avail_h * 0.45)
	_preview_tex.position = Vector2(right_x, preview_y)
	_preview_tex.size = Vector2(right_w, preview_h)

	_card.position = Vector2(right_x, _preview_tex.position.y + _preview_tex.size.y + 6.0)
	_card.size = Vector2(right_w, vp.y - _card.position.y - 40.0)

	_fit_garage_text(left_w, content_h)


## 左栏字号按栏宽与栏高反算。
##
## 栏宽不是常数：界面缩放（`content_scale_factor`）把设计空间放大后，可见区域
## 反而变窄（缩放 200% 时左栏只有约 326 px）。写死一个字号必然在某档缩放下折行，
## 而 AUTOWRAP 折在词中间就读不通了。所以这里量到"最宽的一行刚好排得下"为止，
## 从设计值 20 一路收到 11。
##
## 栏高同样不是常数：标题带占掉顶部之后，15 行文字只剩约 420 px。
## 所以先收行距（8 → 0，这是可压缩的余量），收不动再缩字号（这是可读性）。
func _fit_garage_text(width: float, height: float) -> void:
	const DESIGN_FS := 20
	const MIN_FS := 11
	const SPACINGS := [8, 6, 4, 2, 0]
	var f := ThemeDB.fallback_font
	var widest := 0.0
	for rel in [true, false]:
		for line in InputSetup.controls_text(rel).split("\n"):
			widest = maxf(widest, f.get_string_size(line,
					HORIZONTAL_ALIGNMENT_LEFT, -1, DESIGN_FS).x)
	var lines := _select_l.text.split("\n").size()
	var fs := DESIGN_FS
	while fs >= MIN_FS:
		if widest * (float(fs) / DESIGN_FS) <= width - 8.0:
			for sp in SPACINGS:
				if lines * (f.get_height(fs) + sp) <= height:
					_select_l.add_theme_font_size_override("font_size", fs)
					_select_l.add_theme_constant_override("line_spacing", sp)
					return
		fs -= 1
	# 兜底：最小字号 + 零行距。宁可挤，也不能让最后几行被裁掉——
	# 被裁掉的是"返回"提示与设置项，玩家会以为按键失灵。
	_select_l.add_theme_font_size_override("font_size", MIN_FS)
	_select_l.add_theme_constant_override("line_spacing", 0)


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
