extends Node
## Roguelite 数据层验收：卡表、抽卡、修正累加、经济、境界、跳弹、词缀、修正、
## 元进度与存档、联机行。
##
## 只读数据层 + 一个真实玩家做跳弹判定，不截图、不开窗口，所以能进 CI。
## 判据与 `docs/design/06_tech_and_acceptance.md` 第 4.2 节一一对应。
##
## 用法：godot.exe --headless --path . res://tools/RunProbe.tscn
##
## 注意：元进度相关的几项会临时改写 `user://meta.cfg`，探针退出前会原样还原。

var _fail := 0
var _pass := 0
var _main: Node
var _meta_saved: Dictionary = {}


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_meta_saved = _snap_meta()

	_test_card_table()
	_test_offers()
	_test_mods()
	_test_economy()
	_test_stages()
	_test_affix()
	_test_mutators()
	_test_meta()
	_restore_meta(_meta_saved)
	_test_net_row()
	await _test_ricochet()
	Run.abort()

	print("")
	if _fail == 0:
		print("PROBE RUN OK  (%d 项)" % _pass)
	else:
		print("PROBE RUN FAIL  fail=%d pass=%d" % [_fail, _pass])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
		print("PROBE %-26s OK   %s" % [name, detail])
	else:
		_fail += 1
		print("PROBE %-26s FAIL %s" % [name, detail])


# ---------------- 卡表 ----------------

func _test_card_table() -> void:
	var ids: Array = UpgradeCards.CARDS.keys()
	_check("cards.count", ids.size() == 30, "count=%d" % ids.size())

	var legal: Array = []
	legal.append_array(UpgradeCards.MUL_KEYS)
	legal.append_array(UpgradeCards.ADD_KEYS)

	var bad_key := ""
	var bad_max := ""
	var bad_rarity := ""
	var bad_name := ""
	var bad_flag := ""
	var seen: Dictionary = {}
	var dup := ""
	for id in ids:
		var key := String(id)
		if seen.has(key):
			dup = key
		seen[key] = true
		var info: Dictionary = UpgradeCards.CARDS[id]
		for k in info.get("mods", {}).keys():
			if not (String(k) in legal):
				bad_key = "%s.%s" % [key, k]
		for f in info.get("flags", []):
			if not (String(f) in UpgradeCards.FLAG_KEYS):
				bad_flag = "%s.%s" % [key, f]
		if int(info.get("max", 0)) <= 0:
			bad_max = key
		if int(info.get("rarity", -1)) < 0 or int(info["rarity"]) > 2:
			bad_rarity = key
		var nm := String(info.get("name", ""))
		if nm.length() < 2 or nm.length() > 4:
			bad_name = "%s(%d)" % [nm, nm.length()]
		if String(info.get("desc", "")).is_empty():
			bad_name = "%s 缺描述" % key
	_check("cards.unique", dup.is_empty(), dup)
	_check("cards.mods_keys", bad_key.is_empty(), bad_key)
	_check("cards.flags", bad_flag.is_empty(), bad_flag)
	_check("cards.max", bad_max.is_empty(), bad_max)
	_check("cards.rarity", bad_rarity.is_empty(), bad_rarity)
	_check("cards.names", bad_name.is_empty(), bad_name)
	_check("cards.base_mods",
			float(UpgradeCards.base_mods()["damage"]) == 1.0
			and float(UpgradeCards.base_mods()["ricochet"]) == 0.0)


# ---------------- 抽卡 ----------------

func _test_offers() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261119
	var fresh: Dictionary = {}
	var dup := 0
	var short := 0
	var no_guarantee := 0
	for i in 200:
		var offer := UpgradeCards.roll_offer(rng, fresh, 3, 6, 1)
		if offer.size() != 3:
			short += 1
		var seen: Dictionary = {}
		for id in offer:
			if seen.has(id):
				dup += 1
			seen[id] = true
		var any_above := false
		for id in offer:
			if int(UpgradeCards.CARDS[id]["rarity"]) >= 1:
				any_above = true
		if not any_above:
			no_guarantee += 1
	_check("offers.size", short == 0, "short=%d" % short)
	_check("offers.unique", dup == 0, "dup=%d" % dup)
	_check("offers.guarantee", no_guarantee == 0, "all_common=%d" % no_guarantee)

	# 叠满的卡不再出现：把 ap_round 视为 3 张，抽 300 次都不该再看到它
	var capped := {"ap_round": 3}
	var leaked := 0
	for i in 300:
		if String("ap_round") in UpgradeCards.roll_offer(rng, capped, 3, 8, 2):
			leaked += 1
	_check("offers.cap", leaked == 0, "leaked=%d" % leaked)

	# 所有卡都叠满时返回空表，而不是三张重复的满级卡
	var full: Dictionary = {}
	for id in UpgradeCards.CARDS.keys():
		full[id] = int(UpgradeCards.CARDS[id]["max"])
	var empty := UpgradeCards.roll_offer(rng, full, 3, 9, 1)
	_check("offers.exhausted", empty.is_empty(), "size=%d" % empty.size())


