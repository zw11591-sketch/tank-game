class_name RunState
extends Node
## Roguelite 单局状态（autoload `Run`）：关卡、战区、战功、卡牌、修正、数值重算。
##
## 这一层刻意**不引用任何节点**：它只保存与计算，于是
##   * 联机快照可以直接序列化（net_row / apply_row）；
##   * 探针可以在无头模式下推进整局，不必建场景；
##   * main.gd 只负责"什么时候调用"，不必把规则塞进 2400 行里。
##
## 规格见 docs/design/01_run_structure.md 与 03_economy_and_meta.md。

signal changed
signal offer_ready(offer: Array, stage: int)
signal run_finished(won: bool, payout: int)

const STAGES_PER_ZONE := 3
const ZONE_COUNT := 3
const TOTAL_STAGES := STAGES_PER_ZONE * ZONE_COUNT
## 总开关：关掉后 begin_run 不会激活 Run，main 退回旧的 8 关流程（见 06 文档"回退"）。
const ENABLED := true

enum Kind { CLEAR, HOLD, BOSS }
## 每个战区的三关固定为 歼灭 / 坚守 / 决战。
const KIND_BY_SLOT := [Kind.CLEAR, Kind.HOLD, Kind.BOSS]
const KIND_NAMES := ["歼灭", "坚守", "决战"]
const ZONE_NAMES := ["边境哨线", "工业纵深", "核心要塞"]
## 战区倍率：乘在敌人 HP 与伤害上，与 Enemy.configure 的关卡成长叠加。
const ZONE_HP := [1.0, 1.15, 1.30]
const ZONE_DAMAGE := [1.0, 1.08, 1.16]

## 击毁战功：侦察 / 中型 / 重型 / 火炮 / Boss。
const KILL_CREDITS := [2, 3, 5, 6, 15]
## 跳过卡牌的补偿战功。
const SKIP_CREDITS := 30

var active := false
var won := false
var stage := 1
var credits := 0
var tank_id := ""
var diff := 1
var challenge := Mutators.NONE
var mutators: Array[String] = []

var cards: Array[String] = []
var counts: Dictionary = {}
var mods: Dictionary = {}
var flags: Dictionary = {}
var offer: Array[String] = []

var rerolls := 0
var seed_value := 0
var rng := RandomNumberGenerator.new()
var started_ms := 0
## apply_row 的轻量签名：联机快照 25 Hz，内容没变就不重算 mods。
var _row_sig := ""
## mods 版本号：每次重算自增。main 用它判断"要不要把卡牌加成重新套到车上"，
## 避免 25 Hz 的快照把每辆车每帧重算一遍（重算会按比例回填血量）。
var mods_version := 0
## 结算时的战功与转化结果，供结算页显示。
var final_credits := 0
var final_payout := 0


func _ready() -> void:
	mods = UpgradeCards.base_mods()
	flags = {"kill_explode": false}


# ---------------- 生命周期 ----------------

## 开始一局。必须在 Stats.begin_run() 之前/之后都可调用——它只读写自己的字段。
func begin_run(p_tank: String, p_diff: int, p_challenge: int = Mutators.NONE) -> void:
	active = ENABLED
	won = false
	stage = 1
	tank_id = p_tank
	diff = p_diff
	challenge = p_challenge
	cards.clear()
	counts.clear()
	offer.clear()
	rerolls = 0
	final_credits = 0
	final_payout = 0
	seed_value = int(Time.get_ticks_usec() % 2147483647)
	rng.seed = seed_value
	_row_sig = ""
	mutators = Mutators.for_challenge(challenge, seed_value)
	mods = UpgradeCards.base_mods()
	flags = {"kill_explode": false}
	credits = Meta.start_credits()
	started_ms = Time.get_ticks_msec()
	changed.emit()


## 一局结束：战功按结果转化给长期存档。
## 返回实际获得的补给券，结算页直接显示这个数。
func finish(p_won: bool) -> int:
	if not active:
		return 0
	active = false
	won = p_won
	final_credits = credits
	var rate := 1.0 if p_won else 0.5
	if challenge == Mutators.DAILY:
		rate *= 1.1
	final_payout = int(floor(float(credits) * rate))
	Meta.add_credits(final_payout)
	Meta.note_run(p_won, stage, challenge)
	run_finished.emit(p_won, final_payout)
	return final_payout


func abort() -> void:
	active = false
	offer.clear()


# ---------------- 关卡与战区 ----------------

func stage_kind() -> int:
	return int(KIND_BY_SLOT[(clampi(stage, 1, TOTAL_STAGES) - 1) % STAGES_PER_ZONE])


func kind_name() -> String:
	return KIND_NAMES[clampi(stage_kind(), 0, 2)]


