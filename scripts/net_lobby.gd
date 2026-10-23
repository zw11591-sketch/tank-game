class_name NetLobby
extends Control
## 局域网大厅界面：房间列表、创建/加入、玩家列表、选车、准备与开始。
##
## 和本作其它 UI 一样，完全由代码构建，不依赖 .tscn 或 Theme。按钮负责鼠标操作，
## 键盘只需要 Esc（由 main.gd 处理）就能回到标题。

const DIFF_NAMES := ["简单", "普通", "困难"]
## 大厅面板的设计尺寸。宽屏 1080p / 100% 界面缩放下就用这个大小。
const PANEL_DESIGN := Vector2(980, 640)
## 面板与屏幕上下的最小留白。界面缩放调大后可见的 UI 空间会变小（200% 时
## 1280x720 的窗口只剩 960x540），面板必须能缩到这个范围里，否则会顶出屏幕。
const PANEL_MARGIN := 16.0

var game: Node
var _panel: PanelContainer
var _browse: Control
var _room: Control
var _rooms_box: VBoxContainer
var _status: Label
var _manual_ip: LineEdit
var _room_info: Label
var _players_l: Label
var _tank_btn: Button
var _ready_btn: Button
var _start_btn: Button
var _host_opts: Label
var _stage_btn: Button
var _terrain_btn: Button
var _diff_btn: Button
var _refresh_btn: Button


func _ready() -> void:
	# 必须是 set_anchors_and_offsets_preset：set_anchors_preset 只改锚点，
	# 同时会把偏移改成"维持当前矩形"，而在 _ready 里当前矩形还是 0x0，
	# 于是偏移变成 (0,0,-宽,-高)，覆盖层永远 0x0。面板按 0x0 的父级居中，
	# 结果整块面板的左上角落在屏幕原点、右下角落在屏幕中心，
	# 玩家只看到右下角那一块（就是"点了 L 只有半块黑底 + 手动加入一行"）。
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
	_status.text = ""
	_show_browse()
	if not Net.is_multiplayer():
		Net.discovery.start_listen(Settings.discovery_port)
	_refresh_rooms()


func close() -> void:
	visible = false


func _build() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.035, 0.05, 0.92)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var panel := PanelContainer.new()
	_panel = panel
	# 只给一个很宽松的最小尺寸：真正的尺寸由 _fit_panel() 按可见 UI 空间算，
	# 内容更高更宽时 PanelContainer 自己会撑开（说明空间真的不够，而不是排版错）。
	panel.custom_minimum_size = Vector2(320, 240)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.085, 0.11, 0.96)
	style.border_color = Color(0.32, 0.58, 0.62, 0.85)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var title := Label.new()
	title.text = "局 域 网 联 机"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.34))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 8)
	root.add_child(title)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color(0.65, 0.85, 0.9))
	root.add_child(_status)

	_browse = VBoxContainer.new()
	_browse.add_theme_constant_override("separation", 8)
	# 让房间列表吃掉面板剩下的高度：面板在小屏幕上被压矮时，
	# 列表区域自己收缩，而不是把下面的"手动加入"那一行挤出面板。
	_browse.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_browse)
	_build_browse(_browse)

	_room = VBoxContainer.new()
	_room.add_theme_constant_override("separation", 10)
	_room.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_room.visible = false
	root.add_child(_room)
	_build_room(_room)


## 把面板居中放进当前可见的 UI 空间，并且不超过设计尺寸。
##
## 可见空间不是窗口像素：stretch 用 canvas_items + content_scale_factor，
## 200% 界面缩放下 1280x720 的窗口只有 960x540 的 UI 空间，固定的 980x640
## 会顶出屏幕。这里每次打开/每次窗口尺寸或界面缩放变化都重新量一次。
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


func _build_browse(parent: Control) -> void:
	var hint := Label.new()
	hint.text = "同一网段内自动发现房间；若列表为空，可直接输入房主 IP。"
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.72, 0.78, 0.85))
	parent.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 170)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	_rooms_box = VBoxContainer.new()
	_rooms_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_rooms_box)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_refresh_btn = _button(row, "刷新列表")
	_refresh_btn.pressed.connect(func() -> void:
		Net.discovery.probe()
		_refresh_rooms())
	_button(row, "创建房间").pressed.connect(_on_create)
	var button_back := _button(row, "返回标题")
	button_back.pressed.connect(func() -> void:
		close()
		if game != null:
			game.enter_title())

	var manual := HBoxContainer.new()
	manual.add_theme_constant_override("separation", 8)
	parent.add_child(manual)
	_manual_ip = LineEdit.new()
	_manual_ip.placeholder_text = "房主 IP，例如 192.168.1.23"
	_manual_ip.text = Settings.last_server
	_manual_ip.custom_minimum_size = Vector2(420, 34)
	_manual_ip.add_theme_font_size_override("font_size", 17)
	manual.add_child(_manual_ip)
	var join_btn := _button(manual, "手动加入")
	join_btn.pressed.connect(_on_manual_join)
	var tip := Label.new()
	tip.text = "端口 %d（可在设置文件里改）" % Settings.net_port
	tip.add_theme_font_size_override("font_size", 13)
	tip.add_theme_color_override("font_color", Color(0.55, 0.62, 0.7))
	manual.add_child(tip)