# ---------------- 修正累加 ----------------

func _test_mods() -> void:
	Run.begin_run("falcon", 1, Mutators.NONE)
	Run.pick_card("ap_round")
	Run.pick_card("ap_round")
	Run.pick_card("loader")
	Run.pick_card("deflector")
	Run.pick_card("twin_barrel")
	var dmg := float(Run.mods["damage"])
	var reload := float(Run.mods["reload"])
	var ric := float(Run.mods["ricochet"])
	var shells := int(Run.mods["shells"])
	_check("mods.multiply", absf(dmg - 1.12 * 1.12 * 0.85) < 1e-6, "damage=%.6f" % dmg)
	_check("mods.reload", absf(reload - 0.92) < 1e-6, "reload=%.6f" % reload)
	_check("mods.add", absf(ric - 5.0) < 1e-6 and shells == 1,
			"ricochet=%.2f shells=%d" % [ric, shells])
	_check("mods.counts", int(Run.counts.get("ap_round", 0)) == 2
			and Run.cards.size() == 5, "cards=%d" % Run.cards.size())

	# 叠满后 pick 被拒，计数不涨
	var refused := not Run.pick_card("twin_barrel") and int(Run.counts["twin_barrel"]) == 1
	_check("mods.cap_refuse", refused)

	# 幂等：重算两次结果相同（重复 apply 不会越叠越高）
	var before := float(Run.mods["hp"])
	Run.recompute()
	Run.recompute()
	_check("mods.idempotent", absf(float(Run.mods["hp"]) - before) < 1e-9)

	# 跳弹阈值落到车上：游隼默认 45°，叠两张导流板后 45 − 5 − 5 = 35
	Run.begin_run("falcon", 1, Mutators.NONE)
	Run.pick_card("deflector")
	Run.pick_card("deflector")
	var p := Player.new()
	p.max_hp = 400
	p.hp = 400
	p.ricochet_angle = 45.0
	p.apply_run_mods(Run.mods, true)
	_check("mods.ricochet_tank", absf(p.ricochet_angle - 35.0) < 1e-6,
			"angle=%.1f" % p.ricochet_angle)
	p.free()


# ---------------- 经济 ----------------

func _test_economy() -> void:
	Meta.upgrades = {}
	Run.begin_run("falcon", 1, Mutators.NONE)
	Run.credits = 0
	Run.stage = 1
	var g1 := Run.award_stage()
	Run.stage = 5
	var g5 := Run.award_stage()
	_check("economy.stage_reward", g1 == 38 and g5 == 70, "%d / %d" % [g1, g5])

	Run.credits = 0
	var kills: Array = []
	for t in 5:
		kills.append(Run.award_kill(t))
	_check("economy.kill_reward", kills == [2, 3, 5, 6, 15], str(kills))

	Run.cards.clear()
	Run.counts.clear()
	Run.credits = 500
	var price0 := Run.reroll_price()
	_check("economy.reroll_price0", price0 == 40, "price=%d" % price0)
	Run.pick_card("ap_round")
	Run.pick_card("plate")
	Run.pick_card("loader")
	var price3 := Run.reroll_price()
	_check("economy.reroll_price3", price3 == 60, "price=%d" % price3)

	var before_skip := Run.credits
	Run.skip_offer()
	_check("economy.skip", Run.credits - before_skip == 30,
			"+%d" % (Run.credits - before_skip))

	Run.credits = 10
	var refused := not Run.spend(20) and Run.credits == 10
	var paid := Run.spend(10) and Run.credits == 0
	_check("economy.spend", refused and paid, "credits=%d" % Run.credits)

	# 战功系数：战功勋章 ×1.2
	Run.credits = 0
	Run.pick_card("war_bond")
	Run.add_credits(100)
	_check("economy.credit_mult", Run.credits == 120, "credits=%d" % Run.credits)