func zone_index() -> int:
	return clampi(int((clampi(stage, 1, TOTAL_STAGES) - 1) / 3.0), 0, ZONE_COUNT - 1)


func zone_name() -> String:
	return ZONE_NAMES[zone_index()]


func stage_in_zone() -> int:
	return (clampi(stage, 1, TOTAL_STAGES) - 1) % STAGES_PER_ZONE + 1


func is_final_stage() -> bool:
	return stage >= TOTAL_STAGES


## 每 3 关是战区末尾：打完这关出现补给站。
func is_zone_end() -> bool:
	return stage % STAGES_PER_ZONE == 0


## is_zone_end() 的纯函数版：探针要逐关检查而不想反复改 stage。
func stage_is_zone_end(s: int) -> bool:
	return clampi(s, 1, TOTAL_STAGES) % STAGES_PER_ZONE == 0


func is_hold() -> bool:
	return stage_kind() == Kind.HOLD


func is_boss() -> bool:
	return stage_kind() == Kind.BOSS


## 坚守时长（秒）。blitz 修正把它缩短 20%。
func hold_seconds() -> float:
	return (45.0 + float(stage) * 3.0) * Mutators.factor(mutators, "hold_time")


## 本关敌人总数。人海修正 +25%。
func enemy_budget() -> int:
	var n: int = mini(26, 9 + stage * 2)
	return int(round(float(n) * Mutators.factor(mutators, "enemy_count")))


func zone_hp_mult() -> float:
	return ZONE_HP[zone_index()]


func zone_damage_mult() -> float:
	return ZONE_DAMAGE[zone_index()]


## 敌人受到的伤害系数（硬化修正）。
func enemy_damage_taken() -> float:
	return Mutators.factor(mutators, "enemy_dr")


## 敌人装填系数（弹雨修正）。
func enemy_reload_mult() -> float:
	return Mutators.factor(mutators, "enemy_reload")


func enemy_damage_mult() -> float:
	return Mutators.factor(mutators, "enemy_damage")


## 本局开局命数：基础 3 + 元升级 + 卡牌（不死鸟）。
func starting_lives() -> int:
	return 3 + Meta.start_lives() + int(float(mods.get("lives", 0.0)))


# ---------------- 经济 ----------------

func add_credits(raw: int) -> void:
	if raw == 0:
		return
	var gain := int(round(float(raw) * credit_mult()))
	credits = maxi(0, credits + gain)
	changed.emit()


func credit_mult() -> float:
	return float(mods.get("credits", 1.0)) * Mutators.factor(mutators, "credit")


func award_stage() -> int:
	var raw := 30 + stage * 8
	var before := credits
	add_credits(raw)
	return credits - before


func award_kill(etype: int) -> int:
	var raw: int = KILL_CREDITS[clampi(etype, 0, KILL_CREDITS.size() - 1)]
	var before := credits
	add_credits(raw)
	return credits - before


func reroll_price() -> int:
	var base := 40 + 20 * int(cards.size() / 3.0)
	return maxi(10, int(round(float(base) * Meta.reroll_mult())))


func can_reroll() -> bool:
	return credits >= reroll_price()


## 扣款。补给站与重掷共用这一条，保证 credits 不会变成负数。
func spend(n: int) -> bool:
	if n <= 0 or credits < n:
		return false
	credits -= n
	changed.emit()
	return true


# ---------------- 卡牌 ----------------

## 抽三选一并发信号。返回抽到的 offer，方便探针直接断言。
func roll_offer() -> Array[String]:
	offer = UpgradeCards.roll_offer(rng, counts, 3, stage, diff)
	offer_ready.emit(offer.duplicate(), stage)
	changed.emit()
	return offer


func reroll() -> bool:
	if not can_reroll():
		return false
	credits -= reroll_price()
	rerolls += 1
	roll_offer()
	return true

func skip_offer() -> void:
	# 跳过补偿是固定 30，不乘战功系数：它是"止损"，不是收益来源。
	credits += SKIP_CREDITS
	offer.clear()
	changed.emit()


func pick_card(id: String) -> bool:
	if not UpgradeCards.has(id):
		return false
	if int(counts.get(id, 0)) >= int(UpgradeCards.info(id)["max"]):
		return false
	cards.append(id)
	counts[id] = int(counts.get(id, 0)) + 1
	offer.clear()
	recompute()
	return true


## 补给站的"战术档案"：直接塞一张随机稀有/史诗卡，无视 offer。
func grant_random_card(rarity_min: int = 1) -> String:
	var pool: Array = []
	for id in UpgradeCards.CARDS.keys():
		var info: Dictionary = UpgradeCards.CARDS[id]
		if int(info["rarity"]) >= rarity_min \
				and int(counts.get(id, 0)) < int(info["max"]):
			pool.append(id)
	if pool.is_empty():
		return ""
	var pick := String(pool[rng.randi_range(0, pool.size() - 1)])
	pick_card(pick)
	return pick


