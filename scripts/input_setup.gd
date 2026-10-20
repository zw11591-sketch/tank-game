class_name InputSetup
## 运行时注册全部输入动作：键盘 + 方向键 + 手柄三套绑定集中在一处。
##
## 刻意不写进 project.godot 的 [input] 段，原因有两点：
## 一是 InputEvent 的序列化字段会随引擎版本增减，手写容易写坏项目文件；
## 二是把整张按键表放在代码里便于一眼审阅和改键。
## 由 Settings autoload 在 _ready() 中调用，早于主场景构建玩家坦克。

## 摇杆死区：低于该值的轴向输入视为未推动
const STICK_DEADZONE := 0.18

## 同一次"按下"的最小间隔（毫秒）。见 edge()。
const EDGE_LOCK_MS := 40

## 每个动作上一次被采纳的按下时刻（毫秒）
static var _edge_at: Dictionary = {}


## 边沿触发：比 Input.is_action_just_pressed() 多一道时间锁。
##
## 物理帧是 120Hz，而键鼠事件按渲染帧（通常 60Hz）到达，于是**一次按下**会在
## 连续两个物理帧里都被读成"刚刚按下"。实测（tools/ClickTrace.tscn）点一下左键，
## 玩家会打出**两发**：第一发立刻响，第二发被排队的击发（`_pending_shot`）记住，在装填完成的
## 那一帧无人按键地又响一次——玩家看到的就是"凭空多出一发炮弹飞向远处/天上"，
## 而且节奏完全对不上。切弹种、切视角受同一个问题影响更明显：连按两次等于没按，
## 表现为"Q / V 键没反应"。
##
## 40 ms 的时间锁足以吃掉这两帧（8.3 ms），而人手不可能在 40 ms 内点两下。
static func edge(action: String) -> bool:
	if not Input.is_action_just_pressed(action):
		return false
	var now := Time.get_ticks_msec()
	if now - int(_edge_at.get(action, -100000)) < EDGE_LOCK_MS:
		return false
	_edge_at[action] = now
	return true


## 标记某个动作的"这一次按下"已经被别的通道消费掉了。
##
## 玩家坦克在 `_unhandled_input()` 里直接锁存开火按下——事件有时落在两个物理帧之间，
## 只轮询 `is_action_just_pressed()` 会整下丢掉。但同一次按下在下一个物理帧还会被
## 引擎再报一次"刚按下"，于是 `edge()` 会把它当成第二次点击，排出第二发炮弹。
## 消费锁存时顺手推一下时间锁，两条通道就永远只算一次。
static func suppress(action: String) -> void:
	_edge_at[action] = Time.get_ticks_msec()


static func register() -> void:
	# ---- 驾驶（车体） ----
	_act("move_forward", [KEY_W, KEY_UP], [], [], [[JOY_AXIS_LEFT_Y, -1.0]])
	_act("move_back", [KEY_S, KEY_DOWN], [], [], [[JOY_AXIS_LEFT_Y, 1.0]])
	_act("turn_left", [KEY_A, KEY_LEFT], [], [], [[JOY_AXIS_LEFT_X, -1.0]])
	_act("turn_right", [KEY_D, KEY_RIGHT], [], [], [[JOY_AXIS_LEFT_X, 1.0]])

	# ---- 火力 ----
	_act("fire", [], [MOUSE_BUTTON_LEFT], [], [[JOY_AXIS_TRIGGER_RIGHT, 1.0]])
	_act("aim_scope", [], [MOUSE_BUTTON_RIGHT], [], [[JOY_AXIS_TRIGGER_LEFT, 1.0]])
	_act("switch_shell", [KEY_Q, KEY_1, KEY_2], [], [JOY_BUTTON_Y], [])
	_act("toggle_view", [KEY_V], [], [JOY_BUTTON_RIGHT_STICK], [])

	# ---- 战术技能 ----
	_act("boost", [KEY_SHIFT], [], [JOY_BUTTON_RIGHT_SHOULDER], [])
	_act("smoke", [KEY_SPACE], [], [JOY_BUTTON_LEFT_SHOULDER], [])

	# ---- 右摇杆转塔（鼠标之外的第二套瞄准） ----
	_act("look_left", [], [], [], [[JOY_AXIS_RIGHT_X, -1.0]])
	_act("look_right", [], [], [], [[JOY_AXIS_RIGHT_X, 1.0]])
	_act("look_up", [], [], [], [[JOY_AXIS_RIGHT_Y, -1.0]])
	_act("look_down", [], [], [], [[JOY_AXIS_RIGHT_Y, 1.0]])

	# ---- 系统 ----
	_act("pause", [KEY_ESCAPE], [], [JOY_BUTTON_START], [])
	_act("toggle_display", [KEY_F11], [], [], [])
	_act("debug_hud", [KEY_F3], [], [], [])
	_act("restart", [KEY_R], [], [JOY_BUTTON_X], [])
	_act("back_to_title", [KEY_Q], [], [JOY_BUTTON_B], [])

	_extend_menu_navigation()