func _build_room(parent: Control) -> void:
	_room_info = Label.new()
	_room_info.add_theme_font_size_override("font_size", 17)
	_room_info.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	parent.add_child(_room_info)

	_players_l = Label.new()
	# 4 人各一行约 24px，160 够用；再高就会把 200% 界面缩放下的面板顶高，
	# 面板一高就会贴到屏幕下沿。
	_players_l.custom_minimum_size = Vector2(0, 160)
	_players_l.add_theme_font_size_override("font_size", 19)
	_players_l.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_players_l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_players_l.add_theme_constant_override("outline_size", 4)
	parent.add_child(_players_l)

	_tank_btn = _button(parent, "切换战车")
	_tank_btn.pressed.connect(_on_cycle_tank)

	_host_opts = Label.new()
	_host_opts.add_theme_font_size_override("font_size", 15)
	_host_opts.add_theme_color_override("font_color", Color(0.75, 0.82, 0.9))
	parent.add_child(_host_opts)

	var opts := HBoxContainer.new()
	opts.add_theme_constant_override("separation", 8)
	parent.add_child(opts)
	_stage_btn = _button(opts, "关卡")
	_stage_btn.pressed.connect(func() -> void:
		Net.set_room(posmod(Net.room_stage, 8) + 1, Net.room_terrain, Net.room_difficulty))
	_terrain_btn = _button(opts, "地形")
	_terrain_btn.pressed.connect(func() -> void:
		var n: int = Arena.TERRAINS.size() + 1
		var t: int = posmod(Net.room_terrain + 2, n) - 1
		Net.set_room(Net.room_stage, t, Net.room_difficulty))
	_diff_btn = _button(opts, "难度")
	_diff_btn.pressed.connect(func() -> void:
		Net.set_room(Net.room_stage, Net.room_terrain, posmod(Net.room_difficulty + 1, 3)))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	parent.add_child(actions)
	_ready_btn = _button(actions, "准备")
	_ready_btn.pressed.connect(func() -> void:
		var row: Dictionary = Net.my_row()
		Net.set_ready(not bool(row.get("ready", false))))
	_start_btn = _button(actions, "开始战斗")
	_start_btn.pressed.connect(func() -> void:
		Net.start_match())
	_button(actions, "离开房间").pressed.connect(_on_leave)


