class_name MetaProgress
extends Node
## 长期成长存档（autoload `Meta`）：补给券、战车解锁、永久升级、生涯记录。
##
## 与 Settings / Stats 分开的理由：
##   * Settings 是"我怎么玩"，玩家随时想重置；
##   * Stats 是"我打得怎么样"，只由战斗结果写入；
##   * 这里是"我解锁了什么"，只由结算与解锁写入。
## 三者混在一起，一次"恢复默认设置"就会把成长一起抹掉。
##
## 规格见 docs/design/03_economy_and_meta.md。所有读取都带默认值：
## 旧存档缺字段、手改出脏数据都不会让游戏开不了局。

const CFG_PATH := "user://meta.cfg"

## 战车解锁价。0 表示初始可用（游隼）。价格是代码常量、不写进存档，
## 于是调整价格不会让旧存档失效。
const TANK_COST := {
	"falcon": 0,
	"lynx": 350,
	"anvil": 650,
	"thunder": 700,
	"hunter": 800,
}

## 永久升级。cost[i] 是从第 i 级升到第 i+1 级的价格。
const UPGRADES := {
	"lives": {
		"name": "备用车体", "max": 2, "cost": [600, 1400],
		"desc": "每局多 1 条命",
	},
	"credits": {
		"name": "后勤预算", "max": 2, "cost": [400, 900],
		"desc": "开局 +80 战功",
	},
	"reroll": {
		"name": "情报网", "max": 2, "cost": [350, 800],
		"desc": "重掷卡牌价格 −15%（每级）",
	},
}

signal changed

var credits := 0
var runs := 0
var wins := 0
var best_stage := 0
var challenge_clears := 0
## 战车解锁表：id -> true。游隼永远视为已解锁，不必写进存档。
var unlocked: Dictionary = {}
## 永久升级等级：key -> int。
var upgrades: Dictionary = {}

var _loaded := false


func _ready() -> void:
	load_cfg()


# ---------------- 查询 ----------------

func is_tank_unlocked(id: String) -> bool:
	if int(TANK_COST.get(id, 999999)) <= 0:
		return true
	return bool(unlocked.get(id, false))


func tank_cost(id: String) -> int:
	return int(TANK_COST.get(id, 0))


## 默认出击车。存档里的车未解锁时退回游隼，不让坏存档把玩家卡在车库里。
func default_tank(saved_id: String) -> String:
	if TankRoster.has(saved_id) and is_tank_unlocked(saved_id):
		return saved_id
	return TankRoster.DEFAULT_ID


func upgrade_level(key: String) -> int:
	return clampi(int(upgrades.get(key, 0)), 0, int(UPGRADES.get(key, {}).get("max", 0)))


func upgrade_max(key: String) -> int:
	return int(UPGRADES.get(key, {}).get("max", 0))


## 下一级价格；已满级返回 -1。
func upgrade_cost(key: String) -> int:
	if not UPGRADES.has(key):
		return -1
	var lv := upgrade_level(key)
	var costs: Array = UPGRADES[key]["cost"]
	if lv >= int(UPGRADES[key]["max"]):
		return -1
	return int(costs[clampi(lv, 0, costs.size() - 1)])


## 开局加成。
func start_lives() -> int:
	return upgrade_level("lives")


func start_credits() -> int:
	return upgrade_level("credits") * 80


## 重掷价格系数：情报网每级 −15%。
func reroll_mult() -> float:
	return 1.0 - 0.15 * float(upgrade_level("reroll"))


# ---------------- 写入 ----------------

func add_credits(n: int) -> void:
	if n == 0:
		return
	credits = maxi(0, credits + n)
	save_cfg()
	changed.emit()


func unlock_tank(id: String) -> bool:
	if is_tank_unlocked(id):
		return false
	var cost := tank_cost(id)
	if cost <= 0 or credits < cost:
		return false
	credits -= cost
	unlocked[id] = true
	save_cfg()
	changed.emit()
	return true


func buy_upgrade(key: String) -> bool:
	var cost := upgrade_cost(key)
	if cost < 0 or credits < cost:
		return false
	credits -= cost
	upgrades[key] = upgrade_level(key) + 1
	save_cfg()
	changed.emit()
	return true


## 一局结束后的生涯记录。补给券的加/减由 RunState.finish() 负责，
## 这里只记"打了多少、走到哪、通没通关"，避免两处都扣钱。
func note_run(won: bool, reached_stage: int, challenge: int = 0) -> void:
	runs += 1
	if won:
		wins += 1
		# "挑战通关"只统计带修正的行动（每日 / 精英）。标准行动通关已经由 wins 记账，
		# 两处都加会让车库的"通关 N 次"与挑战数永远相等，看不出区别。
		if challenge != 0:
			challenge_clears += 1
	best_stage = maxi(best_stage, clampi(reached_stage, 1, 9))
	save_cfg()
	changed.emit()


func best_zone() -> int:
	return clampi(int((best_stage - 1) / 3.0) + 1, 1, 3)


# ---------------- 存档 ----------------

func load_cfg() -> void:
	if _loaded:
		return
	_loaded = true
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		_apply_defaults()
		return
	credits = maxi(0, int(cf.get_value("meta", "credits", 0)))
	runs = maxi(0, int(cf.get_value("meta", "runs", 0)))
	wins = maxi(0, int(cf.get_value("meta", "wins", 0)))
	best_stage = clampi(int(cf.get_value("meta", "best_stage", 0)), 0, 9)
	challenge_clears = maxi(0, int(cf.get_value("meta", "challenge_clears", 0)))
	# 手改过的存档可能把 rows 写成字符串或数组：先读进无类型变量再校验，
	# 直接给 Dictionary 赋值会在赋值的瞬间抛类型错误。
	var raw_tanks = cf.get_value("tanks", "rows", {})
	unlocked = raw_tanks if raw_tanks is Dictionary else {}
	var raw_up = cf.get_value("upgrades", "rows", {})
	upgrades = raw_up if raw_up is Dictionary else {}
	_sanitize()


func _apply_defaults() -> void:
	credits = 0
	runs = 0
	wins = 0
	best_stage = 0
	challenge_clears = 0
	unlocked = {}
	upgrades = {}


## 丢弃未知键与非法等级，防止手改存档造出 max+999 的升级。
func _sanitize() -> void:
	var clean: Dictionary = {}
	for id in unlocked.keys():
		if TankRoster.has(String(id)) and bool(unlocked[id]):
			clean[String(id)] = true
	unlocked = clean
	var up: Dictionary = {}
	for key in UPGRADES.keys():
		if upgrades.has(key):
			up[key] = clampi(int(upgrades[key]), 0, int(UPGRADES[key]["max"]))
	upgrades = up


func save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.set_value("meta", "credits", credits)
	cf.set_value("meta", "runs", runs)
	cf.set_value("meta", "wins", wins)
	cf.set_value("meta", "best_stage", best_stage)
	cf.set_value("meta", "challenge_clears", challenge_clears)
	cf.set_value("tanks", "rows", unlocked)
	cf.set_value("upgrades", "rows", upgrades)
	cf.save(CFG_PATH)


## 完全重置（设置页的"清空进度"用；当前版本没有入口，保留给探针与排障）。
func reset() -> void:
	_apply_defaults()
	save_cfg()
	changed.emit()
