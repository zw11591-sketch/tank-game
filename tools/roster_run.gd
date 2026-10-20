extends Node
## 功能验收：五台可选车各开一局，核对"真的装上了名册里那台车"。
##
##   godot.exe --headless --path . res://tools/RosterRun.tscn
##
## 选车界面的截图只能证明"卡片和转台画出来了"，证明不了开局那一刻玩家坦克
## 真的按所选车型装配——而 `_apply_roster()` 里任何一项漏配都会安静地退回基类
## 的默认值（例如忘了写 turret_limit，歼击车就变回全向炮塔）。
## 所以这里逐车型把车造出来、射击一次，再逐项核对实体上的值。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

var _main: Node
var _idx := 0
var _f := 0
var _bad := 0


func _ready() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)


func _physics_process(_d: float) -> void:
	_f += 1
	if _f < 3:
		return
	if _f % 20 != 0:
		return
	if _idx >= TankRoster.ORDER.size():
		print("ROSTER ---- bad=%d ----" % _bad)
		get_tree().quit(1 if _bad > 0 else 0)
		return
	_run_one(TankRoster.ORDER[_idx])
	_idx += 1


func _run_one(id: String) -> void:
	var s := TankRoster.spec(id)
	var d := TankRoster.dims(String(s["model"]))
	_main._sel_row = 0
	_main._sel_tank = TankRoster.ORDER.find(id)
	_main._confirm_start()

	var p = _main.player
	if p == null or not is_instance_valid(p):
		print("ROSTER %-8s FAIL player not spawned" % id)
		_bad += 1
		return

	# 模型必须真的挂上了：_build_model_body() 拿不到 Turret/Barrel/Muzzle 时会
	# 静默退回图元车体，而那正是"模型契约坏了"的表现
	var has_model: bool = p._model != null and is_instance_valid(p._model)
	var nodes_ok: bool = p.turret != null and p.barrel != null and p.muzzle != null

	var checks := [
		["hp", p.max_hp, int(s["hp"])],
		["dmg", p.damage, int(s["damage"])],
		["radius", p.body_radius, float(d["radius"])],
		["length", p.body_length, float(d["length"])],
		["aim_y", p.aim_height, float(d["aim_y"])],
		["limit", p.turret_limit, float(s["turret_limit"])],
		["he", 1 if p.can_use_he else 0, 1 if s["he"] else 0],
	]
	var diffs := []
	for c in checks:
		if absf(float(c[1]) - float(c[2])) > 0.001:
			diffs.append("%s=%s want %s" % [c[0], str(c[1]), str(c[2])])

	# 射击一次：名册漏配 can_use_he / he_mult 之类不会在装配时报错，
	# 但会在这里表现成"开不了火"或"炮弹出生点错位"
	p.reload_t = 0.0
	var before := _shell_count()
	var fired: bool = p.fire()
	var after := _shell_count()

	# 限位炮塔：把炮塔目标甩到正侧方，炮塔应当停在射界上并置 turret_blocked
	var limited := false
	if p.turret_limit > 0.0:
		for i in 40:
			p.aim_at_angles(p.rotation.y + PI * 0.5, 0.0, 1.0 / 120.0)
		limited = p.turret_blocked and \
				absf(p.turret.rotation.y) <= p.turret_limit + 0.01
		if not limited:
			diffs.append("turret_limit not enforced (y=%.3f blocked=%s)" % [
				p.turret.rotation.y, str(p.turret_blocked)])

	var ok: bool = has_model and nodes_ok and fired and after == before + 1 and diffs.is_empty()
	if not ok:
		_bad += 1
	print("ROSTER %-8s model=%-15s hp=%-4d r=%.2f limit=%.2f fire=%s shells=%d+%d %s" % [
		id, String(s["model"]), p.max_hp, p.body_radius, p.turret_limit,
		"OK" if fired else "FAIL", before, after - before,
		"OK" if ok else "BAD " + "; ".join(diffs),
	])


func _shell_count() -> int:
	var n := 0
	for c in _main.get_children():
		if c is Shell:
			n += 1
	return n
