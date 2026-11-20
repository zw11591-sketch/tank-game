class_name UpgradeCards
## Roguelite 强化卡牌表（纯数据 + 纯函数，不依赖场景树）。
##
## 卡牌不是"数值皮肤"：每张卡都必须在**怎么打**上留下痕迹，或者明确接受一条代价。
## 乘性键与加性键的语义写在 consts 里，累加逻辑由 RunState.recompute() 调用
## accumulate() 完成，所以探针可以脱离游戏直接验证数值。
##
## 规格见 docs/design/02_cards.md；新增卡牌必须同时更新那张表与本文件的 CARDS，
## 否则 tools/run_probe.gd 的"卡表完整性"会失败。

const RARITY_NAMES := ["常规", "稀有", "史诗"]
## 稀有度基础权重。困难难度给史诗额外权重（见 rarity_weight）。
const RARITY_WEIGHTS := [60, 30, 10]
const RARITY_COLORS := [
	Color(0.73, 0.76, 0.80),
	Color(0.35, 0.66, 0.94),
	Color(0.94, 0.70, 0.29),
]

## 乘性键：卡牌值相乘，默认 1.0。
const MUL_KEYS := [
	"damage", "reload", "hp", "armor", "speed", "turn", "turret",
	"he", "splash", "credits", "combo_window",
]
## 加性键：卡牌值相加，默认 0。
const ADD_KEYS := [
	"ricochet", "lifesteal", "cdr", "spawn_shield", "shells",
	"stage_heal", "lives",
]
## 标记键：布尔。
const FLAG_KEYS := ["kill_explode"]

