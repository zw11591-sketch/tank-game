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


func _draw() -> void:
	var f := ThemeDB.fallback_font
	var s := TankRoster.spec(tank_id)
	var accent: Color = s["accent_color"]
	var w := size.x - PAD * 2.0
	var y := PAD + 26.0

	# ---- 顶栏：型号名 + 定位标签 ----
	draw_string(f, Vector2(PAD, y), String(s["full"]),
			HORIZONTAL_ALIGNMENT_LEFT, w - 96.0, 28, accent)
	draw_string(f, Vector2(PAD, y), String(s["tag"]),
			HORIZONTAL_ALIGNMENT_RIGHT, w, 19, Color(0.72, 0.79, 0.88))
	y += 12.0
	draw_rect(Rect2(PAD, y, w, 1.5), Color(accent.r, accent.g, accent.b, 0.35))
	y += 28.0

	# ---- 一句话定位 ----
	y = _wrapped(f, y, String(s["desc"]), w, 17, Color(0.74, 0.80, 0.87))
	y += 14.0

	# ---- 特性块 ----
	var perk_lines := _wrap(f, String(s["perk_desc"]), w - 22.0, 17)
	var perk_h := 46.0 + perk_lines.size() * 24.0
	draw_rect(Rect2(PAD - 6.0, y, w + 12.0, perk_h),
			Color(accent.r, accent.g, accent.b, 0.10))
	draw_rect(Rect2(PAD - 6.0, y, w + 12.0, perk_h),
			Color(accent.r, accent.g, accent.b, 0.30), false, 1.5)
	draw_string(f, Vector2(PAD + 8.0, y + 28.0),
			"特性  %s" % s["perk_name"], HORIZONTAL_ALIGNMENT_LEFT, w - 20.0, 21, accent)
	var py := y + 52.0
	for line in perk_lines:
		draw_string(f, Vector2(PAD + 8.0, py), line,
				HORIZONTAL_ALIGNMENT_LEFT, w - 20.0, 17, Color(0.82, 0.87, 0.93))
		py += 24.0
	y += perk_h + 22.0

	# ---- 六条对比条 ----
	for row in TankRoster.bars(tank_id):
		var v: float = clampf(float(row["v"]), 0.0, 1.0)
		var cy := y - BAR_H * 0.5 + 6.0
		draw_string(f, Vector2(PAD, y), String(row["label"]),
				HORIZONTAL_ALIGNMENT_LEFT, BAR_X - 14.0, 19, Color(0.86, 0.90, 0.95))
		draw_rect(Rect2(PAD + BAR_X, cy, BAR_W, BAR_H), Color(0, 0, 0, 0.45))
		# 色相从中低位红一路推到绿：同一条条上"满"与"空"一眼可分，
		# 不必先读右边的数字再回过去比较
		var col := Color.from_hsv(lerpf(0.015, 0.33, v), 0.72, 0.95)
		draw_rect(Rect2(PAD + BAR_X + 1.5, cy + 1.5,
				(BAR_W - 3.0) * v, BAR_H - 3.0), col)
		draw_rect(Rect2(PAD + BAR_X, cy, BAR_W, BAR_H), Color(1, 1, 1, 0.22), false, 1.0)
		draw_string(f, Vector2(PAD + BAR_X + BAR_W + 12.0, y), String(row["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, w - BAR_X - BAR_W - 12.0, 17,
				Color(0.78, 0.84, 0.90))
		y += ROW_H

	# ---- 战绩（底部） ----
	# 画在尺寸的底边上而不是跟着对比条往下排：排行榜这类"有没有"信息
	# 不该改变属性卡的排版，否则打过一局和没打过一局的面板高度会不一样。
	var summary := Stats.tank_summary(tank_id)
	if summary != "":
		draw_string(f, Vector2(PAD, size.y - PAD), summary,
				HORIZONTAL_ALIGNMENT_LEFT, w, 16, Color(0.72, 0.80, 0.72))


# ---------------- 文本换行 ----------------

## 逐字测量换行。中英混排里中文没有空格，按词换行会整段排不下一行，
## 所以这里退回最朴素的做法：一个字一个字地累加，超宽就断行。
func _wrapped(f: Font, y: float, text: String, w: float, fsize: int,
		col: Color) -> float:
	for line in _wrap(f, text, w, fsize):
		draw_string(f, Vector2(PAD, y), line,
				HORIZONTAL_ALIGNMENT_LEFT, w, fsize, col)
		y += float(fsize) + 6.0
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
