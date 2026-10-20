class_name HUD
extends CanvasLayer
## 战斗 HUD：准星与装填环、结构/基地血条、弹种与技能冷却、雷达小地图、
## 受击方向指示、连杀提示。全部用 Control 的 _draw 在代码中绘制。

var game: Node

var reticle: Reticle
var radar: Radar
var damage_ring: DamageRing
var hull_ind: HullIndicator

var _score_l: Label
var _stage_l: Label
var _combo_l: Label
var _enemy_l: Label
var _shell_l: Label
var _skill_l: Label
var _hint_l: Label
var _speed_l: Label
var _hp_bar: Bar
var _base_bar: Bar
var _buff_l: Label

## F3 诊断浮层：排查"鼠标/按键没反应"时用。统计真实到达引擎的鼠标位移事件，
## 并把输入链路上每一环的实际数值摊开，省去反复猜测。
var _dbg_l: Label
var _dbg_on := false
var _dbg_motions := 0
var _dbg_px := 0.0


func _ready() -> void:
	layer = 5

	_score_l = _label(Vector2(20, 14), 24, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_LEFT, 320)
	_stage_l = _label(Vector2(20, 44), 19, Color(0.62, 0.78, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 520)
	_combo_l = _label(Vector2(20, 70), 21, Color(1.0, 0.72, 0.25), HORIZONTAL_ALIGNMENT_LEFT, 320)
	_enemy_l = _label(Vector2(-340, 14), 21, Color(1.0, 0.62, 0.55), HORIZONTAL_ALIGNMENT_RIGHT, 320)

	# 底部状态区
	_hp_bar = Bar.new()
	_hp_bar.tint = Color(0.35, 0.85, 0.45)
	_hp_bar.label = "结构"
	add_child(_hp_bar)

	_base_bar = Bar.new()
	_base_bar.tint = Color(0.4, 0.8, 1.0)
	_base_bar.label = "基地"
	add_child(_base_bar)

	_shell_l = _label(Vector2(20, 0), 22, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_LEFT, 420)
	_skill_l = _label(Vector2(20, 0), 18, Color(0.8, 0.86, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 460)
	_buff_l = _label(Vector2(20, 0), 18, Color(0.65, 0.95, 0.7), HORIZONTAL_ALIGNMENT_LEFT, 460)

	_hint_l = _label(Vector2(0, 0), 30, Color(1.0, 0.85, 0.35), HORIZONTAL_ALIGNMENT_CENTER, 900)

	reticle = Reticle.new()
	reticle.hud = self
	add_child(reticle)

	radar = Radar.new()
	radar.hud = self
	add_child(radar)

	damage_ring = DamageRing.new()
	damage_ring.hud = self
	add_child(damage_ring)

	# 车体朝向指示器：炮塔与车体分离操控时，没有它很容易"不知道车头在哪"
	hull_ind = HullIndicator.new()
	hull_ind.hud = self
	add_child(hull_ind)

	_speed_l = _label(Vector2(0, 0), 17, Color(0.85, 0.9, 1.0), HORIZONTAL_ALIGNMENT_CENTER, 160)

	_dbg_l = _label(Vector2(20, 110), 16, Color(0.6, 1.0, 0.7), HORIZONTAL_ALIGNMENT_LEFT, 760)
	_dbg_l.size = Vector2(760, 230)
	_dbg_l.visible = false

	# HUD 不拦截鼠标，射击输入直接读设备状态
	for ch in get_children():
		if ch is Control:
			ch.mouse_filter = Control.MOUSE_FILTER_IGNORE


## 统计真实到达引擎的鼠标位移，供 F3 浮层显示。只观察，不消费事件。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_dbg_motions += 1
		_dbg_px += event.relative.length()
	elif event.is_action_pressed("debug_hud") and not event.is_echo():
		_dbg_on = not _dbg_on
		_dbg_l.visible = _dbg_on


## 把输入链路逐环摊开：事件是否到达 -> 相机是否转 -> 炮塔是否跟随
func _dbg_text() -> String:
	var rig: CameraRig = game.rig
	var p = game.player
	var lines: Array = [
		"— F3 输入诊断 —  %d FPS" % Engine.get_frames_per_second(),
		"状态 %s    鼠标捕获 %s    窗口聚焦 %s" % [
			game.state,
			"是" if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else "否（环视无效）",
			"是" if DisplayServer.window_is_focused() else "否",
		],
		"鼠标位移事件 %d 个 / 累计 %.0f px    灵敏度 %.2f" % [
			_dbg_motions, _dbg_px, Settings.mouse_sens,
		],
		"镜头 yaw %+.1f°  pitch %+.1f°    瞄准 yaw %+.1f°  pitch %+.1f°（两者分离才看得出炮管转动）" % [
			rad_to_deg(rig.yaw), rad_to_deg(rig.pitch),
			rad_to_deg(rig.aim_yaw), rad_to_deg(rig.aim_pitch),
		],
	]
	if p != null and is_instance_valid(p):
		lines.append("车体朝向 %+.1f°    炮塔(相对车体) %+.1f°    炮塔(世界) %+.1f°" % [
			rad_to_deg(p.rotation.y), rad_to_deg(p.turret.rotation.y),
			rad_to_deg(p.rotation.y + p.turret.rotation.y),
		])
		lines.append("油门 %+.2f  转向 %+.2f  车速 %.1f km/h  驾驶 %s" % [
			Input.get_action_strength("move_forward") - Input.get_action_strength("move_back"),
			Input.get_action_strength("turn_right") - Input.get_action_strength("turn_left"),
			p.speed_kmh(),
			"镜头相对" if Settings.drive_relative else "履带转向",
		])
		lines.append("准星可达 %s" % ("是" if rig.aim_reachable() else "否（被挡/超出俯仰）"))
	else:
		lines.append("玩家坦克不存在（重生中）")
	return "\n".join(lines)


func _label(pos: Vector2, fsize: int, col: Color, align: int, width: float) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = Vector2(width, fsize + 10)
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	add_child(l)
	return l


func _process(_delta: float) -> void:
	if game == null:
		return
	var vp := get_viewport().get_visible_rect().size

	_score_l.text = "得分 %07d" % game.score
	# 带上地形名：开场横幅过两秒就没了，而"我现在在哪张图"会一直影响战术选择
	_stage_l.text = "关卡 %d / %d   %s   最高 %07d" % [
		game.stage, game.MAX_STAGE, game.terrain_name(), game.high_score,
	]
	_combo_l.text = ("连击 x%.1f" % game.combo_mult) if game.combo_mult > 1.01 else ""
	_enemy_l.text = "剩余敌军  %d" % game.enemies_remaining()
	_enemy_l.position = Vector2(vp.x - 340, 14)
	_enemy_l.size = Vector2(320, 32)

	# 底部条
	var bar_w := 300.0
	_hp_bar.position = Vector2(20, vp.y - 96)
	_hp_bar.size = Vector2(bar_w, 22)
	_base_bar.position = Vector2(20, vp.y - 66)
	_base_bar.size = Vector2(bar_w, 16)

	var p = game.player
	if p != null and is_instance_valid(p) and p.alive:
		_hp_bar.ratio = float(p.hp) / float(p.max_hp)
		_hp_bar.text = "%d / %d" % [maxi(p.hp, 0), p.max_hp]
		# 车型写在血条上：选车界面的选择必须在中途也读得到，
		# 否则玩到第五关已经忘了自己开的是哪一台、为什么转向这么钝
		_hp_bar.label = "结构 · %s" % p.tank_name()
		var ap: bool = p.shell_kind == Shell.Kind.AP
		_shell_l.text = "[Q/Y] 弹种  " + ("● 穿甲弹 AP" if ap else "◆ 高爆弹 HE")
		_shell_l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35) if ap else Color(1.0, 0.5, 0.25))
		_skill_l.text = "[Shift/RB] 冲刺 %s     [Space/LB] 烟雾 %s" % [_cd_txt(p.boost_cd), _cd_txt(p.smoke_cd)]
		_buff_l.text = _buff_txt(p)
		_speed_l.text = "%s  %3.0f km/h" % [_gear_txt(p.gear()), p.speed_kmh()]
	else:
		_hp_bar.ratio = 0.0
		_hp_bar.text = "已被击毁"
		_hp_bar.label = "结构"
		_shell_l.text = ""
		_skill_l.text = ""
		_buff_l.text = ""
		_speed_l.text = ""

	_shell_l.position = Vector2(20, vp.y - 152)
	_skill_l.position = Vector2(20, vp.y - 124)
	_buff_l.position = Vector2(20, vp.y - 178)

	if game.arena != null:
		_base_bar.ratio = float(game.arena.base_hp) / float(game.arena.base_max_hp)
		_base_bar.text = "%d" % game.arena.base_hp

	_hint_l.position = Vector2(vp.x * 0.5 - 450, vp.y * 0.32)
	_hint_l.size = Vector2(900, 120)
	# 开场倒计时期间油门是锁死的，必须把"还要等多久"画出来。
	# 否则玩家按方向键没反应、又看不到任何倒计时，只会以为操作失灵。
	if game.state == "ready":
		_hint_l.text = "%s\n准 备  %.1f  ·  可先用鼠标预瞄炮塔" % [
			game.banner_text, maxf(game.state_timer, 0.0),
		]
	else:
		_hint_l.text = game.banner_text

	if _dbg_on:
		_dbg_l.text = _dbg_text()

	radar.position = Vector2(vp.x - 190, vp.y - 190)
	radar.size = Vector2(170, 170)
	radar.queue_redraw()

	# 车体朝向盘摆在雷达左侧，和车速读数上下对齐。
	# 第一人称下完全看不见自己的车体，朝向盘成了唯一的车头参照，所以放大一档。
	var fp: bool = game.rig != null and game.rig.first_person
	var dial := 136.0 if fp else 96.0
	hull_ind.position = Vector2(vp.x - 204 - dial, vp.y - 64 - dial)
	hull_ind.size = Vector2(dial, dial)
	hull_ind.queue_redraw()
	_speed_l.position = Vector2(vp.x - 328, vp.y - 60)
	_speed_l.size = Vector2(152, 26)

	reticle.position = Vector2.ZERO
	reticle.size = vp
	reticle.queue_redraw()

	damage_ring.position = Vector2.ZERO
	damage_ring.size = vp
	damage_ring.queue_redraw()

	_hp_bar.queue_redraw()
	_base_bar.queue_redraw()