func _button(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(150, 36)
	b.add_theme_font_size_override("font_size", 17)
	parent.add_child(b)
	return b


func _show_browse() -> void:
	_browse.visible = true
	_room.visible = false
	if not Net.is_multiplayer():
		Net.discovery.start_listen(Settings.discovery_port)
	_refresh_rooms()


func _show_room() -> void:
	_browse.visible = false
	_room.visible = true
	_refresh_room()


func _on_rooms_changed(rooms: Array) -> void:
	if not visible or not _browse.visible:
		return
	_refresh_rooms(rooms)


func _refresh_rooms(rooms := []) -> void:
	if _rooms_box == null:
		return
	if rooms.is_empty():
		rooms = Net.discovery.get_rooms()
	for c in _rooms_box.get_children():
		c.queue_free()
	if rooms.is_empty():
		var empty := Label.new()
		empty.text = "（暂未发现房间。确认在同一网段，或直接输入房主 IP）"
		empty.add_theme_font_size_override("font_size", 15)
		empty.add_theme_color_override("font_color", Color(0.55, 0.62, 0.7))
		_rooms_box.add_child(empty)
		return
	for r in rooms:
		var b := Button.new()
		var diff: int = clampi(int(r.get("diff", 1)), 0, 2)
		# 构建号不一致的房间直接置灰：握手阶段也会拒绝，但让玩家在点击之前
		# 就知道"不是网络问题，是两边版本不一样"。
		var same_build: bool = String(r.get("build", "")) == Net.game_build()
		b.text = "%s    %d/%d 人    关卡 %d · %s    %s%s" % [
			String(r.get("name", "房间")), int(r.get("players", 1)), int(r.get("max", 4)),
			int(r.get("stage", 1)), DIFF_NAMES[diff], String(r.get("ip", "")),
			"" if same_build else "    （版本不同）",
		]
		b.disabled = not same_build
		b.custom_minimum_size = Vector2(0, 36)
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(_on_join_room.bind(String(r.get("ip", "")), int(r.get("port", 0))))
		_rooms_box.add_child(b)


func _on_create() -> void:
	if Net.host_room("%s的房间" % Net.my_name()):
		_show_room()


## 命令行 --host：直接建房并停在大厅房间页。
func host_from_cmdline() -> void:
	if Net.host_room(""):
		_show_room()


## 命令行 --join=IP：跳过房间列表直接连。
func join_from_cmdline(ip: String) -> void:
	Settings.last_server = ip
	Net.join_room(ip)
	_show_room()


func _on_join_room(ip: String, port: int) -> void:
	if ip.is_empty():
		return
	Settings.last_server = ip
	Settings.save_cfg()
	Net.join_room(ip, port)
	_show_room()


func _on_manual_join() -> void:
	var ip := _manual_ip.text.strip_edges()
	if ip.is_empty():
		_status.text = "请输入房主 IP"
		return
	Settings.last_server = ip
	Settings.save_cfg()
	Net.join_room(ip)
	_show_room()


func _on_leave() -> void:
	Net.leave()
	_show_browse()
	_status.text = "已离开房间"


func _on_session_ended(reason: String) -> void:
	_status.text = reason
	_show_browse()


func _on_notice(text: String) -> void:
	_status.text = text


func _on_cycle_tank() -> void:
	var idx := TankRoster.ORDER.find(Settings.selected_tank)
	idx = posmod((0 if idx < 0 else idx) + 1, TankRoster.ORDER.size())
	Net.set_tank(TankRoster.ORDER[idx])


func _refresh_room() -> void:
	if _room == null:
		return
	var host := Net.is_host()
	var players: Array = Net.get_players_array()
	if players.is_empty():
		return
	var terrain_txt := "随机"
	if Net.room_terrain >= 0 and Net.room_terrain < Arena.TERRAINS.size():
		terrain_txt = String(Arena.TERRAINS[Net.room_terrain]["name"])
	_room_info.text = "房间：%s    %d/%d 人    关卡 %d · %s · %s" % [
		Net.room_name, players.size(), Settings.net_max_players, Net.room_stage,
		terrain_txt, DIFF_NAMES[clampi(Net.room_difficulty, 0, 2)],
	]
	var lines: Array = []
	for p in players:
		var pid := int(p.get("pid", 0))
		var mark := "房主" if pid == 1 else ("已准备" if bool(p.get("ready", false)) else "未准备")
		var self_mark := "  ←你" if pid == Net.local_pid() else ""
		lines.append("%s  %-14s  %-8s  %s%s" % [
			"[房主]" if pid == 1 else "[玩家]",
			String(p.get("name", "玩家")),
			_tank_name(String(p.get("tank_id", ""))),
			mark, self_mark,
		])
	_players_l.text = "\n".join(lines)
	var mine: Dictionary = Net.my_row()
	_tank_btn.text = "我的战车：%s" % _tank_name(String(mine.get("tank_id", "")))
	_ready_btn.text = "取消准备" if bool(mine.get("ready", false)) else "准备"
	_ready_btn.visible = not host
	_start_btn.visible = host
	_host_opts.visible = host
	_stage_btn.visible = host
	_terrain_btn.visible = host
	_diff_btn.visible = host
	if host:
		_stage_btn.text = "关卡 %d" % Net.room_stage
		_terrain_btn.text = "地形 %s" % ("随机" if Net.room_terrain < 0 \
				else String(Arena.TERRAINS[Net.room_terrain]["name"]))
		_diff_btn.text = "难度 %s" % DIFF_NAMES[clampi(Net.room_difficulty, 0, 2)]
		var waiting := 0
		for p in players:
			if int(p.get("pid", 0)) != 1 and not bool(p.get("ready", false)):
				waiting += 1
		_host_opts.text = "所有人已准备，可以开始" if waiting == 0 \
				else "还有 %d 名玩家未准备（房主也可以直接开始）" % waiting


func _tank_name(id: String) -> String:
	if not TankRoster.has(id):
		return "默认"
	return String(TankRoster.spec(id).get("name", id))
