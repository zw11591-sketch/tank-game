class_name NetLobby
extends Control
## 局域网大厅：找房间 / 建房、房间内准备与开始。
##
## 排版按"一屏一个决定"来分：
##   · 加入页：左半屏是「加入房间」列表，右半屏并排两张操作卡——「创建房间」
##     与「手动加入」。这条路/那条路各自成块，玩家不必在一排按钮里猜自己该点哪个。
##   · 房间页：左边是玩家与准备状态（谁还没准备一眼可见），右边是房间规则
##     （房主可改）与自己的战车，底部只放一个主操作：准备 / 开始战斗。
##
## 全屏只有一个面板：界面缩放 200% 时可见 UI 空间只有 960x540，
## 所有尺寸都按这个下限倒推（见 _fit_panel），不会再顶出屏幕。
##
## 和本作其它 UI 一样，完全由代码构建，不依赖 .tscn 或 Theme。鼠标负责所有按钮，
## 键盘只需要 Esc（由 main.gd 处理）就能回标题。

const DIFF_NAMES := ["简单", "普通", "困难"]
## 大厅面板的设计尺寸。1080p + 100% 界面缩放下就是这个大小。
const PANEL_DESIGN := Vector2(980, 640)
## 面板与屏幕边缘的最小留白。
const PANEL_MARGIN := 16.0
## 加入页右侧操作卡与房间页右栏的固定宽度。左栏随面板伸缩。
const RAIL_W := 296.0

# ---- 配色：和标题 / HUD 共用一套，金色标题 + 青色强调 ----
const COL_GOLD := Color(1.0, 0.86, 0.34)
const COL_TEXT := Color(0.93, 0.96, 1.0)
const COL_MUTED := Color(0.58, 0.66, 0.75)
const COL_DIM := Color(0.42, 0.48, 0.55)
const COL_ACCENT := Color(0.55, 0.86, 0.92)
const COL_OK := Color(0.52, 1.0, 0.64)
## 未准备 / 连接中：橙色。它和"已准备"的绿色成对出现，
## 房主扫一眼就能在玩家列表里找到还没点头的人。
const COL_WARN := Color(1.0, 0.74, 0.38)
const COL_EDGE := Color(0.24, 0.34, 0.40)

## 按钮语气。主操作（创建 / 开始）用青色实心，已准备用绿色，
## 其余是深色描边；玩家不必读字就能分出"该点哪个"。
enum Tone { PLAIN, PRIMARY, OK }

var game: Node
var _panel: PanelContainer
var _status: Label
## 状态行当前的消息。空串时显示当前页面的常驻信息（本机 IP / 已连接地址），
## 于是这一行永远有用，不会白占着。
var _status_msg := ""

# ---- 加入页 ----
var _browse: Control
var _rooms_frame: PanelContainer
var _rooms_scroll: ScrollContainer
var _rooms_box: VBoxContainer
var _empty_box: PanelContainer
var _rooms_count_l: Label
var _manual_ip: LineEdit
## 上一次渲染房间列表用的指纹。发现服务每 0.25 秒就可能推送一次，
## 内容没变就不重建按钮，免得鼠标悬停 / 焦点被反复打断。
var _rooms_sig := ""

# ---- 房间页 ----
var _room: Control
var _room_name_l: Label
var _room_meta_l: Label
## 角色标签：房主 / 已连接 / 连接中。
var _role_l: Label
var _players_box: VBoxContainer
var _player_count_l: Label
var _settings_title: Label
## 三行房间设置（关卡 / 地形 / 难度）：[{prev, value, next}]
var _opt_rows: Array = []
var _tank_value: Label
var _invite_title: Label
var _invite_hint: Label
var _invite_addr: Label
var _addr_row: HBoxContainer
var _copy_btn: Button
var _action_hint: Label
var _ready_btn: Button
var _start_btn: Button


func _ready() -> void:
	# 必须是 set_anchors_and_offsets_preset：set_anchors_preset 只改锚点，
	# 同时会把偏移改成"维持当前矩形"，而在 _ready 里当前矩形还是 0x0，
	# 于是偏移变成 (0,0,-宽,-高)，覆盖层永远 0x0（面板会跑到屏幕左上角外）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_fit_panel()
	get_viewport().size_changed.connect(_fit_panel)
	visible = false
	Net.roster_changed.connect(_refresh_room)
	Net.notice.connect(_on_notice)
	Net.session_ended.connect(_on_session_ended)
	Net.discovery.rooms_changed.connect(_on_rooms_changed)


func open() -> void:
	visible = true
	# 玩家可能刚在暂停菜单里改过界面缩放 / 分辨率，打开前重新量一次可见空间。
	_fit_panel()
	# 上一次会话留下的提示（"房间已创建""已离开房间"）在这里已经没有意义。
	_set_status("")
	_show_browse()


func close() -> void:
	visible = false


