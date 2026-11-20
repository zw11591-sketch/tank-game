extends Node
## Roguelite 整局流程验收：真实状态机从第 1 关推进到第 9 关通关，
## 再单独验证一次失败结算。
##
## 与 `RunProbe` 的分工：
##   * `RunProbe` 直接读写 `Run` 的数据层，手工给 `Run.stage` 赋值；
##   * 本探针只通过 `_confirm_start / 肃清 / 三选一 / 补给站` 这些真实入口推进，
##     因此能发现"main.stage 与 Run.stage 不同步"这类数据层探针看不见的问题。
##
## 判据对应 `docs/design/09_delivery_status.md` 第 3 节。
## 用法：godot.exe --headless --path . res://tools/RunFlowProbe.tscn
##
## 探针会真实走一次通关与一次败北，因此会临时改写 `user://meta.cfg` 与
## `user://stats.cfg`；退出前原样还原。

var _fail := 0
var _pass := 0
var _main: Node
var _meta_saved: Dictionary = {}
var _stats_saved: Dictionary = {}


func _ready() -> void:
	await get_tree().process_frame
	Settings.quality = Settings.Quality.LOW
	_meta_saved = _snap_meta()
	_stats_saved = _snap_stats()
	_main = get_node_or_null("Main")
	if _main == null:
		print("FLOW FAIL noMain")
		get_tree().quit(1)
		return
	await _run_flow()
	Run.abort()
	_restore_meta(_meta_saved)
	_restore_stats(_stats_saved)

	print("")
	if _fail == 0:
		print("FLOW VERDICT OK  (%d checks)" % _pass)
	else:
		print("FLOW VERDICT FAIL  fail=%d pass=%d" % [_fail, _pass])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
		print("FLOW %-24s OK   %s" % [name, detail])
	else:
		_fail += 1
		print("FLOW %-24s FAIL %s" % [name, detail])


func _run_flow() -> void:
	_main._sel_tank = TankRoster.ORDER.find("falcon")
	_main._sel_diff = 1
	_main._sel_challenge = Mutators.NONE
	_main._sel_terrain = 0
	_main._confirm_start()
	await _frames(3)

	_check("start.stage", _main.stage == 1 and Run.stage == 1,
			"stage=%d run=%d" % [_main.stage, Run.stage])
	_check("start.kind", Run.stage_kind() == RunState.Kind.CLEAR,
			"kind=%d" % Run.stage_kind())

	# ---- 第 1 关：歼灭 ----
	_force_clear()
	await _frames(3)
	_check("clear.state", _main.state == "clear", _main.state)
	var score_after_clear: int = int(_main.score)
	_main.state_timer = 0.0
	await _frames(2)
	_check("clear.reward", _main.state == "reward" and Run.offer.size() == 3,
			"state=%s offer=%d" % [_main.state, Run.offer.size()])
	_check("clear.offer_unique", _unique(Run.offer), str(Run.offer))

	var first: String = Run.offer[0]
	_main._on_card_picked(first)
	await _frames(3)
	_check("reward.card", Run.cards.size() == 1 and Run.owns_card(first),
			"cards=%d" % Run.cards.size())
	_check("reward.advanced", _main.stage == 2 and Run.stage == 2,
			"stage=%d run=%d" % [_main.stage, Run.stage])
	_check("reward.score_once", _main.score == score_after_clear,
			"score=%d" % _main.score)
	# 卡牌选完已经进入第 2 关：HUD 必须同步成"第 2 关 坚守"，否则
	# 玩家会在正确推进的流程里看到过期的关卡信息。
	_check("reward.hud", String(_main.hud._run_l.text).contains("第 2 关")
			and String(_main.hud._run_l.text).contains("坚守"),
			_main.hud._run_l.text)

	# ---- 第 2 关：坚守 ----
	_check("hold.kind", Run.stage_kind() == RunState.Kind.HOLD,
			"kind=%d" % Run.stage_kind())
	_check("hold.timer", absf(float(_main.hold_left) - 51.0) < 0.01,
			"left=%.1f" % _main.hold_left)
	_main.state = "play"
	_main.hold_left = 0.0
	_main._hold_complete()
	await _frames(2)
	_check("hold.clear", _main.state == "clear", _main.state)
	_main.state_timer = 0.0
	await _frames(2)
	_check("hold.reward", _main.state == "reward" and Run.offer.size() == 3,
			"state=%s offer=%d" % [_main.state, Run.offer.size()])
	_main._on_card_picked(Run.offer[0])
	await _frames(3)

	# ---- 第 3 关：决战（Boss）与补给站 ----
	_check("boss.kind", Run.stage_kind() == RunState.Kind.BOSS,
			"kind=%d" % Run.stage_kind())
	_force_clear()
	await _frames(3)
	_check("boss.clear", _main.state == "clear", _main.state)
	_main.state_timer = 0.0
	await _frames(2)
	_check("boss.reward", _main.state == "reward", _main.state)
	_main._on_card_picked(Run.offer[0])
	await _frames(3)
	_check("station.open", _main.state == "station" and _main._station.size() == 3,
			"state=%s items=%d" % [_main.state, _main._station.size()])

	Run.credits = 500
	_main._refresh_station_enabled()
	var cards_before: int = Run.cards.size()
	var credits_before: int = Run.credits
	_main._on_station_buy(_main.STATION_CARD)
	await _frames(2)
	_check("station.card", Run.cards.size() == cards_before + 1,
			"cards=%d" % Run.cards.size())
	_check("station.spend", Run.credits < credits_before
			and int(_main._station[_main.STATION_CARD]["cost"]) > 0,
			"credits=%d" % Run.credits)
	_check("station.applied", float(Run.mods_version) > 0.0
			and _main.player != null and not _main.player._base_tank.is_empty(),
			"v=%d" % Run.mods_version)

	_main._on_station_close()
	await _frames(3)
	_check("station.advance", _main.stage == 4 and Run.stage == 4,
			"stage=%d run=%d" % [_main.stage, Run.stage])
	_check("station.keep_cards", Run.cards.size() == cards_before + 1,
			"cards=%d" % Run.cards.size())

	# ---- 第 4~9 关：完整循环 ----
	# 类型序列必须继续按 歼灭 / 坚守 / 决战 循环，且每关都要能正常收尾。
	for s in range(4, 10):
		var expected: int = (s - 1) % 3
		_check("stage%d.kind" % s,
				_main.stage == s and Run.stage == s and Run.stage_kind() == expected,
				"stage=%d run=%d kind=%d" % [_main.stage, Run.stage, Run.stage_kind()])
		_check("stage%d.hud" % s,
				String(_main.hud._run_l.text).contains("第 %d 关" % s),
				_main.hud._run_l.text)
		if expected == RunState.Kind.HOLD:
			_main.state = "play"
			_main.hold_left = 0.0
			_main._hold_complete()
		else:
			_force_clear()
		await _frames(3)
		_check("stage%d.clear" % s, _main.state == "clear", _main.state)
		if expected == RunState.Kind.HOLD:
			_check("stage%d.hold_timer" % s, float(_main.hold_left) <= 0.0,
					"left=%.1f" % _main.hold_left)
		_main.state_timer = 0.0
		await _frames(2)
		if s == 9:
			_check("final.win", _main.state == "win", _main.state)
			break
		_check("stage%d.reward" % s,
				_main.state == "reward" and Run.offer.size() == 3,
				"state=%s offer=%d" % [_main.state, Run.offer.size()])
		_main._on_card_picked(Run.offer[0])
		await _frames(3)
		if s % 3 == 0:
			_check("stage%d.station" % s,
					_main.state == "station" and _main._station.size() == 3,
					"state=%s items=%d" % [_main.state, _main._station.size()])
			_main._on_station_close()
			await _frames(3)
		_check("stage%d.advance" % s, _main.stage == s + 1 and Run.stage == s + 1,
				"stage=%d run=%d" % [_main.stage, Run.stage])

	# ---- 通关结算：战功 100% 转化 ----
	_check("final.payout", Run.won and Run.final_credits >= 0
			and Run.final_payout == Run.final_credits,
			"credits=%d payout=%d" % [Run.final_credits, Run.final_payout])
	var win_text := String(_main._result_text(true))
	_check("final.text", win_text.contains("全线突破")
			and win_text.contains("转化 100%") and win_text.contains("补给券余额"),
			"len=%d" % win_text.length())

	# ---- 失败结算：战功 50% 转化 ----
	Run.begin_run("falcon", 1, Mutators.NONE)
	_main._sel_tank = TankRoster.ORDER.find("falcon")
	_main._sel_diff = 1
	_main._sel_challenge = Mutators.NONE
	_main._confirm_start()
	await _frames(3)
	Run.credits = 100
	_main._game_over()
	await get_tree().process_frame
	_check("settle.loss", _main.state == "over" and Run.final_credits == 100
			and Run.final_payout == 50,
			"credits=%d payout=%d" % [Run.final_credits, Run.final_payout])
	var lose_text := String(_main._result_text(false))
	_check("settle.loss_text", lose_text.contains("转化 50%")
			and lose_text.contains("补给券余额"), "len=%d" % lose_text.length())

	_main._clear_battle()
	await get_tree().process_frame