## 从卡牌列表重算全部修正。这是唯一允许写 mods 的地方。
func recompute() -> void:
	mods = UpgradeCards.base_mods()
	flags = {"kill_explode": false}
	for id in cards:
		UpgradeCards.accumulate(mods, flags, id)
	# 装填连乘下限：不允许靠叠卡把装填压成 0，否则"点击必出弹"会退化成机枪。
	mods["reload"] = maxf(float(mods["reload"]), 0.35)
	mods_version += 1
	changed.emit()


## 把当前修正应用到一辆玩家坦克。调用点：main._spawn_player()。
func apply_to_tank(t) -> void:
	if t == null or not is_instance_valid(t):
		return
	if t.has_method("apply_run_mods"):
		t.apply_run_mods(mods)


func owns_card(id: String) -> bool:
	return int(counts.get(id, 0)) > 0


## 结算页的"选过的强化"一行。
func cards_summary() -> String:
	if cards.is_empty():
		return "—"
	var parts: Array = []
	for id in counts.keys():
		var n := int(counts[id])
		var nm := String(UpgradeCards.info(String(id))["name"])
		parts.append(nm if n <= 1 else "%s ×%d" % [nm, n])
	return "  ".join(parts)


# ---------------- 联机 ----------------

## 房主打包给客户端的最小状态。offer 也带上，客户端才能显示同一组卡。
func net_row() -> Dictionary:
	return {
		"active": active,
		"stage": stage,
		"kind": stage_kind(),
		"credits": credits,
		"cards": cards.duplicate(),
		"offer": offer.duplicate(),
		"rerolls": rerolls,
		"mutators": mutators.duplicate(),
		# diff / challenge 必须一起下发：客户端要靠 challenge 算每日挑战的 1.1 倍转化，
		# 要靠 diff 显示正确的难度；只发 mutators 的话结算页会和房主差 10%。
		"diff": diff,
		"challenge": challenge,
	}


## 客户端应用房主状态。重算 mods，于是远端车与本地车拥有相同的卡牌加成。
##
## 快照 25 Hz 到达，如果每次都 emit changed，main 就会每帧重算所有车的卡牌。
## 所以先比一个轻量签名，内容没变就直接返回。
func apply_row(d: Dictionary) -> void:
	var next_stage := clampi(int(d.get("stage", stage)), 1, TOTAL_STAGES)
	var next_credits := int(d.get("credits", credits))
	var next_rerolls := int(d.get("rerolls", rerolls))
	var raw_cards = d.get("cards", [])
	var next_cards: Array[String] = []
	if raw_cards is Array:
		for c in raw_cards:
			if UpgradeCards.has(String(c)):
				next_cards.append(String(c))
	var raw_offer = d.get("offer", [])
	var next_offer: Array[String] = []
	if raw_offer is Array:
		for c in raw_offer:
			if UpgradeCards.has(String(c)):
				next_offer.append(String(c))
	var raw_mut = d.get("mutators", [])
	var next_mut: Array[String] = []
	if raw_mut is Array:
		for m in raw_mut:
			next_mut.append(String(m))
	var next_active := bool(d.get("active", true))
	var next_diff := clampi(int(d.get("diff", diff)), 0, 2)
	var next_challenge := clampi(int(d.get("challenge", challenge)), 0, 2)

	var sig := "%s|%d|%d|%d|%s|%s|%s|%d|%d" % [
		str(next_active), next_stage, next_credits, next_rerolls,
		str(next_cards), str(next_offer), str(next_mut), next_diff, next_challenge,
	]
	if sig == _row_sig:
		return
	_row_sig = sig

	active = next_active
	stage = next_stage
	credits = next_credits
	rerolls = next_rerolls
	cards = next_cards
	offer = next_offer
	mutators = next_mut
	diff = next_diff
	challenge = next_challenge
	counts.clear()
	for id in cards:
		counts[id] = int(counts.get(id, 0)) + 1
	recompute()
	changed.emit()


## 客户端应用房主的"选卡"事件（不重算 offer 之外的东西）。
func apply_pick(id: String) -> void:
	if not UpgradeCards.has(id):
		return
	if int(counts.get(id, 0)) >= int(UpgradeCards.info(id)["max"]):
		return
	cards.append(id)
	counts[id] = int(counts.get(id, 0)) + 1
	recompute()


## HUD 用的一行摘要。
func hud_summary() -> String:
	return "战区 %d/%d · 第 %d 关 %s" % [
		zone_index() + 1, ZONE_COUNT, stage, kind_name(),
	]


func elapsed_seconds() -> float:
	if started_ms <= 0:
		return 0.0
	return float(Time.get_ticks_msec() - started_ms) / 1000.0