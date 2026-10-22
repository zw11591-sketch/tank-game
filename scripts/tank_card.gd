class_name TankCard
extends Control
## 选车界面的属性卡：型号名 / 定位 / 特性说明 / 六条对比条。
##
## 全部用 _draw 现画而不是拼一堆 Label：样式因此与 HUD 同源（都是代码画的），
## 不需要主题资源，也不必为一个面板去维护十几行 Text/Container 节点。
## 对比条本身是矩形而不是 █ 字符——中文字体不一定带方块字符，画矩形则永远都在。

var tank_id := TankRoster.DEFAULT_ID

const PAD := 18.0
const BAR_X := 74.0
const BAR_W := 250.0
const BAR_H := 15.0
const ROW_H := 31.0
## k = 1 时，从顶栏排到六条对比条底部需要的高度。
##
## 卡片拿到的高度不是常数：界面缩放到 200% 时可见区域只剩 960x540，
## 转台下方只分到两百来像素，而按设计字号排下来要 460 px——不缩放的话
## 「特性」说明被下缘切掉，六条对比条整块画到屏幕外，玩家看不到任何数值。
## 所以整张卡按 `size.y / NEED_H` 等比缩小；字号是**算出来再画**的，
## 不是给画布加一个缩放矩阵，否则文字会被当成位图放大糊掉。
const NEED_H := 460.0


func _draw() -> void:
	var f := ThemeDB.fallback_font
	var s := TankRoster.spec(tank_id)
	var accent: Color = s["accent_color"]
	var k := clampf(size.y / NEED_H, 0.35, 1.0)
	var pad := PAD * k
	var w := size.x - pad * 2.0
	var y := pad + 26.0 * k
	var fs_full := int(round(28.0 * k))
	var fs_tag := int(round(19.0 * k))
	var fs_desc := int(round(17.0 * k))
	var fs_perk := int(round(21.0 * k))
	var fs_perk_body := int(round(17.0 * k))
	var fs_bar := int(round(19.0 * k))
	var fs_val := int(round(17.0 * k))

	# ---- 顶栏：型号名 + 定位标签 ----
	draw_string(f, Vector2(pad, y), String(s["full"]),
			HORIZONTAL_ALIGNMENT_LEFT, w - 96.0 * k, fs_full, accent)
	draw_string(f, Vector2(pad, y), String(s["tag"]),
			HORIZONTAL_ALIGNMENT_RIGHT, w, fs_tag, Color(0.72, 0.79, 0.88))
	y += 12.0 * k
	draw_rect(Rect2(pad, y, w, 1.5), Color(accent.r, accent.g, accent.b, 0.35))
	y += 28.0 * k

	# ---- 一句话定位 ----
	y = _wrapped(f, pad, y, String(s["desc"]), w, fs_desc,
			Color(0.74, 0.80, 0.87), k)
	y += 14.0 * k

	# ---- 特性块 ----
	var perk_lines := _wrap(f, String(s["perk_desc"]), w - 22.0 * k, fs_perk_body)
	var perk_h := (46.0 + perk_lines.size() * 24.0) * k
	draw_rect(Rect2(pad - 6.0, y, w + 12.0, perk_h),
			Color(accent.r, accent.g, accent.b, 0.10))
	draw_rect(Rect2(pad - 6.0, y, w + 12.0, perk_h),
			Color(accent.r, accent.g, accent.b, 0.30), false, 1.5)
	draw_string(f, Vector2(pad + 8.0 * k, y + 28.0 * k),
			"特性  %s" % s["perk_name"], HORIZONTAL_ALIGNMENT_LEFT,
			w - 20.0 * k, fs_perk, accent)
	var py := y + 52.0 * k
	for line in perk_lines:
		draw_string(f, Vector2(pad + 8.0 * k, py), line,
				HORIZONTAL_ALIGNMENT_LEFT, w - 20.0 * k, fs_perk_body,
				Color(0.82, 0.87, 0.93))
		py += 24.0 * k
	y += perk_h + 22.0 * k

	# ---- 六条对比条 ----
	var bar_h := BAR_H * k
	for row in TankRoster.bars(tank_id):
		var v: float = clampf(float(row["v"]), 0.0, 1.0)
		var cy := y - bar_h * 0.5 + 6.0 * k
		draw_string(f, Vector2(pad, y), String(row["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, BAR_X - 14.0, fs_bar,
				Color(0.86, 0.90, 0.95))
		draw_rect(Rect2(pad + BAR_X, cy, BAR_W, bar_h), Color(0, 0, 0, 0.45))
		# 色相从中低位红一路推到绿：同一条条上"满"与"空"一眼可分，
		# 不必先读右边的数字再回过去比较
		var col := Color.from_hsv(lerpf(0.015, 0.33, v), 0.72, 0.95)
		draw_rect(Rect2(pad + BAR_X + 1.5, cy + 1.5,
				(BAR_W - 3.0) * v, bar_h - 3.0), col)
		draw_rect(Rect2(pad + BAR_X, cy, BAR_W, bar_h), Color(1, 1, 1, 0.22), false, 1.0)
		draw_string(f, Vector2(pad + BAR_X + BAR_W + 12.0, y), String(row["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, w - BAR_X - BAR_W - 12.0, fs_val,
				Color(0.78, 0.84, 0.90))
		y += ROW_H * k

	# ---- 战绩（底部） ----
	# 画在尺寸的底边上而不是跟着对比条往下排：排行榜这类"有没有"信息
	# 不该改变属性卡的排版，否则打过一局和没打过一局的面板高度会不一样。
	var summary := Stats.tank_summary(tank_id)
	if summary != "":
		draw_string(f, Vector2(pad, size.y - pad), summary,
				HORIZONTAL_ALIGNMENT_LEFT, w, int(round(16.0 * k)),
				Color(0.72, 0.80, 0.72))


# ---------------- 文本换行 ----------------

## 逐字测量换行。中英混排里中文没有空格，按词换行会整段排不下一行，
## 所以这里退回最朴素的做法：一个字一个字地累加，超宽就断行。
func _wrapped(f: Font, x: float, y: float, text: String, w: float, fsize: int,
		col: Color, k: float) -> float:
	for line in _wrap(f, text, w, fsize):
		draw_string(f, Vector2(x, y), line,
				HORIZONTAL_ALIGNMENT_LEFT, w, fsize, col)
		y += float(fsize) + 6.0 * k
	return y


func _wrap(f: Font, text: String, w: float, fsize: int) -> Array:
	var out: Array = []
	for para in text.split("\n"):
		var line := ""
		for ch in para:
			var probe := line + ch
			if line != "" and f.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x > w:
				out.append(line)
				line = ch
			else:
				line = probe
		out.append(line)
	return out