# ---------------- 骨架 ----------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.032, 0.045, 0.94)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(320, 240)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var style := _box(Color(0.055, 0.075, 0.10, 0.97), Color(0.32, 0.58, 0.62, 0.90), 2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 16.0
	style.content_margin_bottom = 16.0
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	_panel.add_child(root)

	# 标题行：左边固定标题，右边是状态提示（连接失败 / 已复制等）。
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	root.add_child(head)
	var title := _label(head, "局域网联机", 30, COL_GOLD)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 8)
	_status = _label(head, "", 15, COL_ACCENT, HORIZONTAL_ALIGNMENT_RIGHT)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root.add_child(_divider())

	_browse = VBoxContainer.new()
	_browse.add_theme_constant_override("separation", 8)
	_browse.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_browse)
	_build_browse(_browse)

	_room = VBoxContainer.new()
	_room.add_theme_constant_override("separation", 8)
	_room.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_room.visible = false
	root.add_child(_room)
	_build_room(_room)


## 把面板居中放进当前可见的 UI 空间，并且不超过设计尺寸。
##
## 可见空间不是窗口像素：stretch 用 canvas_items + content_scale_factor，
## 200% 界面缩放下 1280x720 的窗口只有 960x540 的 UI 空间。固定的 980x640
## 会顶出屏幕，所以这里每次打开 / 每次窗口或缩放变化都重新量一次。
func _fit_panel() -> void:
	if _panel == null:
		return
	var avail := get_viewport_rect().size
	var w: float = minf(PANEL_DESIGN.x, maxf(avail.x - PANEL_MARGIN * 2.0, 320.0))
	var h: float = minf(PANEL_DESIGN.y, maxf(avail.y - PANEL_MARGIN * 2.0, 240.0))
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -w * 0.5
	_panel.offset_top = -h * 0.5
	_panel.offset_right = w * 0.5
	_panel.offset_bottom = h * 0.5


# ---------------- 加入页 ----------------

