class_name HUD
extends CanvasLayer
## 战斗 HUD：准星与装填环、结构/基地血条、弹种与技能冷却、雷达小地图、
## 受击方向指示、连杀提示。全部用 Control 的 _draw 在代码中绘制。

var game: Node

var reticle: Reticle
var radar: Radar
var damage_ring: DamageRing
var hull_ind: HullIndicator
var plates: NamePlates
var vignette: Vignette

var _score_l: Label
var _stage_l: Label
var _combo_l: Label
var _enemy_l: Label
var _shell_l: Label
var _skill_l: Label
var _spot_l: Label
var _hint_l: Label
var _speed_l: Label
var _hp_bar: Bar
var _base_bar: Bar
var _buff_l: Label
var _lives_l: Label
var _feed_l: Label
## 合作模式的队友状态：名字、血量、剩余命数。阵亡的队友仍在名册里，
## 所以这里按名册画，而不是按场上的车——否则"阵亡"两个字永远不出现。
var _team_l: Label

## 战斗结果提示（击穿 / 跳弹 / 击毁 / 格挡）。画在准星下方，
## 因为玩家的视线就在准星附近：放在屏幕角落等于不提示。
var _res_txt := ""
var _res_col := Color.WHITE
var _res_t := 0.0
const RES_TIME := 1.1