# ---------------- 境界 ----------------

func _test_stages() -> void:
	Run.begin_run("falcon", 1, Mutators.NONE)
	var kinds: Array = []
	var zones: Array = []
	for i in range(1, 10):
		Run.stage = i
		kinds.append(Run.stage_kind())
		zones.append(Run.zone_index())
	var want_kinds: Array = [0, 1, 2, 0, 1, 2, 0, 1, 2]
	var want_zones: Array = [0, 0, 0, 1, 1, 1, 2, 2, 2]
	_check("stages.kinds", kinds == want_kinds, str(kinds))
	_check("stages.zones", zones == want_zones, str(zones))
	_check("stages.zone_end",
			Run.stage_is_zone_end(3) and Run.stage_is_zone_end(6)
			and Run.stage_is_zone_end(9))
	Run.stage = 2
	var hold := Run.hold_seconds()
	Run.mutators.clear()
	Run.mutators.append("blitz")
	var blitz := Run.hold_seconds()
	_check("stages.hold", absf(hold - 51.0) < 1e-6 and absf(blitz - 40.8) < 1e-6,
			"%.1f / %.1f" % [hold, blitz])
	Run.mutators.clear()
	Run.mutators.append("horde")
	Run.stage = 1
	var budget := Run.enemy_budget()
	_check("stages.horde", budget == int(round(11.0 * 1.25)), "budget=%d" % budget)


# ---------------- 词缀 ----------------

func _test_affix() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 991
	var early := 0
	for i in 50:
		if not EnemyAffix.roll(rng, 1, 0, []).is_empty():
			early += 1
	_check("affix.stage1_none", early == 0, "with_affix=%d" % early)

	var late_empty := 0
	var dup := 0
	var too_many := 0
	for i in 200:
		var a := EnemyAffix.roll(rng, 9, 0, [])
		if a.is_empty():
			late_empty += 1
		var seen: Dictionary = {}
		for id in a:
			if seen.has(id):
				dup += 1
			seen[id] = true
		if a.size() > EnemyAffix.MAX_AFFIX:
			too_many += 1
	_check("affix.stage9_present", late_empty == 0, "empty=%d" % late_empty)
	_check("affix.unique", dup == 0, "dup=%d" % dup)
	_check("affix.max", too_many == 0, "over=%d" % too_many)

	var boss := EnemyAffix.roll(rng, 9, 4, [])
	_check("affix.boss_min", boss.size() >= 2, "size=%d" % boss.size())

	var elite := EnemyAffix.roll(rng, 1, 0, ["elite"])
	_check("affix.elite_bonus", elite.size() >= 1, "size=%d" % elite.size())

	var e := Enemy.new()
	e.configure(2, 5, 1)
	var hp0 := e.max_hp
	var af0 := e.armor_front
	var sp0 := e.move_speed
	EnemyAffix.apply(e, ["armored"])
	var ok := absf(float(e.max_hp) - float(hp0) * 1.25) < 1.0 \
			and absf(e.armor_front - af0 * 0.72) < 1e-6 \
			and absf(e.move_speed - sp0 * 0.90) < 1e-6
	_check("affix.numbers", ok, "hp %d→%d" % [hp0, e.max_hp])
	var e2 := Enemy.new()
	e2.configure(4, 5, 1)
	e2.damage_scale = 0.88
	_check("affix.damage_taken", absf(e2.damage_taken_mult(Shell.Kind.AP) - 0.88) < 1e-6)
	e.free()
	e2.free()


# ---------------- 修正 ----------------

func _test_mutators() -> void:
	_check("mutators.factor",
			absf(Mutators.factor(["horde"], "enemy_count") - 1.25) < 1e-6
			and absf(Mutators.factor(["blitz"], "hold_time") - 0.8) < 1e-6)
	var elite := Mutators.for_challenge(Mutators.ELITE, 12345)
	_check("mutators.elite", elite.size() == 2 and "elite" in elite, str(elite))
	var d1 := Mutators.for_challenge(Mutators.DAILY, 0)
	var d2 := Mutators.for_challenge(Mutators.DAILY, 0)
	_check("mutators.daily", d1.size() == 2 and d1 == d2, str(d1))
	_check("mutators.none", Mutators.for_challenge(Mutators.NONE, 0).is_empty())