func _cd_txt(cd: float) -> String:
	return "就绪" if cd <= 0.0 else "%.0fs" % ceil(cd)


func _gear_txt(g: int) -> String:
	match g:
		1:
			return "前进 D"
		-1:
			return "倒车 R"
		_:
			return "空挡 N"


func _buff_txt(p) -> String:
	var parts: Array = []
	if p.shield_t > 0.0:
		parts.append("护盾 %.0fs" % ceil(p.shield_t))
	if p.armor_buff_t > 0.0:
		parts.append("装甲 %.0fs" % ceil(p.armor_buff_t))
	if p.rapid_buff_t > 0.0:
		parts.append("装填 %.0fs" % ceil(p.rapid_buff_t))
	if p.damage_mult > 1.01:
		parts.append("火力 +%d%%" % int(round((p.damage_mult - 1.0) * 100.0)))
	return "  ".join(parts)


# ---------------- 内部控件 ----------------

class Bar extends Control:
	var ratio := 1.0
	var tint := Color(0.4, 0.9, 0.5)
	var label := ""
	var text := ""

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0, 0, 0, 0.55))
		var fill := Rect2(Vector2(2, 2), Vector2((size.x - 4) * clampf(ratio, 0.0, 1.0), size.y - 4))
		var c := tint if ratio > 0.35 else Color(0.95, 0.35, 0.25)
		draw_rect(fill, c)
		draw_rect(r, Color(1, 1, 1, 0.35), false, 1.5)
		# 布局尚未生效时 size 为 0，换算出的字号会是非法值，这里直接跳过文字
		if size.y < 8.0:
			return
		var f := ThemeDB.fallback_font
		draw_string(f, Vector2(8, size.y - 5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size.y * 0.72), Color(1, 1, 1, 0.95))
		draw_string(f, Vector2(size.x - 96, size.y - 5), text, HORIZONTAL_ALIGNMENT_RIGHT, 90, int(size.y * 0.66), Color(1, 1, 1, 0.9))


