class_name Mutators
## Run 级修正（挑战规则）：作用于整局，只影响敌人与计时，不改玩家数值。
##
## 修正存在的意义是把"同一套卡牌池"玩出不同压力：弹雨逼玩家算对射节奏、
## 人海逼玩家管地图空间、精英逼玩家读词缀。所以它们全部作用在**敌方与节奏**上，
## 而不是"玩家少 10% 血"这种无选择空间的惩罚。
##
## 规格见 docs/design/04_combat_rules.md 第 5 节。

const NONE := 0
const DAILY := 1
const ELITE := 2
const CHALLENGE_NAMES := ["标准行动", "每日挑战", "精英行动"]

## 修正表。取值为"乘法系数"，默认 1.0 = 不生效。
const DEFS := {
	"iron_rain": {"name": "弹雨", "desc": "敌人装填 −12%", "enemy_reload": 0.88},
	"horde": {"name": "人海", "desc": "敌人总数 +25%", "enemy_count": 1.25},
	"hardened": {"name": "硬化", "desc": "敌人受伤 −12%", "enemy_dr": 0.88},
	"elite": {"name": "精英", "desc": "所有敌人额外 1 条词缀", "affix_bonus": 1},
	"veteran": {"name": "老兵", "desc": "敌人伤害 +12%", "enemy_damage": 1.12},
	"blitz": {"name": "速攻", "desc": "坚守时间 −20%，战功 +20%", "hold_time": 0.8, "credit": 1.2},
}

const ORDER: Array[String] = [
	"iron_rain", "horde", "hardened", "elite", "veteran", "blitz",
]


## 由挑战类型生成修正列表。每日挑战用日期做种子，所以全世界同一天看到同一组修正。
static func for_challenge(kind: int, seed_value: int = 0) -> Array[String]:
	var out: Array[String] = []
	match kind:
		DAILY:
			var day := _day_index()
			var rng := RandomNumberGenerator.new()
			rng.seed = day * 7919 + 13
			var pool := ORDER.duplicate()
			while out.size() < 2 and pool.size() > 0:
				var i := rng.randi_range(0, pool.size() - 1)
				out.append(String(pool[i]))
				pool.remove_at(i)
		ELITE:
			out.append("elite")
			var rng2 := RandomNumberGenerator.new()
			rng2.seed = seed_value if seed_value != 0 else 20261119
			var others: Array = []
			for id in ORDER:
				if id != "elite":
					others.append(id)
			out.append(String(others[rng2.randi_range(0, others.size() - 1)]))
	return out


static func _day_index() -> int:
	var utc := Time.get_unix_time_from_system()
	return int(utc / 86400.0)


static func name_of(id: String) -> String:
	return String(DEFS.get(id, {"name": id})["name"])


static func desc_of(id: String) -> String:
	return String(DEFS.get(id, {"desc": ""})["desc"])


## 一条修正生效在某个字段上的系数。没有该字段时返回 1.0。
static func factor(ids: Array, key: String) -> float:
	var f := 1.0
	for id in ids:
		var d: Dictionary = DEFS.get(String(id), {})
		if d.has(key):
			f *= float(d[key])
	return f


static func int_bonus(ids: Array, key: String) -> int:
	var n := 0
	for id in ids:
		var d: Dictionary = DEFS.get(String(id), {})
		if d.has(key):
			n += int(d[key])
	return n


## 开场横幅与暂停菜单用的一行摘要。
static func summary(ids: Array) -> String:
	if ids.is_empty():
		return "无"
	var parts: Array = []
	for id in ids:
		parts.append("%s（%s）" % [name_of(String(id)), desc_of(String(id))])
	return "　".join(parts)