## 清空本关敌人并让主循环在下一帧判定肃清。
func _force_clear() -> void:
	_main.spawn_queue.clear()
	for e in _main.enemies:
		if is_instance_valid(e):
			e.queue_free()
	_main.enemies.clear()
	_main.state = "play"
	_main._stage_cleared = false


func _unique(arr: Array) -> bool:
	var seen: Dictionary = {}
	for id in arr:
		if seen.has(id):
			return false
		seen[id] = true
	return true


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame
		await get_tree().physics_frame


# ---------------- 存档快照 ----------------

func _snap_meta() -> Dictionary:
	return {
		"credits": Meta.credits, "runs": Meta.runs, "wins": Meta.wins,
		"best_stage": Meta.best_stage, "challenge_clears": Meta.challenge_clears,
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


func _snap_stats() -> Dictionary:
	return {
		"games": Stats.games, "wins": Stats.wins, "kills": Stats.kills,
		"damage_dealt": Stats.damage_dealt,
		"damage_blocked": Stats.damage_blocked,
		"shots": Stats.shots, "hits": Stats.hits, "bounces": Stats.bounces,
		"best_combo": Stats.best_combo, "best_score": Stats.best_score,
		"per_tank": Stats.per_tank.duplicate(true),
		"per_diff": Stats.per_diff.duplicate(true),
	}


func _restore_stats(s: Dictionary) -> void:
	Stats.games = int(s["games"])
	Stats.wins = int(s["wins"])
	Stats.kills = int(s["kills"])
	Stats.damage_dealt = int(s["damage_dealt"])
	Stats.damage_blocked = int(s["damage_blocked"])
	Stats.shots = int(s["shots"])
	Stats.hits = int(s["hits"])
	Stats.bounces = int(s["bounces"])
	Stats.best_combo = float(s["best_combo"])
	Stats.best_score = int(s["best_score"])
	Stats.per_tank = (s["per_tank"] as Dictionary).duplicate(true)
	Stats.per_diff = (s["per_diff"] as Dictionary).duplicate(true)
	Stats.save_cfg()