class Reticle extends Control:
	var hud: HUD

	func _draw() -> void:
		var g = hud.game
		if g == null or g.state != "play":
			return
		var p = g.player
		if p == null or not is_instance_valid(p) or not p.alive:
			return
		var c := size * 0.5
		var ready: bool = p.can_fire()
		var rig = g.rig
		if rig != null:
			# 镜头锁车体之后准星不再固定在屏幕中心，它跟着炮塔瞄准方向走
			var sp: Vector2 = rig.aim_screen_point()
			if sp == Vector2.INF:
				return
			c = sp.clamp(Vector2(44, 44), size - Vector2(44, 44))
		var hot: bool = rig != null and rig.aim_target() != null and rig.aim_target() != p
		var reachable: bool = rig == null or rig.aim_reachable()

		var col := Color(1.0, 0.3, 0.25) if hot else (Color(0.6, 1.0, 0.7) if ready else Color(0.75, 0.78, 0.82, 0.75))
		if not reachable:
			# 打不到的点（俯仰够不着或被掩体挡住）一律变灰，省下一发空弹
			col = Color(0.55, 0.55, 0.58, 0.65)
		# 限位炮塔（歼击车）的目标跑到射界之外：变色之外还要说清"为什么没跟上"，
		# 否则玩家只会以为鼠标失灵
		var limited: bool = p.turret_blocked
		if limited:
			col = Color(1.0, 0.62, 0.2)
		# 空击：炮还没装好就点了鼠标。整个准星转红，于是"点了没反应"永远不会发生
		if p.dry_flash > 0.0:
			col = Color(1.0, 0.32, 0.28)

		# 装填未完成时准星张开，完成后收拢
		var gap: float = 8.0 + (1.0 - p.reload_ratio()) * 22.0
		var arm := 12.0
		var width := 2.0 + (4.0 if p.dry_flash > 0.0 else 0.0)
		for d in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * gap, c + d * (gap + arm), col, width)
		draw_circle(c, 2.0, col)

		# 装填进度环
		var r := gap + arm + 8.0
		draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * p.reload_ratio(), 48, col, 3.0)
		if p.dry_flash > 0.0:
			draw_arc(c, r, 0.0, TAU, 40, Color(1.0, 0.3, 0.26, p.dry_flash / 0.22 * 0.9), 2.5)
		if not ready:
			var f := ThemeDB.fallback_font
			draw_string(f, c + Vector2(-30, r + 26), "装填 %.1fs" % (p.reload_t / maxf(p.reload_rate(), 0.01)),
					HORIZONTAL_ALIGNMENT_CENTER, 60, 15, Color(1, 1, 1, 0.7))

		_draw_hitmark(c, p)
		_draw_muzzle_ring(c, col)
		_draw_reverse(c, p)
		if limited:
			draw_string(ThemeDB.fallback_font, c + Vector2(-90.0, -gap - arm - 22.0),
					"炮塔限位 · 转车体瞄准",
					HORIZONTAL_ALIGNMENT_CENTER, 180, 16, Color(1.0, 0.66, 0.24, 0.95))

	## 命中标记：炮弹真的打到目标时在准星上打一个叉。
	## 开火与命中之间隔着炮弹飞行时间，没有这个确认就只能盯着目标猜打中没打中。
	func _draw_hitmark(c: Vector2, p) -> void:
		if p.hit_flash <= 0.0:
			return
		var k: float = p.hit_flash / 0.3
		var col := Color(0.72, 0.84, 1.0, k) if p.hit_ricochet else Color(1.0, 0.95, 0.55, k)
		# 命中瞬间最大、随即收拢，于是连续命中也能一眼数清打了几发
		var inner := 7.0 + (1.0 - k) * 5.0
		var outer := inner + 9.0
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			draw_line(c + d * inner, c + d * outer, col, 2.5)

	## 倒车提示：车体前后几乎对称，没有它很容易"以为在前进、其实在倒车"。
	## 画在准星上方，因为视线一直在准星上，放到屏幕角落等于没画。
	func _draw_reverse(c: Vector2, p) -> void:
		if p.gear() != -1:
			return
		var col := Color(1.0, 0.72, 0.2, 0.95)
		var top := c + Vector2(0, -62.0)
		# 向下的三角，与"倒车"二字一起指明车正在往车尾方向走
		draw_colored_polygon(PackedVector2Array([
			top + Vector2(-9, -7), top + Vector2(9, -7), top + Vector2(0, 5),
		]), col)
		draw_string(ThemeDB.fallback_font, top + Vector2(-60, 28), "倒车",
				HORIZONTAL_ALIGNMENT_CENTER, 120, 19, col)

	## 炮口真实指向的次级环：它与中心准星重合时才是真的对准了。
	## 炮塔还在回转的途中，这个环会从外侧收向中心，给出明确的"等一下"信号。
	func _draw_muzzle_ring(c: Vector2, col: Color) -> void:
		var rig = hud.game.rig
		if rig == null:
			return
		var m: Vector2 = rig.muzzle_screen_point()
		if m == Vector2.INF:
			return
		var off := m - c
		if off.length() < 3.0:
			return
		# 偏差越大画得越淡，避免甩炮时满屏乱飞
		var a := clampf(1.0 - off.length() / (size.length() * 0.45), 0.25, 0.9)
		var mc := Color(col.r, col.g, col.b, a)
		draw_arc(m, 9.0, 0.0, TAU, 20, mc, 2.0)
		draw_line(m + Vector2(-4, 0), m + Vector2(4, 0), mc, 1.5)
		draw_line(m + Vector2(0, -4), m + Vector2(0, 4), mc, 1.5)
		draw_line(c + off.normalized() * 6.0, m - off.normalized() * 11.0, Color(mc.r, mc.g, mc.b, a * 0.35), 1.0)


