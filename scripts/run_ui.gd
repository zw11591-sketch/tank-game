class_name RunUI
extends Control
## Roguelite 覆盖层：三选一卡牌与前线补给站。
##
## 只负责"显示 + 发信号"，从不修改战斗状态。main.gd 收到信号后调用 Run 结算，
## 于是界面与规则解耦，探针也可以不建界面直接测规则。
##
## 布局按可见区域缩放：界面缩放 200% 时设计空间只有 960×540，
## 固定 330×400 的三张卡会横溢出屏，所以卡片尺寸与字号都从可用宽高反算。

signal card_picked(id: String)
signal rerolled
signal skipped
signal station_bought(index: int)
signal station_closed

const DESIGN_CARD_W := 330.0
const DESIGN_CARD_H := 400.0
const CARD_GAP := 28.0

const COL_TEXT := Color(0.94, 0.96, 1.0)
const COL_DIM := Color(0.66, 0.71, 0.78)
const COL_ACCENT := Color(1.0, 0.80, 0.35)
const COL_BAD := Color(0.95, 0.45, 0.42)
const COL_OK := Color(0.55, 0.92, 0.60)

## "" / "cards" / "station"
var mode := ""
var offer: Array[String] = []
## 补给站商品：[{name, desc, cost, sold, enabled}]
var station: Array = []
var cursor := 0
## 联机时客户端只显示、不接受输入。
var interactive := true

var head := ""
var sub := ""
var foot := ""
## 卡牌模式下显示"已持有 N 张"需要它
var credits := 0
var reroll_cost := 0

var _hover := -1
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# ---------------- 显示入口 ----------------

func show_cards(p_offer: Array, p_head: String, p_sub: String, p_credits: int,
		p_reroll_cost: int, p_interactive: bool) -> void:
	mode = "cards"
	offer.clear()
	for id in p_offer:
		offer.append(String(id))
	cursor = 0
	_hover = -1
	head = p_head
	sub = p_sub
	credits = p_credits
	reroll_cost = p_reroll_cost
	interactive = p_interactive
	_update_foot()
	visible = true
	queue_redraw()


func show_station(p_items: Array, p_head: String, p_sub: String,
		p_interactive: bool) -> void:
	mode = "station"
	station = p_items
	cursor = 0
	_hover = -1
	head = p_head
	sub = p_sub
	interactive = p_interactive
	foot = "↑↓ 选择    Enter 购买    Esc 离开" if interactive else "等待房主选择"
	visible = true
	queue_redraw()


func close() -> void:
	mode = ""
	offer.clear()
	station.clear()
	visible = false
	queue_redraw()


func refresh(p_credits: int, p_reroll_cost: int) -> void:
	credits = p_credits
	reroll_cost = p_reroll_cost
	_update_foot()
	queue_redraw()


## 补给站：购买成功后刷新商品状态与副标题。
##
## 与 refresh() 分开是因为两者更新的东西不同：卡牌模式刷新的是"战功 / 重掷价格"，
## 补给站刷新的是"商品 enabled + sold + 余额"。混用会让卡牌界面的重掷价
## 在补给站里被当成"战功"写进副标题。
func refresh_station(p_items: Array, p_sub: String) -> void:
	station = p_items
	sub = p_sub
	queue_redraw()


func _update_foot() -> void:
	if not interactive:
		foot = "等待房主选择"
		return
	foot = "←→ 选择    Enter 确认    R 重掷 %d    Esc 跳过 +%d" % [
		reroll_cost, RunState.SKIP_CREDITS,
	]


# ---------------- 输入（由 main 路由） ----------------

func move(d: int) -> void:
	if not interactive:
		return
	var n := _count()
	if n <= 0:
		return
	cursor = posmod(cursor + d, n)
	queue_redraw()