func _build_browse(parent: Control) -> void:
	# 左右两栏：左边"加入"，右边"创建 / 手动"。两条路物理上分开，
	# 玩家不用先判断自己该当房主还是当客户端。
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(cols)

	# ---- 左栏：加入房间列表 ----
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left)

	var lh := HBoxContainer.new()
	lh.add_theme_constant_override("separation", 8)
	left.add_child(lh)
	_section(lh, "加入房间")
	# 房间数量紧跟标题，于是"列表是空的"这件事在标题行就能读出来。
	_rooms_count_l = _label(lh, "", 13, COL_MUTED)
	_rooms_count_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var refresh := _button(lh, "刷新", Tone.PLAIN, 62)
	refresh.custom_minimum_size.y = 26
	refresh.add_theme_font_size_override("font_size", 14)
	refresh.pressed.connect(_rescan)

	var frame := PanelContainer.new()
	_rooms_frame = frame
	frame.add_theme_stylebox_override("panel",
			_box(Color(0.040, 0.052, 0.068), COL_EDGE))
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(frame)

	_rooms_scroll = ScrollContainer.new()
	_rooms_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(_rooms_scroll)
	_rooms_box = VBoxContainer.new()
	_rooms_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_box.add_theme_constant_override("separation", 6)
	_rooms_scroll.add_child(_rooms_box)

	# 空列表时占位的是整块说明，而不是滚动区里的一行小字：宁可说清楚怎么解决，
	# 也不要让玩家对着一片空白猜。它和列表同一个位置，二选一显示。
	_empty_box = PanelContainer.new()
	_empty_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_box.add_theme_stylebox_override("panel",
			_box(Color(0.040, 0.052, 0.068), COL_EDGE))
	left.add_child(_empty_box)
	var ec := VBoxContainer.new()
	ec.alignment = BoxContainer.ALIGNMENT_CENTER
	ec.add_theme_constant_override("separation", 10)
	_empty_box.add_child(ec)
	_label(ec, "没有发现房间", 19, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	var tip := _label(ec,
			"确认两台机器连的是同一个 WiFi / 交换机\n"
			+ "或让房主在右侧创建房间，再把 IP 填进「手动加入」",
			13, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var rescan := _button(ec, "重新扫描", Tone.PLAIN, 110)
	rescan.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	rescan.pressed.connect(_rescan)

	# ---- 右栏：创建房间 + 手动加入 ----
	var rail := VBoxContainer.new()
	rail.add_theme_constant_override("separation", 10)
	rail.custom_minimum_size = Vector2(RAIL_W, 0)
	rail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(rail)

	var create_col := _card(rail)
	_section(create_col, "创建房间")
	var create_tip := _label(create_col,
			"由你当房主：关卡、地形与难度都由你决定。\n"
			+ "同一 WiFi 下的队友会自动看到这个房间。",
			13, COL_MUTED)
	create_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var create_btn := _button(create_col, "＋ 创建房间", Tone.PRIMARY)
	create_btn.custom_minimum_size.y = 38
	create_btn.pressed.connect(_on_create)

	var manual_col := _card(rail)
	_section(manual_col, "手动加入")
	var manual_tip := _label(manual_col, "列表里没看到房间？输入房主的 IP 直连。",
			13, COL_MUTED)
	manual_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_manual_ip = LineEdit.new()
	_manual_ip.placeholder_text = "房主 IP，例如 192.168.1.23"
	_manual_ip.text = Settings.last_server
	_manual_ip.custom_minimum_size = Vector2(0, 34)
	_manual_ip.add_theme_font_size_override("font_size", 16)
	_manual_ip.add_theme_color_override("font_color", COL_TEXT)
	_manual_ip.add_theme_color_override("font_placeholder_color", COL_DIM)
	_manual_ip.add_theme_stylebox_override("normal", _input_box(COL_EDGE))
	_manual_ip.add_theme_stylebox_override("focus", _input_box(COL_ACCENT))
	_manual_ip.text_submitted.connect(func(_t: String) -> void: _on_manual_join())
	manual_col.add_child(_manual_ip)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	manual_col.add_child(join_row)
	var join_btn := _button(join_row, "连接", Tone.PLAIN)
	join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_btn.custom_minimum_size.y = 34
	join_btn.pressed.connect(_on_manual_join)
	var port_l := _label(join_row, "端口 %d" % Settings.net_port, 12, COL_DIM)
	port_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	rail.add_child(_spacer())

	# ---- 底部：只留"回去" ----
	parent.add_child(_divider())
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	parent.add_child(foot)
	var back := _button(foot, "← 返回标题", Tone.PLAIN, 132)
	back.pressed.connect(func() -> void:
		close()
		if game != null:
			game.enter_title())
	var esc := _label(foot, "Esc 也可以返回标题", 12, COL_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	esc.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 房间卡片：整块可点，右侧另有明确的「加入」按钮作为视觉落点。
## 文字层全部忽略鼠标，于是点击一定落到整卡按钮上。
## 不能加入时，右侧按钮换成原因（已满 / 对局中 / 版本不同），
## 而不是把原因塞进第二行灰字里——玩家扫一眼就知道为什么点不动。
func _room_card(r: Dictionary) -> void:
	var ip := String(r.get("ip", ""))
	var port := int(r.get("port", Settings.net_port))
	var max_n := maxi(1, int(r.get("max", 4)))
	var have := int(r.get("players", 1))
	var same_build: bool = String(r.get("build", "")) == Net.game_build()
	var playing := bool(r.get("active", false))
	var full := have >= max_n
	var joinable := same_build and not playing and not full

	var b := _button(_rooms_box, "", Tone.PLAIN)
	b.custom_minimum_size = Vector2(0, 58)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = not joinable
	if joinable:
		# 可加入的房间底色略微提亮，一眼能和在打的 / 版本不同的房间区分开。
		var bg := Color(0.10, 0.135, 0.175)
		var bd := Color(0.30, 0.46, 0.52)
		b.add_theme_stylebox_override("normal", _box(bg, bd))
		b.add_theme_stylebox_override("hover", _box(bg.lightened(0.10), bd.lightened(0.18)))
		b.add_theme_stylebox_override("pressed", _box(bg.darkened(0.12), bd))
		b.pressed.connect(_on_join_room.bind(ip, port))

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 12)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_top", 7)
	pad.add_theme_constant_override("margin_bottom", 7)
	b.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(row)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 1)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(left)
	var name_l := _label(left, String(r.get("name", "房间")), 17,
			COL_TEXT if joinable else COL_DIM)
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var diff: int = clampi(int(r.get("diff", 1)), 0, 2)
	_label(left, "第 %d 关 · %s · %s" % [int(r.get("stage", 1)), DIFF_NAMES[diff], ip],
			13, COL_MUTED if joinable else COL_DIM)

	var count := _label(row, "%d/%d 人" % [have, max_n], 15,
			COL_TEXT if joinable else COL_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count.custom_minimum_size = Vector2(56, 0)

	var reason := ""
	if not same_build:
		reason = "版本不同"
	elif playing:
		reason = "对局中"
	elif full:
		reason = "已满"
	if joinable:
		var pill := _pill(row, "加入 →", Color(0.98, 1.0, 1.0),
				Color(0.12, 0.40, 0.45), Color(0.42, 0.82, 0.88), 14)
		pill.custom_minimum_size = Vector2(76, 28)
		pill.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	else:
		var pill := _pill(row, reason, COL_DIM,
				Color(0.075, 0.09, 0.11), Color(0.18, 0.23, 0.28), 13)
		pill.custom_minimum_size = Vector2(76, 28)
		pill.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER


# ---------------- 房间页 ----------------

func _build_room(parent: Control) -> void:
	# 房名 + 身份 + 规则摘要。房主改设置后这一行立刻变化，客户端也看得到。
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	parent.add_child(top)
	_room_name_l = _label(top, "", 21, COL_TEXT)
	_room_name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_role_l = _pill(top, "房主", COL_GOLD, COL_GOLD.darkened(0.78),
			COL_GOLD.darkened(0.45), 13)
	_role_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_role_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_room_meta_l = _label(top, "", 13, COL_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(cols)

	# ---- 左栏：玩家 ----
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left)
	var left_head := HBoxContainer.new()
	left_head.add_theme_constant_override("separation", 8)
	left.add_child(left_head)
	_section(left_head, "玩家")
	# 人数紧跟"玩家"而不是甩到右栏边上：不然它看着像"房间设置"的标题。
	_player_count_l = _label(left_head, "", 13, COL_MUTED)
	_player_count_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 6)
	left.add_child(_players_box)

	# 加入方式 / 连接状态紧跟在玩家列表下面：它讲的就是"屋里还有谁、怎么再来人"。
	# 房主随时能念出这个地址，客户端也能确认自己连的是哪台机器。
	var invite := PanelContainer.new()
	invite.add_theme_stylebox_override("panel",
			_box(Color(0.06, 0.082, 0.105), Color(0.20, 0.30, 0.36)))
	left.add_child(invite)
	var invite_col := VBoxContainer.new()
	invite_col.add_theme_constant_override("separation", 4)
	invite.add_child(invite_col)
	_invite_title = _section(invite_col, "队友加入")
	_invite_hint = _label(invite_col, "", 13, COL_MUTED)
	_invite_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var addr_row := HBoxContainer.new()
	_addr_row = addr_row
	addr_row.add_theme_constant_override("separation", 8)
	invite_col.add_child(addr_row)
	_invite_addr = _label(addr_row, "", 16, COL_ACCENT)
	_invite_addr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_invite_addr.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_copy_btn = _button(addr_row, "复制地址", Tone.PLAIN, 92)
	_copy_btn.custom_minimum_size.y = 26
	_copy_btn.add_theme_font_size_override("font_size", 13)
	_copy_btn.pressed.connect(_on_copy_addr)

	# 玩家列表与"队友加入"贴在一起：它们讲的都是"这屋里现在有谁、怎么再来人"。
	# 留白统一压到最底下，而不是插在两块相关内容之间。
	left.add_child(_spacer())

	# ---- 右栏：房间规则 + 我的战车 ----
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.custom_minimum_size = Vector2(RAIL_W, 0)
	cols.add_child(right)

	var set_col := _card(right)
	_settings_title = _section(set_col, "房间设置")
	_opt_rows.clear()
	_opt_rows.append(_option_row(set_col, "关卡"))
	_opt_rows.append(_option_row(set_col, "地形"))
	_opt_rows.append(_option_row(set_col, "难度"))
	(_opt_rows[0]["prev"] as Button).pressed.connect(func() -> void:
		Net.set_room(posmod(Net.room_stage - 2, 8) + 1, Net.room_terrain, Net.room_difficulty))
	(_opt_rows[0]["next"] as Button).pressed.connect(func() -> void:
		Net.set_room(posmod(Net.room_stage, 8) + 1, Net.room_terrain, Net.room_difficulty))
	(_opt_rows[1]["prev"] as Button).pressed.connect(func() -> void:
		var n: int = Arena.TERRAINS.size() + 1
		Net.set_room(Net.room_stage, posmod(Net.room_terrain + n - 1, n) - 1, Net.room_difficulty))
	(_opt_rows[1]["next"] as Button).pressed.connect(func() -> void:
		var n: int = Arena.TERRAINS.size() + 1
		Net.set_room(Net.room_stage, posmod(Net.room_terrain + 2, n) - 1, Net.room_difficulty))
	(_opt_rows[2]["prev"] as Button).pressed.connect(func() -> void:
		Net.set_room(Net.room_stage, Net.room_terrain, posmod(Net.room_difficulty + 2, 3)))
	(_opt_rows[2]["next"] as Button).pressed.connect(func() -> void:
		Net.set_room(Net.room_stage, Net.room_terrain, posmod(Net.room_difficulty + 1, 3)))

	var tank_col := _card(right)
	_section(tank_col, "我的战车")
	var tank_row := HBoxContainer.new()
	tank_row.add_theme_constant_override("separation", 6)
	tank_col.add_child(tank_row)
	var tank_prev := _small_button(tank_row, "◀")
	_tank_value = _label(tank_row, "", 16, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_tank_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tank_next := _small_button(tank_row, "▶")
	tank_prev.pressed.connect(_on_cycle_tank.bind(-1))
	tank_next.pressed.connect(_on_cycle_tank.bind(1))
	_label(tank_col, "开战前随时可换，只有你自己看得见", 12, COL_DIM)

	right.add_child(_spacer())

	parent.add_child(_divider())

	# 底部只留一个主操作。房主是"开始战斗"，客户端是"准备"。
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	parent.add_child(foot)
	var leave := _button(foot, "离开房间", Tone.PLAIN, 128)
	leave.custom_minimum_size.y = 38
	leave.pressed.connect(_on_leave)
	_action_hint = _label(foot, "", 13, COL_MUTED)
	_action_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_ready_btn = _button(foot, "准备", Tone.PRIMARY, 180)
	_ready_btn.custom_minimum_size.y = 38
	_ready_btn.pressed.connect(func() -> void:
		var row: Dictionary = Net.my_row()
		Net.set_ready(not bool(row.get("ready", false))))
	_start_btn = _button(foot, "开始战斗", Tone.PRIMARY, 190)
	_start_btn.custom_minimum_size.y = 38
	_start_btn.pressed.connect(func() -> void: Net.start_match())


## 一行房间设置：左标签 + ◀ 值 ▶。非房主隐藏箭头，只读展示。
func _option_row(parent: Control, title: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var name_l := _label(row, title, 14, COL_MUTED)
	name_l.custom_minimum_size = Vector2(44, 0)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var prev := _small_button(row, "◀")
	# 值不参与撑宽，◀ 值 ▶ 才会贴在一起形成一组；否则右栏一宽，
	# 箭头就被推到两端，玩家会以为它们属于两件不同的事。
	var value := _label(row, "", 15, COL_TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	value.custom_minimum_size = Vector2(108, 0)
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var next := _small_button(row, "▶")
	return {"prev": prev, "value": value, "next": next}


# ---------------- 通用小部件 ----------------

## 统一的圆角底：按钮、卡片、空态框都用它，保证一套视觉语言。
func _box(bg: Color, border: Color, width := 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(4)
	s.content_margin_left = 10.0
	s.content_margin_right = 10.0
	s.content_margin_top = 5.0
	s.content_margin_bottom = 5.0
	return s


## 输入框底：和按钮同一套深色 + 描边，聚焦时换成青色边。
func _input_box(border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.07, 0.09, 0.115)
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 10.0
	s.content_margin_right = 10.0
	s.content_margin_top = 4.0
	s.content_margin_bottom = 4.0
	return s


## 分组卡片：房间页右栏与加入页右栏共用，比裸控件更像"一档设置"。
func _card(parent: Control) -> VBoxContainer:
	var p := PanelContainer.new()
	var s := _box(Color(0.062, 0.082, 0.105, 1.0), Color(0.20, 0.28, 0.34))
	s.set_corner_radius_all(5)
	s.content_margin_left = 10.0
	s.content_margin_right = 10.0
	s.content_margin_top = 8.0
	s.content_margin_bottom = 8.0
	p.add_theme_stylebox_override("panel", s)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(p)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	p.add_child(col)
	return col


func _button(parent: Control, text: String, tone := Tone.PLAIN, min_w := 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 34)
	b.add_theme_font_size_override("font_size", 17)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	parent.add_child(b)
	_style_button(b, tone)
	return b


## 按钮换语气：主操作 / 已准备 / 普通。准备按钮会在"已准备"时切成绿色，
## 于是"我现在到底准备没准备"不必再读一遍字。
func _style_button(b: Button, tone: int) -> void:
	var bg := Color(0.11, 0.15, 0.19)
	var bd := COL_EDGE
	var fg := COL_TEXT
	match tone:
		Tone.PRIMARY:
			bg = Color(0.12, 0.40, 0.45)
			bd = Color(0.42, 0.82, 0.88)
			fg = Color(0.97, 1.0, 1.0)
		Tone.OK:
			bg = Color(0.14, 0.34, 0.20)
			bd = Color(0.46, 0.86, 0.55)
			fg = Color(0.92, 1.0, 0.94)
	b.add_theme_stylebox_override("normal", _box(bg, bd))
	b.add_theme_stylebox_override("hover", _box(bg.lightened(0.10), bd.lightened(0.12)))
	b.add_theme_stylebox_override("pressed", _box(bg.darkened(0.18), bd))
	b.add_theme_stylebox_override("disabled", _box(
			Color(0.09, 0.11, 0.13), Color(0.17, 0.21, 0.25)))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), bd.lightened(0.35)))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.86, 0.94, 1.0))
	b.add_theme_color_override("font_disabled_color", Color(0.40, 0.45, 0.51))


