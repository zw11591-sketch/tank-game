extends Node
## 战绩存档（Stats autoload）：跨局累计的战斗数据，写在 user://stats.cfg。
##
## 为什么单独开一个文件而不是塞进 Settings：Settings 是"我怎么玩"的配置，
## 玩家会反复调、随时想重置；这里是"我打得怎么样"的记录，只该由战斗结果写入。
## 两者混在同一个文件里，一次"恢复默认设置"就会把战绩一起抹掉。
##
## 键的组织：
##   lifetime   —— 全局累计，结算页与属性卡都用它
##   tank.<id>  —— 每台车各自的累计，车库属性卡上显示
##   diff.<n>   —— 每个难度各自的通关记录
##
## 所有读取都带默认值：旧存档缺字段、手改出脏数据都不会让游戏开不了局。

const CFG_PATH := "user://stats.cfg"

# ---- 全局累计 ----
var games := 0
var wins := 0
var kills := 0
var damage_dealt := 0
var damage_blocked := 0
var shots := 0
var hits := 0
var bounces := 0
var best_combo := 1.0
var best_score := 0

## 单局数据：由 main 在开局时清零、结算时提交。
## 放在这里而不是 main 里，是因为结算页要读、main 要写，两边都要有同一个来源。
var run_kills := 0
var run_damage := 0
var run_blocked := 0
var run_shots := 0
var run_hits := 0
var run_bounces := 0
var run_combo := 1.0

## 每台车的累计：id -> {kills, damage, best_score, clears, games}
var per_tank: Dictionary = {}
## 每个难度的最好成绩：difficulty -> {best_score, clears}
var per_diff: Dictionary = {}

var _loaded := false


func _ready() -> void:
	load_cfg()


# ---------------- 单局生命周期 ----------------

## 开新一局（不是新一关）：单局统计清零。
## 最高分与总击毁是跨局量，不在这里清。
func begin_run() -> void:
	run_kills = 0
	run_damage = 0
	run_blocked = 0
	run_shots = 0
	run_hits = 0
	run_bounces = 0
	run_combo = 1.0


func add_damage(v: int) -> void:
	run_damage += v
	damage_dealt += v


func add_blocked(v: int) -> void:
	run_blocked += v
	damage_blocked += v


func add_shot() -> void:
	run_shots += 1
	shots += 1


func add_hit() -> void:
	run_hits += 1
	hits += 1


func add_bounce() -> void:
	run_bounces += 1
	bounces += 1


func add_kill() -> void:
	run_kills += 1
	kills += 1


func note_combo(mult: float) -> void:
	if mult > run_combo:
		run_combo = mult
	if mult > best_combo:
		best_combo = mult


## 命中率。没有开过火时返回 -1，让界面显示"—"而不是"0%"。
func accuracy() -> float:
	if run_shots <= 0:
		return -1.0
	return clampf(float(run_hits) / float(run_shots), 0.0, 1.0)


## 一局结束：把单局数据并入全局与分车统计，然后落盘。
func end_run(tank_id: String, diff: int, score_value: int, won: bool) -> void:
	games += 1
	if won:
		wins += 1
	if score_value > best_score:
		best_score = score_value

	var t: Dictionary = per_tank.get(tank_id, {
		"kills": 0, "damage": 0, "best_score": 0, "clears": 0, "games": 0,
	})
	t["kills"] = int(t["kills"]) + run_kills
	t["damage"] = int(t["damage"]) + run_damage
	t["games"] = int(t["games"]) + 1
	t["best_score"] = maxi(int(t["best_score"]), score_value)
	if won:
		t["clears"] = int(t["clears"]) + 1
	per_tank[tank_id] = t

	var d: Dictionary = per_diff.get(diff, {"best_score": 0, "clears": 0})
	d["best_score"] = maxi(int(d["best_score"]), score_value)
	if won:
		d["clears"] = int(d["clears"]) + 1
	per_diff[diff] = d

	save_cfg()


# ---------------- 读取 ----------------

func tank_row(id: String) -> Dictionary:
	# 逐字段补默认值：旧存档 / 手改过的存档可能缺键，
	# 直接返回原始字典会让属性卡读 r["games"] 时报错。
	var row := {"kills": 0, "damage": 0, "best_score": 0, "clears": 0, "games": 0}
	var raw = per_tank.get(id, null)
	if raw is Dictionary:
		for k in row.keys():
			row[k] = int(raw.get(k, row[k]))
	return row


## 属性卡用的一行摘要。没打过任何一局时返回空串，界面就不必显示一串零。
func tank_summary(id: String) -> String:
	var r := tank_row(id)
	if int(r["games"]) <= 0:
		return ""
	return "战绩  最高 %07d   击毁 %d   通关 %d 次" % [
		int(r["best_score"]), int(r["kills"]), int(r["clears"]),
	]


func diff_best(diff: int) -> int:
	return int(per_diff.get(diff, {"best_score": 0})["best_score"])


func diff_clears(diff: int) -> int:
	return int(per_diff.get(diff, {"clears": 0})["clears"])


func lifetime_accuracy() -> float:
	return 0.5 if shots <= 0 else clampf(float(hits) / float(shots), 0.0, 1.0)


# ---------------- 存档 ----------------

func load_cfg() -> void:
	if _loaded:
		return
	_loaded = true
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return
	games = int(cf.get_value("lifetime", "games", games))
	wins = int(cf.get_value("lifetime", "wins", wins))
	kills = int(cf.get_value("lifetime", "kills", kills))
	damage_dealt = int(cf.get_value("lifetime", "damage_dealt", damage_dealt))
	damage_blocked = int(cf.get_value("lifetime", "damage_blocked", damage_blocked))
	shots = int(cf.get_value("lifetime", "shots", shots))
	hits = int(cf.get_value("lifetime", "hits", hits))
	bounces = int(cf.get_value("lifetime", "bounces", bounces))
	best_combo = float(cf.get_value("lifetime", "best_combo", best_combo))
	best_score = int(cf.get_value("lifetime", "best_score", best_score))
	# 先读进无类型局部变量再校验：给 Dictionary 变量直接赋一个非字典值，
	# 赋值的瞬间就会抛类型错误，"之后再检查"根本走不到。
	# 手改过的存档可能把 rows 写成字符串或数组，这里直接丢弃并回到空表。
	var tanks_raw = cf.get_value("tanks", "rows", {})
	per_tank = tanks_raw if tanks_raw is Dictionary else {}
	var diffs_raw = cf.get_value("diffs", "rows", {})
	per_diff = diffs_raw if diffs_raw is Dictionary else {}


func save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.set_value("lifetime", "games", games)
	cf.set_value("lifetime", "wins", wins)
	cf.set_value("lifetime", "kills", kills)
	cf.set_value("lifetime", "damage_dealt", damage_dealt)
	cf.set_value("lifetime", "damage_blocked", damage_blocked)
	cf.set_value("lifetime", "shots", shots)
	cf.set_value("lifetime", "hits", hits)
	cf.set_value("lifetime", "bounces", bounces)
	cf.set_value("lifetime", "best_combo", best_combo)
	cf.set_value("lifetime", "best_score", best_score)
	cf.set_value("tanks", "rows", per_tank)
	cf.set_value("diffs", "rows", per_diff)
	cf.save(CFG_PATH)


## 存档损坏或玩家想从头开始时的完全重置。
func reset() -> void:
	games = 0
	wins = 0
	kills = 0
	damage_dealt = 0
	damage_blocked = 0
	shots = 0
	hits = 0
	bounces = 0
	best_combo = 1.0
	best_score = 0
	per_tank.clear()
	per_diff.clear()
	save_cfg()