func confirm() -> void:
	if not interactive:
		return
	match mode:
		"cards":
			if cursor >= 0 and cursor < offer.size():
				card_picked.emit(offer[cursor])
		"station":
			if cursor >= 0 and cursor < station.size():
				var item: Dictionary = station[cursor]
				if bool(item.get("sold", false)) or not bool(item.get("enabled", true)):
					return
				station_bought.emit(cursor)


func reroll() -> void:
	if interactive and mode == "cards":
		rerolled.emit()


func back() -> void:
	if not interactive:
		return
	match mode:
		"cards":
			skipped.emit()
		"station":
			station_closed.emit()


func _count() -> int:
	match mode:
		"cards":
			return offer.size()
		"station":
			return station.size()
	return 0


# ---------------- 鼠标 ----------------

func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return
	if event is InputEventMouseMotion:
		var h := _hit((event as InputEventMouseMotion).position)
		if h != _hover:
			_hover = h
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var i := _hit(mb.position)
			if i >= 0:
				cursor = i
				confirm()
				accept_event()


func _hit(pos: Vector2) -> int:
	match mode:
		"cards":
			for i in offer.size():
				if _card_rect(i).has_point(pos):
					return i
		"station":
			for i in station.size():
				if _station_rect(i).has_point(pos):
					return i
	return -1


# ---------------- 布局 ----------------

## 卡牌尺寸按可用区域收缩。字号跟着卡宽等比缩放，保证 200% 界面缩放下也排得下。
func _card_size() -> Vector2:
	var w: float = minf(DESIGN_CARD_W, (size.x - 120.0 - CARD_GAP * 2.0) / 3.0)
	w = maxf(w, 150.0)
	var h: float = minf(DESIGN_CARD_H, maxf(size.y - 300.0, 220.0))
	return Vector2(w, h)


func _card_rect(i: int) -> Rect2:
	var cs := _card_size()
	var row_w: float = cs.x * 3.0 + CARD_GAP * 2.0
	var x0: float = (size.x - row_w) * 0.5
	var y0: float = maxf(size.y * 0.30, 150.0)
	return Rect2(x0 + float(i) * (cs.x + CARD_GAP), y0, cs.x, cs.y)


func _station_rect(i: int) -> Rect2:
	var w: float = minf(860.0, size.x - 120.0)
	var h := 64.0
	var x0: float = (size.x - w) * 0.5
	var y0: float = maxf(size.y * 0.34, 170.0)
	return Rect2(x0, y0 + float(i) * (h + 12.0), w, h)


# ---------------- 绘制 ----------------

func _draw() -> void:
	if mode == "":
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.02, 0.03, 0.86))
	var head_fs: int = 40 if size.x > 1400.0 else 30
	var sub_fs: int = 20 if size.x > 1400.0 else 16
	draw_string(_font, Vector2(0, 86), head, HORIZONTAL_ALIGNMENT_CENTER,
			size.x, head_fs, COL_ACCENT)
	draw_string(_font, Vector2(0, 124), sub, HORIZONTAL_ALIGNMENT_CENTER,
			size.x, sub_fs, COL_TEXT)
	draw_string(_font, Vector2(0, size.y - 46), foot, HORIZONTAL_ALIGNMENT_CENTER,
			size.x, sub_fs, COL_DIM if interactive else COL_BAD)
	match mode:
		"cards":
			_draw_cards()
		"station":
			_draw_station()