# ---------------- 元进度 ----------------

func _snap_meta() -> Dictionary:
	return {
		"credits": Meta.credits,
		"runs": Meta.runs,
		"wins": Meta.wins,
		"best_stage": Meta.best_stage,
		"challenge_clears": Meta.challenge_clears,
		"unlocked": Meta.unlocked.duplicate(true),
		"upgrades": Meta.upgrades.duplicate(true),
	}


func _restore_meta(s: Dictionary) -> void:
	Meta.credits = int(s["credits"])
	Meta.runs = int(s["runs"])
	Meta.wins = int(s["wins"])
	Meta.best_stage = int(s["best_stage"])
	Meta.challenge_clears = int(s["challenge_clears"])
	Meta.unlocked = (s["unlocked"] as Dictionary).duplicate(true)
	Meta.upgrades = (s["upgrades"] as Dictionary).duplicate(true)
	Meta.save_cfg()


func _test_meta() -> void:
	Meta.unlocked = {}
	Meta.upgrades = {}
	Meta.credits = 1000

	var unlocked_ok := Meta.unlock_tank("lynx") and Meta.is_tank_unlocked("lynx") \
			and Meta.credits == 650
	var again := not Meta.unlock_tank("lynx")
	_check("meta.unlock", unlocked_ok and again, "credits=%d" % Meta.credits)

	Meta.credits = 700
	var bought := Meta.buy_upgrade("lives") and Meta.upgrade_level("lives") == 1 \
			and Meta.credits == 100
	var poor := not Meta.buy_upgrade("lives")
	Meta.credits = 2000
	Meta.buy_upgrade("lives")
	var capped := Meta.upgrade_cost("lives") == -1 and not Meta.buy_upgrade("lives")
	_check("meta.upgrade", bought and poor and capped,
			"lives=%d" % Meta.upgrade_level("lives"))
	_check("meta.start_bonus", Meta.start_lives() == 2,
			"lives=%d" % Meta.start_lives())

	Meta.upgrades = {"reroll": 2, "credits": 2}
	_check("meta.bonuses", absf(Meta.reroll_mult() - 0.70) < 1e-6
			and Meta.start_credits() == 160,
			"reroll=%.2f credits=%d" % [Meta.reroll_mult(), Meta.start_credits()])

	Meta.upgrades = {}
	Run.begin_run("falcon", 1, Mutators.NONE)
	Run.credits = 100
	var lose := Run.finish(false)
	Run.begin_run("falcon", 1, Mutators.NONE)
	Run.credits = 100
	var win := Run.finish(true)
	Run.begin_run("falcon", 1, Mutators.DAILY)
	Run.credits = 100
	var daily := Run.finish(true)
	_check("meta.payout", lose == 50 and win == 100 and daily == 110,
			"%d / %d / %d" % [lose, win, daily])

	Meta.credits = 321
	Meta.runs = 7
	Meta.wins = 2
	Meta.best_stage = 6
	Meta.save_cfg()
	Meta._loaded = false
	Meta.load_cfg()
	_check("meta.save", Meta.credits == 321 and Meta.runs == 7
			and Meta.best_stage == 6 and Meta.wins == 2,
			"%d/%d/%d" % [Meta.credits, Meta.runs, Meta.best_stage])

	# 损坏的字典不该让启动失败
	Meta.unlocked = {"falcon": true, "nope": true}
	Meta.upgrades = {"lives": 99, "hacker": 5}
	Meta._sanitize()
	_check("meta.sanitize", not Meta.unlocked.has("nope")
			and not Meta.upgrades.has("hacker")
			and Meta.upgrade_level("lives") == 2, str(Meta.upgrades))


# ---------------- 联机行 ----------------

func _test_net_row() -> void:
	Run.begin_run("falcon", 1, Mutators.NONE)
	Run.pick_card("ap_round")
	Run.pick_card("loader")
	Run.roll_offer()
	Run.credits = 250
	Run.stage = 4
	var row := Run.net_row()
	var v_before := Run.mods_version

	Run.begin_run("lynx", 2, Mutators.ELITE)
	Run.apply_row(row)
	var ok := Run.stage == 4 and Run.credits == 250 \
			and Run.cards.size() == 2 and absf(float(Run.mods["damage"]) - 1.12) < 1e-6 \
			and int(Run.counts.get("ap_round", 0)) == 1 \
			and Run.mutators.is_empty()
	# 同一行再应用一次不该重复重算：签名相同直接返回
	var v_mid := Run.mods_version
	Run.apply_row(row)
	ok = ok and Run.mods_version == v_mid and v_mid != v_before
	_check("net.run_row", ok, "stage=%d cards=%d" % [Run.stage, Run.cards.size()])


