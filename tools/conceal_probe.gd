extends Node
## 验收：草丛隐蔽、烟幕按云团生效、开火暴露、栅栏被压倒。
##
## 判据：
##   * 地图上存在隐蔽格（灌木 / 芦苇），站在里面 is_concealed() 为真；
##   * 开火后 expose_t > 0，隐蔽失效；等待后恢复；
##   * 烟幕只在云团范围内生效，20 m 外不生效，寿命结束后失效；
##   * 铁丝网实例能被 crush_at 放倒（实例变换的竖直轴倾到 0.6 以下）。
##
## 注意：MultiMesh 的实例变换存在渲染服务端，无头模式（dummy 渲染器）
## 读不回来，所以本探针必须带窗口跑，与 vis_probe 相同。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会二次编码。

var _main: Node = null
var _f := 0
var _step := 0
var _marks: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	_main = get_node_or_null("Main")
	if _main == null:
		print("COVER FAIL noMain")
		get_tree().quit(1)
		return
	_main._sel_diff = 1
	_main._sel_stage = 0
	_main._sel_terrain = 0
	_main._confirm_start()


func _physics_process(_delta: float) -> void:
	if _main == null:
		return
	_f += 1
	match _step:
		0:
			if _main.state == "play" and _f > 4:
				_check_static()
				_f = 0
				_step = 1
			elif _f > 800:
				print("COVER FAIL neverPlay state=%s" % _main.state)
				get_tree().quit(1)
		1:
			var p = _main.player
			if p == null or not is_instance_valid(p) or not p.alive:
				print("COVER FAIL noPlayer")
				get_tree().quit(1)
				return
			p.reload_t = 0.0
			p.fire()
			var exposed: bool = p.expose_t > 0.01
			var hidden_while_firing: bool = p.is_concealed()
			print("COVER fire exposed=%s concealed=%s" % [str(exposed), str(hidden_while_firing)])
			_marks["expose"] = exposed
			_marks["fire_hide"] = not hidden_while_firing
			_f = 0
			_step = 2
		2:
			if _f > 260:
				var p = _main.player
				var back: bool = p.is_concealed()
				print("COVER afterWait concealed=%s" % str(back))
				_marks["recover"] = back
				_f = 0
				_step = 3
		3:
			var p = _main.player
			_main.deploy_smoke(p.global_position, 1.0)
			var here: bool = _main.smoke_at(p.global_position)
			var far: bool = _main.smoke_at(p.global_position + Vector3(20, 0, 0))
			print("COVER smoke here=%s far=%s" % [str(here), str(far)])
			_marks["smoke"] = here and not far
			_f = 0
			_step = 4
		4:
			if _f > 200:
				var p = _main.player
				var gone: bool = not _main.smoke_at(p.global_position)
				print("COVER smokeExpired=%s" % str(gone))
				_marks["smoke_expire"] = gone
				_crush_test()
				_verdict()


func _check_static() -> void:
	var arena = _main.arena
	var n: int = arena._conceal_cells.size()
	print("COVER concealCells=%d" % n)
	_marks["cells"] = n > 0
	# 找一个真的能站车的隐蔽格
	var chosen := Vector3.INF
	for c in arena._conceal_cells.keys():
		if arena.blocks_tank(c.x, c.y):
			continue
		chosen = arena.cell_center(c.x, c.y)
		break
	if chosen == Vector3.INF:
		print("COVER FAIL noWalkableCell")
		_marks["stand"] = false
		return
	var p = _main.player
	p.global_position = chosen
	p.expose_t = 0.0
	var hidden: bool = p.is_concealed()
	print("COVER stand at=(%.1f,%.1f) concealed=%s" % [chosen.x, chosen.z, str(hidden)])
	_marks["stand"] = hidden


func _crush_test() -> void:
	var arena = _main.arena
	if not arena._crush_meta.has("prop_wire"):
		print("COVER FAIL noWire")
		_marks["crush"] = false
		return
	var meta: Dictionary = arena._crush_meta["prop_wire"]
	var xfs: Array = meta["xfs"]
	if xfs.is_empty():
		print("COVER FAIL wireEmpty")
		_marks["crush"] = false
		return
	var target: Transform3D = xfs[0]
	var target_idx := -1
	# 取一个真的列进格表（不在路障格里）的实例
	for c in arena._crush_cells.keys():
		var recs: Array = arena._crush_cells[c]
		for r in recs:
			if String(r[0]) == "prop_wire":
				target_idx = int(r[1])
				target = xfs[target_idx]
				break
		if target_idx >= 0:
			break
	if target_idx < 0:
		print("COVER FAIL noReachableWire")
		_marks["crush"] = false
		return
	var mmi: MultiMeshInstance3D = meta["mmi"]
	arena._crush_cd = 0.0
	arena.crush_at(target.origin)
	var down: Dictionary = meta["down"]
	var first: int = -1
	for k in down.keys():
		first = int(k)
		break
	var tipped := false
	if first >= 0:
		var after: Transform3D = mmi.multimesh.get_instance_transform(first)
		tipped = absf(after.basis.y.y) < 0.6
	print("COVER crush instances=%d down=%d tipped=%s" % [
		xfs.size(), down.size(), str(tipped)])
	_marks["crush"] = tipped


func _verdict() -> void:
	var ok: bool = bool(_marks.get("cells", false)) \
			and bool(_marks.get("stand", false)) \
			and bool(_marks.get("expose", false)) \
			and bool(_marks.get("fire_hide", false)) \
			and bool(_marks.get("recover", false)) \
			and bool(_marks.get("smoke", false)) \
			and bool(_marks.get("smoke_expire", false)) \
			and bool(_marks.get("crush", false))
	print("COVER VERDICT coverOk=%s" % str(ok))
	get_tree().quit(0 if ok else 1)