## 全部卡牌。max 是叠加上限，超过后不再进入卡池。
##
## 数值约定：
##   reload < 1 表示装填变快；armor < 1 表示受伤减少；
##   ricochet 是"降低跳弹阈值角"的度数，越大越硬。
const CARDS := {
	# ---------------- 常规（14） ----------------
	"ap_round": {
		"name": "穿甲强化", "rarity": 0, "max": 3,
		"desc": "单发伤害 +12%",
		"mods": {"damage": 1.12},
	},
	"he_charge": {
		"name": "高爆装药", "rarity": 0, "max": 3,
		"desc": "HE 直击伤害 +20%",
		"mods": {"he": 1.20},
	},
	"loader": {
		"name": "快速装填", "rarity": 0, "max": 3,
		"desc": "装填时间 −8%",
		"mods": {"reload": 0.92},
	},
	"plate": {
		"name": "加厚钢板", "rarity": 0, "max": 3,
		"desc": "结构上限 +12%",
		"mods": {"hp": 1.12},
	},
	"composite": {
		"name": "复合装甲", "rarity": 0, "max": 3,
		"desc": "受到伤害 −8%",
		"mods": {"armor": 0.92},
	},
	"engine_tune": {
		"name": "引擎调校", "rarity": 0, "max": 3,
		"desc": "极速 +8%",
		"mods": {"speed": 1.08},
	},
	"gearbox": {
		"name": "传动升级", "rarity": 0, "max": 2,
		"desc": "车体转向 +10%",
		"mods": {"turn": 1.10},
	},
	"turret_motor": {
		"name": "炮塔电机", "rarity": 0, "max": 2,
		"desc": "炮塔回转 +12%",
		"mods": {"turret": 1.12},
	},
	"frag": {
		"name": "破片弹头", "rarity": 0, "max": 2,
		"desc": "HE 溅射半径 +20%",
		"mods": {"splash": 1.20},
	},
	"deflector": {
		"name": "跳弹导流", "rarity": 0, "max": 2,
		"desc": "跳弹阈值角 −5°（更硬的正面）",
		"mods": {"ricochet": 5.0},
	},
	"field_repair": {
		"name": "战地维修", "rarity": 0, "max": 2,
		"desc": "每关开始回复 20% 结构",
		"mods": {"stage_heal": 0.20},
	},
	"war_bond": {
		"name": "战功勋章", "rarity": 0, "max": 2,
		"desc": "战功收入 +20%",
		"mods": {"credits": 1.20},
	},
	"combo_ext": {
		"name": "连击延展", "rarity": 0, "max": 2,
		"desc": "连击窗口 +30%",
		"mods": {"combo_window": 1.30},
	},
	"optics": {
		"name": "瞄准镜组", "rarity": 0, "max": 2,
		"desc": "炮塔回转 +8%，跳弹阈值角 −2°",
		"mods": {"turret": 1.08, "ricochet": 2.0},
	},

	# ---------------- 稀有（10） ----------------
	"twin_barrel": {
		"name": "双联炮座", "rarity": 1, "max": 1,
		"desc": "每次击发 +1 发，单发伤害 −15%",
		"mods": {"shells": 1, "damage": 0.85},
	},
	"vampiric": {
		"name": "吸血装甲", "rarity": 1, "max": 3,
		"desc": "造成伤害的 4% 回复结构",
		"mods": {"lifesteal": 0.04},
	},
	"detonate": {
		"name": "殉爆药", "rarity": 1, "max": 1,
		"desc": "击毁敌车时引发半径 6 m 爆炸",
		"mods": {},
		"flags": ["kill_explode"],
	},
	"reactive": {
		"name": "反应装甲", "rarity": 1, "max": 2,
		"desc": "出生自带 4 秒护盾",
		"mods": {"spawn_shield": 4.0},
	},
	"siege_he": {
		"name": "攻城高爆", "rarity": 1, "max": 2,
		"desc": "溅射半径 +35%，HE 伤害 +15%",
		"mods": {"splash": 1.35, "he": 1.15},
	},
	"cooling": {
		"name": "冷却回路", "rarity": 1, "max": 2,
		"desc": "冲刺与烟雾冷却 −15%",
		"mods": {"cdr": 0.15},
	},
	"predator": {
		"name": "猎杀本能", "rarity": 1, "max": 2,
		"desc": "伤害 +20%，结构上限 −10%",
		"mods": {"damage": 1.20, "hp": 0.90},
	},
	"bunker": {
		"name": "装甲套件", "rarity": 1, "max": 1,
		"desc": "结构上限 +20%，极速 −6%",
		"mods": {"hp": 1.20, "speed": 0.94},
	},
	"sharpshooter": {
		"name": "尖兵", "rarity": 1, "max": 1,
		"desc": "跳弹阈值角 −8°",
		"mods": {"ricochet": 8.0},
	},
	"scavenger": {
		"name": "战地回收", "rarity": 1, "max": 2,
		"desc": "战功收入 +40%",
		"mods": {"credits": 1.40},
	},

	# ---------------- 史诗（6） ----------------
	"annihilator": {
		"name": "灭绝者", "rarity": 2, "max": 1,
		"desc": "伤害 +30%，装填时间 +10%",
		"mods": {"damage": 1.30, "reload": 1.10},
	},
	"phoenix": {
		"name": "不死鸟", "rarity": 2, "max": 1,
		"desc": "本局多 1 条命",
		"mods": {"lives": 1},
	},
	"bastion": {
		"name": "钢铁壁垒", "rarity": 2, "max": 1,
		"desc": "受到伤害 −18%，结构上限 +15%",
		"mods": {"armor": 0.82, "hp": 1.15},
	},
	"barrage": {
		"name": "弹幕风暴", "rarity": 2, "max": 1,
		"desc": "每次击发 +2 发，单发伤害 −30%",
		"mods": {"shells": 2, "damage": 0.70},
	},
	"bloodking": {
		"name": "吸血之王", "rarity": 2, "max": 1,
		"desc": "造成伤害的 10% 回复结构",
		"mods": {"lifesteal": 0.10},
	},
	"overhaul": {
		"name": "全面改装", "rarity": 2, "max": 1,
		"desc": "伤害、结构、极速各 +10%",
		"mods": {"damage": 1.10, "hp": 1.10, "speed": 1.10},
	},
}