func _small_button(parent: Control, text: String) -> Button:
	var b := _button(parent, text, Tone.PLAIN)
	b.custom_minimum_size = Vector2(30, 26)
	b.add_theme_font_size_override("font_size", 13)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


func _label(parent: Control, text: String, size: int, col: Color,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## 分组标题：前缀一个色块，扫一眼就知道这是哪一段。
func _section(parent: Control, text: String) -> Label:
	var l := _label(parent, "▍ " + text, 17, COL_TEXT)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("outline_size", 4)
	return l


## 胶囊标签：状态徽章、房间卡上的「加入」按钮都用它。
## 文字层忽略鼠标，于是整卡点击不会被它挡住。
func _pill(parent: Control, text: String, fg: Color, bg: Color, bd: Color,
		size := 13) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", fg)
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = bd
	s.set_border_width_all(1)
	s.set_corner_radius_all(9)
	s.content_margin_left = 9.0
	s.content_margin_right = 9.0
	s.content_margin_top = 1.0
	s.content_margin_bottom = 1.0
	l.add_theme_stylebox_override("normal", s)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(l)
	return l


## 刷新一个胶囊标签的文字与配色（房主 / 已连接 / 连接中会来回变）。
func _set_pill(l: Label, text: String, fg: Color) -> void:
	if l == null:
		return
	l.text = text
	l.add_theme_color_override("font_color", fg)
	var s := StyleBoxFlat.new()
	s.bg_color = fg.darkened(0.78)
	s.border_color = fg.darkened(0.45)
	s.set_border_width_all(1)
	s.set_corner_radius_all(9)
	s.content_margin_left = 9.0
	s.content_margin_right = 9.0
	s.content_margin_top = 1.0
	s.content_margin_bottom = 1.0
	l.add_theme_stylebox_override("normal", s)


func _badge(parent: Control, text: String, col: Color) -> Label:
	return _pill(parent, text, col, col.darkened(0.78), col.darkened(0.45))


func _divider() -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(0.20, 0.30, 0.35, 0.9)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## 竖直方向的弹性填空，把栏内内容顶到上边。
func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ---------------- 页面切换 ----------------

func _show_browse() -> void:
	_browse.visible = true
	_room.visible = false
	if not Net.is_multiplayer():
		Net.discovery.start_listen(Settings.discovery_port)
	_set_status(_status_msg)
	_refresh_rooms()


func _show_room() -> void:
	_browse.visible = false
	_room.visible = true
	_set_status(_status_msg)
	_refresh_room()


func _on_rooms_changed(rooms: Array) -> void:
	if not visible or not _browse.visible:
		return
	_refresh_rooms(rooms)


func _rescan() -> void:
	Net.discovery.probe()
	# 清掉指纹，哪怕内容恰好没变也重建一次，让"刷新"有可见的反馈。
	_rooms_sig = ""
	_refresh_rooms()


func _refresh_rooms(rooms := []) -> void:
	if _rooms_box == null:
		return
	if rooms.is_empty():
		rooms = Net.discovery.get_rooms()
	var sig := "<none>"
	if not rooms.is_empty():
		var parts: Array = []
		for r in rooms:
			parts.append("%s|%d|%d|%d|%d|%d|%s|%s|%s" % [
				String(r.get("ip", "")), int(r.get("port", 0)),
				int(r.get("players", 1)), int(r.get("max", 4)),
				int(r.get("stage", 1)), int(r.get("diff", 1)),
				String(r.get("build", "")), str(bool(r.get("active", false))),
				String(r.get("name", "")),
			])
		sig = ";".join(PackedStringArray(parts))
	if sig == _rooms_sig:
		return
	_rooms_sig = sig
	for c in _rooms_box.get_children():
		_rooms_box.remove_child(c)
		c.queue_free()
	_rooms_scroll.visible = not rooms.is_empty()
	_rooms_frame.visible = not rooms.is_empty()
	_empty_box.visible = rooms.is_empty()
	_rooms_count_l.text = "" if rooms.is_empty() else "%d 个房间" % rooms.size()
	for r in rooms:
		_room_card(r)


# ---------------- 房间页刷新 ----------------

func _refresh_room() -> void:
	if _room == null or _players_box == null:
		return
	var host := Net.is_host()
	var players: Array = Net.get_players_array()
	var diff: int = clampi(Net.room_difficulty, 0, 2)
	_room_name_l.text = Net.room_name
	_room_meta_l.text = "第 %d 关 · %s · %s" % [Net.room_stage, _terrain_name(), DIFF_NAMES[diff]]

	# 身份标签：房主金色、已连接绿色、还没接到名册时橙色"连接中"。
	if host:
		_set_pill(_role_l, "房主", COL_GOLD)
	elif players.is_empty():
		_set_pill(_role_l, "连接中", COL_WARN)
	else:
		_set_pill(_role_l, "已连接", COL_OK)

	_player_count_l.text = "%d/%d 人" % [players.size(), Settings.net_max_players]

	for c in _players_box.get_children():
		_players_box.remove_child(c)
		c.queue_free()
	if players.is_empty():
		_connecting_card()
	else:
		for p in players:
			_player_card(p)
		# 空位也画出来：一眼能看出"还有几个位置、房间是不是快满了"。
		for i in maxi(0, Settings.net_max_players - players.size()):
			_empty_player_card()

	# 房主能改设置，客户端只读；两个视图共用同一套控件，切人时面板不会跳动。
	_settings_title.text = "▍ 房间设置" if host else "▍ 房间设置（房主决定）"
	(_opt_rows[0]["value"] as Label).text = "第 %d 关" % Net.room_stage
	(_opt_rows[1]["value"] as Label).text = _terrain_name()
	(_opt_rows[2]["value"] as Label).text = DIFF_NAMES[diff]
	for r in _opt_rows:
		(r["prev"] as Button).visible = host
		(r["next"] as Button).visible = host
		var v := r["value"] as Label
		# 房主看到的是"可以左右调"的居中值；客户端看到的是只读的左对齐值，
		# 和左边的标签对齐成一张表。
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if host \
				else HORIZONTAL_ALIGNMENT_LEFT
		v.add_theme_color_override("font_color", COL_TEXT if host else COL_MUTED)

	var mine: Dictionary = Net.my_row()
	var tank_id := String(mine.get("tank_id", Settings.selected_tank))
	_tank_value.text = _tank_label(tank_id)

	# 邀请信息：房主看到的是"把队友叫进来"的地址，客户端看到的是"我连的是谁"。
	if host:
		_invite_title.text = "▍ 队友加入"
		_invite_hint.text = "同一 WiFi 下自动出现；也可让队友手动输入："
		_invite_addr.text = "%s:%d" % [_local_ip(), Settings.net_port]
		_addr_row.visible = true
		_copy_btn.visible = true
	else:
		var addr := Net.server_addr()
		_invite_title.text = "▍ 连接状态"
		if addr.is_empty():
			_invite_hint.text = "正在连接房主…"
			_invite_addr.text = ""
			_addr_row.visible = false
		elif players.is_empty():
			# 已经发出连接请求，但还没收到名册：地址先亮出来，连不上时玩家能核对。
			_invite_hint.text = "正在连接房主…"
			_invite_addr.text = "%s:%d" % [addr, Settings.net_port]
			_addr_row.visible = true
		else:
			_invite_hint.text = "已连接房主；卡顿请先确认双方在同一 WiFi。"
			_invite_addr.text = "%s:%d" % [addr, Settings.net_port]
			_addr_row.visible = true
		_copy_btn.visible = false

	var ready := bool(mine.get("ready", false))
	_ready_btn.visible = not host
	_ready_btn.text = "✓ 已准备（取消）" if ready else "准备"
	_style_button(_ready_btn, Tone.OK if ready else Tone.PRIMARY)
	_start_btn.visible = host
	if host:
		var waiting := 0
		for p in players:
			if int(p.get("pid", 0)) != 1 and not bool(p.get("ready", false)):
				waiting += 1
		if players.size() <= 1:
			_action_hint.text = "还没有队友加入；也可以直接开始（等同单机）"
		elif waiting == 0:
			_action_hint.text = "所有队友已准备，可以开始战斗"
		else:
			_action_hint.text = "还有 %d 名队友未准备，也可以直接开始" % waiting
	else:
		_action_hint.text = "已准备，等待房主开始" if ready \
				else "点右侧「准备」，让房主知道你可以开打"


func _player_card(p: Dictionary) -> void:
	var pid := int(p.get("pid", 0))
	var is_me := pid == Net.local_pid()
	var is_host := pid == 1
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 40)
	card.add_theme_stylebox_override("panel", _box(
			Color(0.085, 0.11, 0.145, 1.0) if is_me else Color(0.065, 0.085, 0.11, 1.0),
			COL_ACCENT if is_me else Color(0.19, 0.26, 0.32)))
	_players_box.add_child(card)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)

	# 车型色条：一眼把"谁开哪台车"和名字对上，同类车撞色也不影响读名字。
	var spec := TankRoster.spec(String(p.get("tank_id", "")))
	var chip := ColorRect.new()
	chip.color = spec.get("accent_color", COL_MUTED)
	chip.custom_minimum_size = Vector2(4, 0)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(chip)

	var name_txt := String(p.get("name", "玩家"))
	if is_me:
		name_txt += "（你）"
	var nm := _label(row, name_txt, 17, COL_ACCENT if is_me else COL_TEXT)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var tank_l := _label(row, _tank_label(String(p.get("tank_id", ""))), 13, COL_MUTED)
	tank_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if is_host:
		_badge(row, "房主", COL_GOLD)
	elif bool(p.get("ready", false)):
		_badge(row, "已准备", COL_OK)
	else:
		_badge(row, "未准备", COL_WARN)