## 给引擎内置的 ui_* 菜单动作补上 WASD，让菜单和驾驶用同一套手感
static func _extend_menu_navigation() -> void:
	_append("ui_up", KEY_W)
	_append("ui_down", KEY_S)
	_append("ui_left", KEY_A)
	_append("ui_right", KEY_D)


## 重建一个动作。重复调用是安全的（先擦除再建），便于运行时改键。
static func _act(name: String, keys: Array, mouse: Array, pad: Array, axes: Array) -> void:
	if InputMap.has_action(name):
		InputMap.erase_action(name)
	InputMap.add_action(name, STICK_DEADZONE)

	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(name, e)

	for b in mouse:
		var e := InputEventMouseButton.new()
		e.button_index = b
		InputMap.action_add_event(name, e)

	for b in pad:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		InputMap.action_add_event(name, e)

	for a in axes:
		var e := InputEventJoypadMotion.new()
		e.axis = a[0]
		e.axis_value = a[1]
		InputMap.action_add_event(name, e)


static func _append(name: String, key: int) -> void:
	if not InputMap.has_action(name):
		return
	var e := InputEventKey.new()
	e.physical_keycode = key
	if not InputMap.action_has_event(name, e):
		InputMap.action_add_event(name, e)


## 操作说明文本，菜单与暂停界面共用。
## 驾驶那一行由调用方传入：两套操控方案下 WASD 的含义完全不同，写死会误导玩家。
## 这里刻意不直接读 Settings —— 本文件是 Settings autoload 的编译依赖，
## 在静态函数里引用该 autoload 会形成循环依赖。
##
## 两种排版，因为两个界面卡在不同的约束上：
##
##   compact = false（车库）—— 受**宽度**约束。左栏宽度受右栏起点限制不能加大，
##     超宽的一行只会被 AUTOWRAP 在**任意字符**处折断，读起来像"第一人 / 称"。
##     所以拆成 6 行短句，一行一件事，字号再由调用方按栏宽自适应。
##   compact = true（暂停、标题）—— 受**高度**约束。暂停菜单本身已有 17 行设置项，
##     多三行就把整块文字顶出画面，而它是居中 Label：排不下时上下两头一起被裁，
##     玩家看不到最下面的设置项。这几行宽度富余，所以合并成 3 行宽句。
##
## 验收手段：tools/garage_shot.gd 的 FIT 行（车库逐行量宽，超宽报 OVER）。
static func controls_text(drive_relative: bool, compact := false) -> String:
	var drive_line := "WASD 按画面方向，A/D 单独按 = 原地转车" if drive_relative \
			else "WASD / 左摇杆 前进后退 + 原地转车（履带）"
	if compact:
		return "%s    鼠标 / 右摇杆 转动炮塔    左键 / RT 开火\n" % drive_line \
			+ "右键 / LT 狙击镜    V / 右摇杆键 切换视角    Q / Y 切换弹种(AP/HE)\n" \
			+ "Shift / RB 冲刺    Space / LB 烟雾弹    Esc 暂停与设置    F11 显示模式    F3 输入诊断"
	return "%s\n" % drive_line \
		+ "鼠标 / 右摇杆 转动炮塔    左键 / RT 开火\n" \
		+ "右键 / LT 狙击镜    V / 右摇杆键 切换视角\n" \
		+ "Q / Y 切换弹种(AP/HE)    Shift / RB 冲刺\n" \
		+ "Space / LB 烟雾弹    Esc 暂停与设置\n" \
		+ "F11 显示模式    F3 输入诊断"