# ---------------- 跳弹 ----------------

func _test_ricochet() -> void:
	_main = get_node("Main")
	_main._sel_tank = TankRoster.ORDER.find("falcon")
	_main._sel_diff = 1
	_main._sel_challenge = Mutators.NONE
	_main._sel_terrain = 0
	_main._confirm_start()
	_main.state = "play"
	_main.spawn_queue = []
	_main._spawn_t = 1.0e9
	_main._field_t = 1.0e9
	for _i in 6:
		await get_tree().physics_frame

	var p: Player = _main.player
	if p == null or not is_instance_valid(p):
		_check("ricochet.spawn", false, "no player")
		return
	p.shield_t = 0.0
	p.armor_buff_t = 0.0
	p.ricochet_angle = 45.0

	var from44 := _from_angle(p, 44.0)
	var from46 := _from_angle(p, 46.0)
	_check("ricochet.angle_math",
			absf(p.impact_angle(from44) - 44.0) < 0.5
			and absf(p.impact_angle(from46) - 46.0) < 0.5,
			"%.1f / %.1f" % [p.impact_angle(from44), p.impact_angle(from46)])

	var hit_count := 0
	var bounce_count := 0
	for i in 50:
		p.hp = p.max_hp
		if p.take_hit(1, from44, Shell.Kind.AP) in ["hit", "kill"]:
			hit_count += 1
		p.hp = p.max_hp
		if p.take_hit(1, from46, Shell.Kind.AP) == "ricochet":
			bounce_count += 1
	_check("ricochet.deterministic", hit_count == 50 and bounce_count == 50,
			"hit=%d bounce=%d" % [hit_count, bounce_count])
	_check("ricochet.hint_matches",
			not p.is_ricochet_angle(from44, Shell.Kind.AP)
			and p.is_ricochet_angle(from46, Shell.Kind.AP))

	# HE 不跳弹：同一角度必须打进装甲
	p.hp = p.max_hp
	var he := p.take_hit(1, from46, Shell.Kind.HE)
	_check("ricochet.he_never", he in ["hit", "kill"], he)

	# 卡牌把阈值拉到 35°：同一条 46° 的入射仍跳，而 40° 变成了跳弹
	Run.pick_card("deflector")
	Run.pick_card("deflector")
	p.apply_run_mods(Run.mods, false)
	p.shield_t = 0.0
	var from40 := _from_angle(p, 40.0)
	p.hp = p.max_hp
	var b40 := p.take_hit(1, from40, Shell.Kind.AP)
	_check("ricochet.card_threshold", absf(p.ricochet_angle - 35.0) < 1e-6
			and b40 == "ricochet", "angle=%.1f res=%s" % [p.ricochet_angle, b40])

	# 敌方按车型分化阈值（38°~52°）：同一发 39° 的正面 AP，
	# 重型必须跳、侦察必须穿；两端看到的是同一个值，准星提示才对得上结算。
	#
	# 敌车在这里只做数值判断，不进场景树——`impact_angle()` 用的是 global_transform，
	# 未入树的节点会报错，所以直接用角度本身比较（判据与 is_ricochet_angle 相同）。
	var th: Array = []
	for et in 5:
		var e := Enemy.new()
		e.configure(et, 1, 1)
		th.append(e.ricochet_angle)
		e.free()
	var ap := Shell.Kind.AP
	_check("ricochet.enemy_types",
			th[2] >= 38.0 and th[0] <= 52.0 and th[2] < th[1] and th[1] < th[0]
			and ap == Shell.Kind.AP and 39.0 > float(th[2]) and 39.0 < float(th[0]),
			"%s" % [th])

	_main._clear_battle()
	await get_tree().physics_frame


## 从坦克正面偏转 deg 度的方向放一个射手位置（12 m 外）。
func _from_angle(p: Player, deg: float) -> Vector3:
	var r := deg_to_rad(deg)
	var dir := Vector3(-sin(r), 0.0, -cos(r)).rotated(Vector3.UP, p.rotation.y)
	return p.global_position + dir * 12.0