static func has(id: String) -> bool:
	return CARDS.has(id)


static func info(id: String) -> Dictionary:
	if not CARDS.has(id):
		return {"name": "未知强化", "rarity": 0, "max": 0, "desc": "", "mods": {}}
	return CARDS[id]


static func ids() -> Array:
	return CARDS.keys()


static func rarity_weight(r: int, stage: int, diff: int) -> int:
	var w: int = RARITY_WEIGHTS[clampi(r, 0, 2)]
	if r == 2:
		var zone: int = int((maxi(stage, 1) - 1) / 3.0)
		w += zone * 2
		if diff == 2:
			w += 5
	return w


## 抽三选一。
##
## 规则（docs/design/02_cards.md 第 5 节）：
##   * 候选 = 未叠满的卡；
##   * 三张互不重复；
##   * 从第 2 关起，若三张全为常规，第三张替换为稀有或史诗。
static func roll_offer(rng: RandomNumberGenerator, counts: Dictionary,
		count: int = 3, stage: int = 1, diff: int = 1) -> Array[String]:
	var pool: Array = []
	for id in CARDS.keys():
		var owned: int = int(counts.get(id, 0))
		if owned < int(CARDS[id]["max"]):
			pool.append(id)

	var out: Array[String] = []
	while out.size() < count and pool.size() > 0:
		var pick := _weighted_pick(rng, pool, stage, diff)
		if pick == "":
			break
		out.append(pick)
		pool.erase(pick)

	if stage >= 2 and out.size() >= count:
		var has_above_common := false
		for id in out:
			if int(CARDS[id]["rarity"]) >= 1:
				has_above_common = true
				break
		if not has_above_common:
			var upgrades: Array = []
			for id in pool:
				if int(CARDS[id]["rarity"]) >= 1:
					upgrades.append(id)
			if upgrades.size() > 0:
				out[out.size() - 1] = _weighted_pick(rng, upgrades, stage, diff)
	return out


static func _weighted_pick(rng: RandomNumberGenerator, pool: Array,
		stage: int, diff: int) -> String:
	var total := 0
	var weights: Array = []
	for id in pool:
		var w := rarity_weight(int(CARDS[id]["rarity"]), stage, diff)
		weights.append(w)
		total += w
	if total <= 0:
		return ""
	var roll := rng.randi_range(1, total)
	var acc := 0
	for i in pool.size():
		acc += int(weights[i])
		if roll <= acc:
			return String(pool[i])
	return String(pool[pool.size() - 1])


## 把一张卡累加进 mods / flags。乘性键相乘、加性键相加、标记键置真。
static func accumulate(mods: Dictionary, flags: Dictionary, id: String) -> void:
	if not CARDS.has(id):
		return
	var card: Dictionary = CARDS[id]
	var m: Dictionary = card.get("mods", {})
	for k in m.keys():
		var key := String(k)
		var v: float = float(m[k])
		# 只有文档列出的加性键才相加；其余（damage / reload / hp …）一律相乘。
		# 不能按"当前键是否存在加性键表"判断——两者是同一个表，永远为真。
		if key in ADD_KEYS:
			mods[key] = float(mods.get(key, 0.0)) + v
		else:
			mods[key] = float(mods.get(key, 1.0)) * v
	for f in card.get("flags", []):
		flags[String(f)] = true


## 初始 mods。所有乘性键为 1、加性键为 0，未列出的键读取时一律回落到这两个默认值。
static func base_mods() -> Dictionary:
	var m := {}
	for k in MUL_KEYS:
		m[k] = 1.0
	for k in ADD_KEYS:
		m[k] = 0.0
	return m


## 卡面副标题：稀有度 + 已持有数量。
static func subtitle(id: String, owned: int) -> String:
	var r := int(info(id)["rarity"])
	var s := "%s · 已持有 %d 张" % [RARITY_NAMES[clampi(r, 0, 2)], owned]
	if owned >= int(info(id)["max"]):
		s += "（已满）"
	return s