## 空位占位卡：低对比度的暗底 + 灰字，不抢玩家视线。
func _empty_player_card() -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 40)
	card.add_theme_stylebox_override("panel", _box(
			Color(0.055, 0.068, 0.085, 1.0), Color(0.15, 0.20, 0.24)))
	_players_box.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	var slot_l := _label(row, "空位", 15, COL_DIM)
	slot_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(row, "等待队友加入", 12, COL_DIM, HORIZONTAL_ALIGNMENT_RIGHT)


## 客户端刚连上、名册还没到时整块占位：比一排空位更能说明"正在发生什么"。
func _connecting_card() -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 76)
	card.add_theme_stylebox_override("panel", _box(
			Color(0.055, 0.068, 0.085, 1.0), Color(0.20, 0.30, 0.36)))
	_players_box.add_child(card)
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	card.add_child(col)
	_label(col, "正在连接房主…", 16, COL_ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_label(col, "一直停在这里就检查 IP、防火墙与是否同一网段",
			12, COL_MUTED, HORIZONTAL_ALIGNMENT_CENTER)


# ---------------- 交互 ----------------

func _on_create() -> void:
	if not Net.host_room("%s的房间" % Net.my_name()):
		return
	_rooms_sig = ""
	_show_room()
	# 房名就在下面一行，标题行不必再复述"房间已创建"。
	_set_status("")


## 命令行 --host：直接建房并停在大厅房间页。
func host_from_cmdline() -> void:
	if not Net.host_room(""):
		return
	_show_room()
	_set_status("")


## 命令行 --join=IP：跳过房间列表直接连。
func join_from_cmdline(ip: String) -> void:
	Settings.last_server = ip
	if not Net.join_room(ip):
		return
	_show_room()
	_set_status("")


func _on_join_room(ip: String, port: int) -> void:
	if ip.is_empty():
		return
	Settings.last_server = ip
	Settings.save_cfg()
	if not Net.join_room(ip, port):
		return
	_show_room()
	_set_status("")


func _on_manual_join() -> void:
	var ip := _manual_ip.text.strip_edges()
	if ip.is_empty():
		_set_status("请先填入房主 IP")
		return
	Settings.last_server = ip
	Settings.save_cfg()
	if not Net.join_room(ip):
		return
	_show_room()
	_set_status("")


func _on_leave() -> void:
	Net.leave()
	_show_browse()
	_set_status("已离开房间")


func _on_session_ended(reason: String) -> void:
	_set_status(reason)
	_show_browse()


func _on_notice(text: String) -> void:
	# 房间页的房名就在标题下面，"房间已创建：xxx"再写一遍只是噪音。
	if _room != null and _room.visible and text.begins_with("房间已创建"):
		_set_status("")
		return
	_set_status(text)


func _on_copy_addr() -> void:
	var txt := _invite_addr.text.strip_edges()
	if txt.is_empty():
		return
	DisplayServer.clipboard_set(txt)
	_set_status("已复制 %s" % txt)
	_copy_btn.text = "已复制"
	await get_tree().create_timer(1.2).timeout
	if is_instance_valid(_copy_btn):
		_copy_btn.text = "复制地址"


## 状态行：有消息就显示消息，没有消息就显示当前页面的常驻信息。
## 常驻内容在局域网场景里很实用——房主能直接把它念给队友，
## 客户端能确认自己连的是哪台机器。
func _set_status(text: String) -> void:
	_status_msg = text
	if _status == null:
		return
	_status.text = text if not text.is_empty() else _status_hint()


func _status_hint() -> String:
	# 房间页把地址放在专门的"队友加入 / 连接状态"卡片里，标题行再写一遍只是噪音。
	if _room != null and _room.visible:
		return ""
	if Net.is_client():
		var addr := Net.server_addr()
		return "已连接 %s" % addr if not addr.is_empty() else ""
	return "本机 %s · 端口 %d" % [_local_ip(), Settings.net_port]


func _on_cycle_tank(dir: int) -> void:
	var id := String(Net.my_row().get("tank_id", Settings.selected_tank))
	var idx := TankRoster.ORDER.find(id)
	idx = posmod((0 if idx < 0 else idx) + dir, TankRoster.ORDER.size())
	Net.set_tank(TankRoster.ORDER[idx])


# ---------------- 小工具 ----------------

## 战车显示名带定位标签，例如"游隼 · 主战"：队友看名字时顺带知道对方是什么车。
func _tank_label(id: String) -> String:
	if not TankRoster.has(id):
		return "默认"
	var s := TankRoster.spec(id)
	return "%s · %s" % [String(s.get("name", id)), String(s.get("tag", ""))]


func _terrain_name() -> String:
	if Net.room_terrain < 0 or Net.room_terrain >= Arena.TERRAINS.size():
		return "随机地形"
	return String(Arena.TERRAINS[Net.room_terrain]["name"])


## 本机在局域网里的地址，念给队友就能手动加入。
## 按常见程度挑：192.168.x 最常见，10.x 次之，172.16~31 再次，
## 其余（Docker / WSL / VPN 的虚拟网卡）只在没有别的地址时才用。
func _local_ip() -> String:
	var cands: Array = []
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		cands.append(a)
	for prefix in ["192.168.", "10."]:
		for a in cands:
			if String(a).begins_with(prefix):
				return String(a)
	for a in cands:
		var parts := String(a).split(".")
		if parts.size() == 4 and int(parts[0]) == 172 \
				and int(parts[1]) >= 16 and int(parts[1]) <= 31:
			return String(a)
	return String(cands[0]) if not cands.is_empty() else "127.0.0.1"