## 车体朝向盘：外圈是相机朝向（屏幕上永远朝上）。镜头锁在车体后方，所以车体轮廓
## 基本朝上不动；真正会动的是红色的炮塔指针——它直观显示炮管相对车头偏了多少。
class HullIndicator extends Control:
	var hud: HUD

	func _draw() -> void:
		var g = hud.game
		if g == null or g.state == "title" or g.state == "select":
			return
		var p = g.player
		if p == null or not is_instance_valid(p) or not p.alive or g.rig == null:
			return

		var c := size * 0.5
		var r := size.x * 0.46
		draw_circle(c, r, Color(0.02, 0.05, 0.06, 0.6))
		draw_arc(c, r, 0.0, TAU, 40, Color(0.45, 0.85, 0.95, 0.4), 1.5)
		# 相机视线（屏幕正上方）
		draw_line(c + Vector2(0, -r), c + Vector2(0, -r + 8.0), Color(0.6, 0.95, 1.0, 0.8), 2.0)

		var a: float = p.rotation.y - g.rig.yaw
		var hull := PackedVector2Array([
			Vector2(-0.34, -0.5), Vector2(0.34, -0.5),
			Vector2(0.4, 0.46), Vector2(-0.4, 0.46),
		])
		var pts := PackedVector2Array()
		for v in hull:
			pts.append(c + v.rotated(a) * (r * 1.5))
		var moving: bool = absf(p.speed()) > 0.3
		draw_colored_polygon(pts, Color(0.45, 0.9, 0.5, 0.85) if moving else Color(0.5, 0.6, 0.65, 0.75))

		# 车头方向的小箭头
		var nose := c + Vector2(0, -1).rotated(a) * (r * 0.82)
		draw_line(c, nose, Color(1.0, 0.85, 0.3, 0.95), 2.5)

		# 炮塔相对车体的夹角
		var t: float = a + p.turret.rotation.y
		draw_line(c, c + Vector2(0, -1).rotated(t) * (r * 1.05), Color(1.0, 0.45, 0.3, 0.9), 2.0)