func _draw_cards() -> void:
	var cs := _card_size()
	var k: float = clampf(cs.x / DESIGN_CARD_W, 0.55, 1.0)
	var pad := 18.0 * k
	for i in offer.size():
		var id := offer[i]
		var info := UpgradeCards.info(id)
		var r := int(info["rarity"])
		var rect := _card_rect(i)
		var sel: bool = (i == cursor)
		var rar_col: Color = UpgradeCards.RARITY_COLORS[clampi(r, 0, 2)]
		var fill := Color(0.075, 0.090, 0.115, 0.98)
		if sel:
			fill = Color(0.115, 0.135, 0.170, 0.99)
		_panel(rect, fill, rar_col, 3.0 if sel else 1.5, 12.0 * k)
		# 顶部稀有度色条
		draw_rect(Rect2(rect.position + Vector2(1.0, 1.0),
				Vector2(rect.size.x - 2.0, 6.0 * k)), rar_col)

		var x := rect.position.x + pad
		var w := rect.size.x - pad * 2.0
		var y := rect.position.y + pad + 16.0 * k
		draw_string(_font, Vector2(x, y), UpgradeCards.RARITY_NAMES[clampi(r, 0, 2)],
				HORIZONTAL_ALIGNMENT_LEFT, w, int(15.0 * k), rar_col)
		y += 34.0 * k
		draw_string(_font, Vector2(x, y), String(info["name"]),
				HORIZONTAL_ALIGNMENT_LEFT, w, int(30.0 * k), COL_TEXT)
		y += 22.0 * k
		draw_line(Vector2(x, y), Vector2(x + w, y), Color(1, 1, 1, 0.10), 1.0)
		y += 28.0 * k
		draw_multiline_string(_font, Vector2(x, y), String(info["desc"]),
				HORIZONTAL_ALIGNMENT_LEFT, w, int(19.0 * k), 6, COL_DIM)
		# 底部：已持有数量
		var owned_row := rect.position.y + rect.size.y - pad
		draw_string(_font, Vector2(x, owned_row),
				UpgradeCards.subtitle(id, Run.counts.get(id, 0)),
				HORIZONTAL_ALIGNMENT_LEFT, w, int(15.0 * k),
				COL_ACCENT if Run.owns_card(id) else COL_DIM)
		if sel:
			draw_string(_font, Vector2(rect.position.x, rect.position.y - 10.0),
					"▲", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, int(18.0 * k), rar_col)


func _draw_station() -> void:
	var sub_fs: int = 18 if size.x > 1400.0 else 15
	for i in station.size():
		var it: Dictionary = station[i]
		var rect := _station_rect(i)
		var sel: bool = (i == cursor)
		var sold := bool(it.get("sold", false))
		var ok := bool(it.get("enabled", true)) and not sold
		var border: Color = COL_ACCENT if sel else Color(1, 1, 1, 0.16)
		var fill := Color(0.075, 0.09, 0.115, 0.98)
		if sel:
			fill = Color(0.12, 0.14, 0.175, 0.99)
		_panel(rect, fill, border, 2.0 if sel else 1.0, 8.0)
		var x := rect.position.x + 22.0
		var y := rect.position.y + 30.0
		var name_col: Color = COL_DIM if (sold or not ok) else COL_TEXT
		draw_string(_font, Vector2(x, y), String(it.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, 220.0, int(22.0 * (1.0 if rect.size.x > 700.0 else 0.85)),
				name_col)
		draw_string(_font, Vector2(x + 200.0, y), String(it.get("desc", "")),
				HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 420.0, sub_fs, COL_DIM)
		var price := int(it.get("cost", 0))
		var price_col := COL_DIM if (sold or not ok) else COL_ACCENT
		var label := "%d 战功" % price
		if sold:
			label = "已购"
		elif bool(it.get("maxed", false)):
			label = "已达上限"
		elif not ok:
			price_col = COL_BAD
			label = "战功不足"
		draw_string(_font, Vector2(rect.position.x + rect.size.x - 220.0, y), label,
				HORIZONTAL_ALIGNMENT_RIGHT, 190.0, sub_fs, price_col)


## 圆角面板。Godot 的 draw_rect 只有直角，用 StyleBoxFlat 才能得到与 HUD 一致的圆角。
func _panel(rect: Rect2, fill: Color, border: Color, width: float, radius: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(int(maxf(width, 1.0)))
	sb.set_corner_radius_all(int(radius))
	draw_style_box(sb, rect)