## 击毁信息栏（kill feed）。每条 5 秒后淡出。
var _feed: Array = []
const FEED_TIME := 5.0

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
	# 队友状态挂在左上角分数/关卡下方，最多三行，不会撞到中上方的隐蔽指示灯。
	_team_l = _label(Vector2(20, 104), 16, Color(0.55, 1.0, 0.62), HORIZONTAL_ALIGNMENT_LEFT, 460)
	_team_l.visible = false

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
	# 剩余战车必须一直看得见：它决定"还能不能硬顶"，而原来只在死亡横幅里出现一次
	_lives_l = _label(Vector2(20, 0), 17, Color(0.95, 0.9, 0.7), HORIZONTAL_ALIGNMENT_LEFT, 300)
	_feed_l = _label(Vector2(-420, 46), 17, Color(1.0, 0.82, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, 400)
	# 隐蔽 / 被发现指示灯。草丛与烟幕只有在玩家能读懂"我现在藏住了没有"
	# 的时候才是战术，否则只是一层看不见的判定。
	_spot_l = _label(Vector2(0, 14), 18, Color(0.6, 1.0, 0.7), HORIZONTAL_ALIGNMENT_CENTER, 320)

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

	# 受击暗角画在最底层：它只在屏幕边缘压红，不能盖住准星与血条。
	# 插在血条之前（血条是 _ready 开头建的），所以顺序上会压在它们下面。
	vignette = Vignette.new()
	vignette.hud = self
	add_child(vignette)
	move_child(vignette, 0)

	# 敌车血条：画在 3D 世界里每辆车的投影位置上，所以必须排在 HUD 最上层
	plates = NamePlates.new()
	plates.hud = self
	add_child(plates)

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

	# 血条与提示最后再抬到最上层：血条要压在敌车模型上，
	# 而它们都是后加的 Control，默认已经在上层，这里显式保证一次。
	move_child(plates, get_child_count() - 1)


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

	# 结果提示与击毁信息栏的计时放在这里：暂停时整个 HUD 仍会在跑（它要负责画暂停
	# 菜单下方的战场），所以额外判一次状态，免得暂停期间提示自己消失。
	var dt := 0.0 if game.state == "pause" else _delta
	_res_t = maxf(0.0, _res_t - dt)
	if _feed.size() > 0:
		var alive: Array = []
		for f in _feed:
			f["t"] = float(f["t"]) - dt
			if float(f["t"]) > 0.0:
				alive.append(f)
		_feed = alive

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

	# 隐蔽 / 被发现指示灯
	_spot_l.position = Vector2(vp.x * 0.5 - 160, 14)
	_spot_l.size = Vector2(320, 26)
	_update_spot(p)

	if game.arena != null:
		_base_bar.ratio = float(game.arena.base_hp) / float(game.arena.base_max_hp)
		_base_bar.text = "%d" % game.arena.base_hp

	_hint_l.position = Vector2(vp.x * 0.5 - 450, vp.y * 0.32)
	_hint_l.size = Vector2(900, 120)
	_lives_l.position = Vector2(20, vp.y - 204)
	_lives_l.size = Vector2(300, 24)
	if Net.is_multiplayer():
		# 合作模式：自己的命数与队友存活数一起显示。单机的 game.lives
		# 是"本机还剩几条"，多人下每条命归属各自的 peer。
		var mates := 0
		var mates_alive := 0
		for t in game.players:
			if t != game.player and is_instance_valid(t):
				mates += 1
				if t.alive:
					mates_alive += 1
		_lives_l.text = "战车 ×%d   队友 %d/%d" % [game.my_lives(), mates_alive, mates]
		_team_l.text = _team_text()
		_team_l.visible = not _team_l.text.is_empty()
	else:
		_lives_l.text = "剩余战车 ×%d" % maxi(game.lives, 0)
		_team_l.visible = false
	_feed_l.position = Vector2(vp.x - 420, 46)
	_feed_l.size = Vector2(400, 120)
	_feed_l.text = _feed_text()
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
	# 车速标签比原来宽 40 px、左移 40 px："空挡 N  00 km/h" 在 17 px 字号下
	# 约 190 px，原来的 152 px 会把两端顶出控件，靠近雷达时读起来像叠字。
	_speed_l.position = Vector2(vp.x - 368, vp.y - 60)
	_speed_l.size = Vector2(190, 26)

	reticle.position = Vector2.ZERO
	reticle.size = vp
	reticle.queue_redraw()

	damage_ring.position = Vector2.ZERO
	damage_ring.size = vp
	damage_ring.queue_redraw()

	_hp_bar.queue_redraw()
	_base_bar.queue_redraw()
	plates.size = vp
	plates.queue_redraw()
	vignette.size = vp
	vignette.queue_redraw()


## 战斗结果提示：击穿 / 跳弹 / 击毁 / 格挡。由 main 在炮弹产生结果时调用。
func show_result(text: String, col: Color) -> void:
	_res_txt = text
	_res_col = col
	_res_t = RES_TIME


## 击毁信息栏：一条一条往下排，5 秒后消失。
func feed(text: String) -> void:
	_feed.append({"text": text, "t": FEED_TIME})
	if _feed.size() > 4:
		_feed.remove_at(0)


func _feed_text() -> String:
	var lines: Array = []
	for f in _feed:
		lines.append(String(f["text"]))
	return "\n".join(lines)


## 合作模式的队友状态。名册是权威：队友阵亡后他的车会从场上移除，
## 但名册里仍然有这一行（带命数），所以"阵亡 · 命 ×2"能被画出来。
## 名字与命数都取自房主同步的 Net.players，血量取自快照回写到车上的值。
func _team_text() -> String:
	var lines: Array = []
	for row in Net.get_players_array():
		var pid := int(row.get("pid", 0))
		if pid == Net.local_pid():
			continue
		var nm := String(row.get("name", "队友"))
		if nm.is_empty():
			nm = "队友"
		var lives := int(row.get("lives", 0))
		var t = game.player_for_pid(pid) if game.has_method("player_for_pid") else null
		if t != null and is_instance_valid(t) and t.alive:
			lines.append("%s   %d/%d   命 ×%d" % [nm, int(t.hp), int(t.max_hp), lives])
		else:
			lines.append("%s   阵亡   命 ×%d" % [nm, lives])
	return "\n".join(lines)


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


## 隐蔽状态指示灯。优先级：被发现 > 烟幕 > 草丛 > 无。
## "被发现"用红色常亮而不是闪烁：它是一段持续状态，闪烁会读成警报噪音。
func _update_spot(p) -> void:
	if p == null or not is_instance_valid(p) or not p.alive:
		_spot_l.text = ""
		return
	var seen := false
	for e in game.enemies:
		if is_instance_valid(e) and e.alive and e.sees_player:
			seen = true
			break
	if seen:
		_spot_l.text = "● 被发现"
		_spot_l.add_theme_color_override("font_color", Color(1.0, 0.36, 0.3))
		return
	if p.is_smoked():
		_spot_l.text = "◇ 烟幕隐蔽"
		_spot_l.add_theme_color_override("font_color", Color(0.7, 0.86, 1.0))
	elif p.is_concealed():
		_spot_l.text = "◇ 隐蔽中"
		_spot_l.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	else:
		_spot_l.text = ""


func _buff_txt(p) -> String:
	var parts: Array = []
	if p.shield_t > 0.0:
		parts.append("护盾 %.0fs" % ceil(p.shield_t))
	if p.armor_buff_t > 0.0:
		parts.append("装甲 %.0fs" % ceil(p.armor_buff_t))
	if p.rapid_buff_t > 0.0:
		parts.append("装填 %.0fs" % ceil(p.rapid_buff_t))
	# 多弹装填与引擎过载原来只存在于 _process 里，HUD 上看不到。
	# 这两项恰好是最需要"还剩多久"的增益（一个改火力密度、一个改机动），
	# 看不到计时就只能凭感觉猜，玩家会以为增益已经结束了。
	if p.multi_t > 0.0:
		parts.append("多弹 %.0fs" % ceil(p.multi_t))
	if p.overdrive_t > 0.0:
		parts.append("过载 %.0fs" % ceil(p.overdrive_t))
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

		var col := Color(0.6, 1.0, 0.7) if ready else Color(0.75, 0.78, 0.82, 0.75)
		# 准星压在敌车上时按装甲分区变色：正面黄、侧面橙、背面红。
		# 分区判定与 take_hit() 共用 Tank.zone_index()，所以提示与结算不会打架。
		# 这一条不增加任何随机性，只是把"打哪块更疼"从试错变成看得见。
		var zone := -1
		var bounce_risk := false
		var aimed = rig.aim_target() if rig != null else null
		if hot and aimed != null and is_instance_valid(aimed):
			var from: Vector3 = rig.aim_origin()
			zone = aimed.zone_index(from)
			bounce_risk = aimed.is_ricochet_angle(from, p.shell_kind)
			match zone:
				0: col = Color(1.0, 0.86, 0.32)
				1: col = Color(1.0, 0.55, 0.20)
				_: col = Color(1.0, 0.30, 0.26)
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
		# 正对着可能跳弹的角度：在准星外侧加一圈冷色描边。
		# 这是"把车头斜过来"唯一能被玩家看见的回报。
		if bounce_risk:
			draw_arc(c, 26.0, 0.0, TAU, 28, Color(0.55, 0.72, 1.0, 0.85), 1.6)

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
		_draw_result(c)
		_draw_he_arc()
		_draw_scope(c)
		if limited:
			draw_string(ThemeDB.fallback_font, c + Vector2(-90.0, -gap - arm - 22.0),
					"炮塔限位 · 转车体瞄准",
					HORIZONTAL_ALIGNMENT_CENTER, 180, 16, Color(1.0, 0.66, 0.24, 0.95))

	## HE 弹道预览：把解出来的抛物线投影到屏幕上画成断续的弧，末端画落点圈。
	##
	## HE 的抬升量是算出来的，玩家看不见就等于在盲投：抛物线一画，
	## "这一发会不会从敌人头顶飞过去"立刻有了答案，换弹种也不再是换一种运气。
	## 只在 HE 弹种下画——AP 是直瞄，多画一条直线只是噪声。
	func _draw_he_arc() -> void:
		var g = hud.game
		if g == null or g.rig == null or g.rig.cam == null:
			return
		var pts: PackedVector3Array = g.rig.he_preview()
		if pts.size() < 2:
			return
		var cam: Camera3D = g.rig.cam
		var col := Color(1.0, 0.55, 0.22, 0.55)
		var prev := Vector2.INF
		for i in pts.size():
			if cam.is_position_behind(pts[i]):
				prev = Vector2.INF
				continue
			var sp: Vector2 = cam.unproject_position(pts[i])
			# 每两个采样点画一段，于是整条弧是虚线：它不该被误读成一道光束
			if prev != Vector2.INF and i % 2 == 1:
				draw_line(prev, sp, col, 2.0)
			prev = sp
		# 落点圈：抛物线末端的真实落点
		var end: Vector3 = pts[pts.size() - 1]
		if not cam.is_position_behind(end):
			var ep: Vector2 = cam.unproject_position(end)
			draw_arc(ep, 12.0, 0.0, TAU, 20, Color(1.0, 0.45, 0.18, 0.85), 2.0)
			draw_line(ep + Vector2(-17, 0), ep + Vector2(17, 0), Color(1.0, 0.45, 0.18, 0.7), 1.5)
			draw_line(ep + Vector2(0, -17), ep + Vector2(0, 17), Color(1.0, 0.45, 0.18, 0.7), 1.5)


	## 狙击镜框：四边压暗 + 一圈镜筒 + 距离读数。
	##
	## 光是把 FOV 收窄还不够——玩家需要一条明确的"我现在在镜里"的边界，
	## 否则窄视场只会读成"画面忽然变小了"。距离读数同理：狙击的全部意义
	## 就是判断远近，没有距离数字就只剩放大。
	func _draw_scope(c: Vector2) -> void:
		var g = hud.game
		if g == null or g.rig == null or not g.rig.sniper:
			return
		var r: float = minf(size.x, size.y) * 0.42
		var center := size * 0.5
		var vign := Color(0.01, 0.012, 0.014, 0.88)
		draw_rect(Rect2(0, 0, size.x, center.y - r), vign)
		draw_rect(Rect2(0, center.y + r, size.x, size.y - center.y - r), vign)
		draw_rect(Rect2(0, center.y - r, center.x - r, r * 2.0), vign)
		draw_rect(Rect2(center.x + r, center.y - r, size.x - center.x - r, r * 2.0), vign)
		draw_arc(center, r, 0.0, TAU, 96, Color(0.55, 0.6, 0.66, 0.9), 3.0)
		draw_arc(center, r - 5.0, 0.0, TAU, 96, Color(0.10, 0.11, 0.13, 0.85), 7.0)
		# 十字线只画到圈边，不穿过准星，免得和装填环打架
		draw_line(center + Vector2(-r, 0), center + Vector2(-40, 0), Color(0.75, 0.8, 0.85, 0.5), 1.5)
		draw_line(center + Vector2(r, 0), center + Vector2(40, 0), Color(0.75, 0.8, 0.85, 0.5), 1.5)
		draw_line(center + Vector2(0, -r), center + Vector2(0, -40), Color(0.75, 0.8, 0.85, 0.5), 1.5)
		draw_line(center + Vector2(0, r), center + Vector2(0, 40), Color(0.75, 0.8, 0.85, 0.5), 1.5)
		var f := ThemeDB.fallback_font
		var p = g.player
		if p != null and is_instance_valid(p):
			var d: float = p.global_position.distance_to(g.rig.aim_point())
			draw_string(f, center + Vector2(-80, r - 18), "%.0f m" % d,
					HORIZONTAL_ALIGNMENT_CENTER, 160, 22, Color(0.9, 0.94, 0.98, 0.9))
		var zoom_txt := "×2 窄镜" if g.rig.sniper_zoom > 0 else "×1 宽镜"
		draw_string(f, center + Vector2(-80, -r + 34), zoom_txt,
				HORIZONTAL_ALIGNMENT_CENTER, 160, 17, Color(0.75, 0.8, 0.85, 0.75))

	## 结果提示：击穿 / 跳弹 / 击毁 / 格挡。
	## 画在准星正下方并向上收拢，视线不用离开准星就能读到结果。
	func _draw_result(c: Vector2) -> void:
		var h := hud
		if h == null or h._res_t <= 0.0:
			return
		var k: float = clampf(h._res_t / h.RES_TIME, 0.0, 1.0)
		var rise: float = (1.0 - k) * 12.0
		var a: float = clampf(k * 1.6, 0.0, 1.0)
		var at := c + Vector2(-120.0, 58.0 - rise)
		draw_string(ThemeDB.fallback_font, at, h._res_txt,
				HORIZONTAL_ALIGNMENT_CENTER, 240, 21,
				Color(h._res_col.r, h._res_col.g, h._res_col.b, a))

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
				var e := edge_dir(pu.global_position, origin, yaw)
				if e == Vector2.ZERO:
					continue
				var p0: Vector2 = c + e * (r - 5.0)
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
		# 队友：绿色实心点 + 炮口朝向。合作模式下"队友在哪"是比敌人
		# 更需要一眼确认的信息，否则四辆车很容易在同一格走廊里对顶。
		for t in g.players:
			if not is_instance_valid(t) or not t.alive or t == p:
				continue
			var tv := _map(t.global_position, origin, yaw, r)
			if tv == Vector2.INF:
				continue
			var tc := Color(0.45, 1.0, 0.60)
			draw_circle(c + tv, 3.2, tc)
			var ty: float = t.rotation.y + t.turret.rotation.y - yaw
			draw_line(c + tv, c + tv + Vector2(-sin(ty), -cos(ty)) * 7.0, tc, 1.5)

	## 世界坐标 -> 雷达局部坐标；超出量程返回 Vector2.INF
	func _map(w: Vector3, origin: Vector3, yaw: float, r: float) -> Vector2:
		var d := w - origin
		var flat := Vector2(d.x, d.z)
		if flat.length() > RANGE:
			return Vector2.INF
		# 反向旋转到玩家本地坐标系；屏幕上 -Y 对应车头 -Z
		var rot := flat.rotated(yaw)
		return Vector2(rot.x, rot.y) * (r / RANGE)

	## 量程外目标的贴边方向（单位向量，雷达局部坐标）。
	##
	## 必须与 _map() 走同一套换算，否则同一个目标"在量程内画在这里、出了量程
	## 画到那里"。原来这里多做了 `rotated(-yaw)` 又把 y 翻一次，两次"修正"
	## 叠成一个镜像：正前方的补给被画到雷达底边，玩家照着箭头开正好背道而驰。
	static func edge_dir(w: Vector3, origin: Vector3, yaw: float) -> Vector2:
		var d := w - origin
		var flat := Vector2(d.x, d.z).rotated(yaw)
		if flat.length_squared() < 0.000001:
			return Vector2.ZERO
		return flat.normalized()


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


## 敌车血条。把每辆车的世界坐标投影到屏幕上画一条短血条——
## 没有它，玩家只能从"还剩几个敌人"的计数里推断战果，打残一辆车和刚见到它
## 在画面上完全一样，火力该往谁身上压全靠猜。
##
## 视线判定按 4 Hz 刷新而不是每帧：`has_line_of_sight()` 是一次网格步进，
## 六辆车每帧各做一次完全是浪费，而"墙后面"的信息晚 0.25 秒毫无影响。
class NamePlates extends Control:
	var hud: HUD
	var _seen: Dictionary = {}
	var _t := 0.0

	func _process(delta: float) -> void:
		var g = hud.game
		if g == null or g.state == "pause":
			return
		_t -= delta
		if _t > 0.0:
			return
		_t = 0.25
		_seen.clear()
		var p = g.player
		if p == null or not is_instance_valid(p) or g.arena == null:
			return
		var eye: Vector3 = p.global_position + Vector3(0, 1.9, 0)
		for e in g.enemies:
			if not is_instance_valid(e) or not e.alive:
				continue
			var alive: bool = g.arena.has_line_of_sight(
					eye, e.global_position + Vector3(0, 1.9, 0))
			_seen[e.get_instance_id()] = alive

	func _draw() -> void:
		var g = hud.game
		if g == null or g.state != "play":
			return
		var p = g.player
		var rig = g.rig
		if p == null or not is_instance_valid(p) or rig == null or rig.cam == null:
			return
		var cam: Camera3D = rig.cam
		var eye: Vector3 = p.global_position
		for e in g.enemies:
			if not is_instance_valid(e) or not e.alive:
				continue
			var dist: float = eye.distance_to(e.global_position)
			# 雷达量程以外不画：那不是"看不见"，是"不在这张图的交战范围里"
			if dist > Radar.RANGE + 6.0:
				continue
			var top: float = 4.3 if e.etype == 4 else 2.95
			var world: Vector3 = e.global_position + Vector3(0, top, 0)
			if cam.is_position_behind(world):
				continue
			var sp: Vector2 = cam.unproject_position(world)
			if sp.x < -80.0 or sp.y < -40.0 or sp.x > size.x + 80.0 or sp.y > size.y + 40.0:
				continue

			var lit: bool = bool(_seen.get(e.get_instance_id(), true))
			var ratio: float = clampf(float(e.hp) / maxf(float(e.max_hp), 1.0), 0.0, 1.0)
			var boss: bool = e.etype == 4
			var w := 76.0 if boss else 50.0
			var h := 8.0 if boss else 5.0
			# 距离越远血条越淡，近处才实：避免二十米外的六个条把画面糊住
			var base_a: float = clampf(1.2 - dist / (Radar.RANGE + 6.0), 0.35, 0.95)
			if not lit:
				base_a *= 0.35
			var r := Rect2(sp - Vector2(w * 0.5, h), Vector2(w, h))
			draw_rect(r, Color(0.02, 0.03, 0.04, 0.62 * base_a))
			var fill := Rect2(r.position + Vector2(1, 1), Vector2((w - 2) * ratio, h - 2))
			var fc := Color(0.95, 0.55, 0.25) if boss else Color(0.96, 0.35, 0.3)
			if not lit:
				fc = fc.lerp(Color(0.55, 0.58, 0.62), 0.6)
			draw_rect(fill, Color(fc.r, fc.g, fc.b, base_a))
			draw_rect(r, Color(1, 1, 1, 0.30 * base_a), false, 1.0)
			if boss:
				draw_string(ThemeDB.fallback_font, sp + Vector2(-60, -h - 6.0),
						"指挥车", HORIZONTAL_ALIGNMENT_CENTER, 120, 15,
						Color(1.0, 0.6, 0.2, base_a))

		# 队友名牌：绿色，不画血条——队友的血量已经在 HUD 左下的小字里，
		# 战场上只需要"那是谁、在哪个方向"。本地玩家自己不画。
		for t in g.players:
			if not is_instance_valid(t) or not t.alive or t == p:
				continue
			var world: Vector3 = t.global_position + Vector3(0, 2.8, 0)
			if cam.is_position_behind(world):
				continue
			var sp: Vector2 = cam.unproject_position(world)
			if sp.x < -80.0 or sp.y < -40.0 or sp.x > size.x + 80.0 or sp.y > size.y + 40.0:
				continue
			var nm := String(t.get("display_name"))
			if nm.is_empty():
				nm = "队友"
			var a: float = clampf(1.2 - eye.distance_to(t.global_position) / (Radar.RANGE + 6.0),
					0.35, 0.95)
			draw_string(ThemeDB.fallback_font, sp + Vector2(-60, 0),
					nm, HORIZONTAL_ALIGNMENT_CENTER, 120, 14,
					Color(0.55, 1.0, 0.65, a))


## 受击暗角：被击中时屏幕边缘压红，血量低于 25% 时持续搏动。
## 原来被击中的唯一提示是血条变化与方向环，180° 外的视角下几乎察觉不到；
## 暗角的作用是"不用看 HUD 也知道自己挨打了"。
class Vignette extends Control:
	var hud: HUD

	func _draw() -> void:
		var g = hud.game
		if g == null:
			return
		var p = g.player
		var v: float = g.hit_vignette
		var low := 0.0
		if p != null and is_instance_valid(p) and p.alive and p.hp < p.max_hp * 0.25:
			low = 0.16 + 0.10 * (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006))
		var a: float = clampf(v * 0.55 + low, 0.0, 0.62)
		if a <= 0.004:
			return
		# 没有渐变矩形可用，就用几层递减的窄条拼出柔边
		var band: float = minf(size.x, size.y) * 0.20
		for i in 6:
			var t := float(i) / 6.0
			var al: float = a * (1.0 - t) * (1.0 - t) * 0.30
			var d: float = band * t
			var step := band / 6.0
			draw_rect(Rect2(0, d, size.x, step), Color(0.72, 0.05, 0.04, al))
			draw_rect(Rect2(0, size.y - d - step, size.x, step), Color(0.72, 0.05, 0.04, al))
			draw_rect(Rect2(d, 0, step, size.y), Color(0.72, 0.05, 0.04, al))
			draw_rect(Rect2(size.x - d - step, 0, step, size.y), Color(0.72, 0.05, 0.04, al))