class Radar extends Control:
	const RANGE := 70.0
	var hud: HUD

	func _draw() -> void:
		var g = hud.game
		if g == null or g.arena == null:
			return
		var p = g.player
		var c := size * 0.5
		var r := size.x * 0.5

		draw_circle(c, r, Color(0.02, 0.05, 0.06, 0.72))
		draw_arc(c, r, 0, TAU, 48, Color(0.4, 0.9, 0.8, 0.5), 2.0)
		draw_arc(c, r * 0.5, 0, TAU, 32, Color(0.4, 0.9, 0.8, 0.22), 1.0)
		draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(0.4, 0.9, 0.8, 0.18), 1.0)
		draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(0.4, 0.9, 0.8, 0.18), 1.0)

		if p == null or not is_instance_valid(p):
			return
		# 雷达随玩家车体朝向旋转，上方永远是车头方向
		var yaw: float = p.rotation.y
		var origin: Vector3 = p.global_position

		var base_v := _map(g.arena.base_position(), origin, yaw, r)
		if base_v != Vector2.INF:
			draw_rect(Rect2(c + base_v - Vector2(4, 4), Vector2(8, 8)), Color(0.4, 0.85, 1.0))

		for pu in g.powerups:
			if not is_instance_valid(pu):
				continue
			var col: Color = PowerUp.info(pu.ptype)["color"]
			var v := _map(pu.global_position, origin, yaw, r)
			if v == Vector2.INF:
				# 超出量程的补给贴在雷达边缘画一个空心箭标。
				# 空投会落到场地深处，直接不画等于"说了已标记却看不到"，
				# 玩家于是只能瞎转；贴边之后至少方向是确定的。
				var d: Vector3 = pu.global_position - origin
				var e := Vector2(d.x, d.z).rotated(-yaw)
				e.y = -e.y
				if e.length_squared() < 0.001:
					continue
				var p0: Vector2 = c + e.normalized() * (r - 5.0)
				draw_arc(p0, 3.5, 0.0, TAU, 12, Color(col.r, col.g, col.b, 0.85), 1.5)
				continue
			draw_circle(c + v, 3.0, col)
			# 定时空投比击杀掉落值钱，外圈加一个脉动环把它拎出来
			if pu.from_field:
				var k: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
				draw_arc(c + v, 5.0 + k * 2.5, 0.0, TAU, 14,
						Color(col.r, col.g, col.b, 0.4 + k * 0.5), 1.5)

		for e in g.enemies:
			if not is_instance_valid(e) or not e.alive:
				continue
			var v := _map(e.global_position, origin, yaw, r)
			if v == Vector2.INF:
				continue
			var col := Color(1.0, 0.35, 0.3)
			var sz := 3.5
			if e.etype == 4:
				col = Color(1.0, 0.55, 0.1)
				sz = 6.0
			elif e.etype == 3:
				col = Color(0.85, 0.45, 0.95)
			draw_circle(c + v, sz, col)
			# 敌人炮口朝向
			var ey: float = e.rotation.y + e.turret.rotation.y - yaw
			draw_line(c + v, c + v + Vector2(-sin(ey), -cos(ey)) * (sz + 4.0), col, 1.5)

		# 玩家自身
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(0, -7), c + Vector2(-5, 5), c + Vector2(5, 5),
		]), Color(0.5, 1.0, 0.55))

	## 世界坐标 -> 雷达局部坐标；超出量程返回 Vector2.INF
	func _map(w: Vector3, origin: Vector3, yaw: float, r: float) -> Vector2:
		var d := w - origin
		var flat := Vector2(d.x, d.z)
		if flat.length() > RANGE:
			return Vector2.INF
		# 反向旋转到玩家本地坐标系；屏幕上 -Y 对应车头 -Z
		var rot := flat.rotated(yaw)
		return Vector2(rot.x, rot.y) * (r / RANGE)


class DamageRing extends Control:
	var hud: HUD

	func _draw() -> void:
		var g = hud.game
		if g == null:
			return
		var p = g.player
		if p == null or not is_instance_valid(p):
			return
		var c := size * 0.5
		for h in g.damage_marks:
			var a: float = clampf(h["t"] / 1.4, 0.0, 1.0)
			var d: Vector3 = h["pos"] - p.global_position
			var ang: float = atan2(d.x, -d.z) + g.rig.yaw
			var pts := PackedVector2Array()
			var rr := minf(size.x, size.y) * 0.24
			for i in 9:
				var k := -0.32 + 0.08 * i
				pts.append(c + Vector2(sin(ang + k), -cos(ang + k)) * (rr + (0.0 if i % 2 == 0 else 14.0)))
			draw_polyline(pts, Color(1.0, 0.25, 0.2, a * 0.85), 5.0)
