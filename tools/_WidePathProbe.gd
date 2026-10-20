extends Node
## 临时诊断：宽体寻路（find_path(..., true)）是否真的绕开了单格通道，以及它是否会
## 因为绕不过去而整段返回空路径。打印标签全用 ASCII。

var _main: Node
var _a: Arena
var _seed := 90210


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	for stage in [1, 2, 3, 4, 5]:
		for terrain in [0, 3, 6, 8, 11]:
			_main.arena.generate(stage, terrain)
			await get_tree().process_frame
			_scan(stage, terrain)
	get_tree().quit(0)


func _scan(stage: int, terrain: int) -> void:
	_a = _main.arena
	var pairs := 40
	var narrow_hits := 0
	var empty := 0
	var fallback := 0
	var steps := 0
	for i in pairs:
		var ca := _open_cell()
		var cb := _open_cell()
		if ca == Vector2i(-1, -1) or cb == Vector2i(-1, -1):
			continue
		var pa := Arena.cell_center(ca.x, ca.y)
		var pb := Arena.cell_center(cb.x, cb.y)
		var wide := _a.find_path(pa, pb, true)
		var plain := _a.find_path(pa, pb, false)
		if wide.is_empty():
			empty += 1
			continue
		if wide.size() == plain.size():
			# 同长不一定是兜底，但长度完全一致且路径里出现窄格就是兜底
			pass
		var bad := 0
		for w in wide:
			var v: Vector3 = w
			var c := Arena.to_cell(v)
			if _a._narrow_any(c.x, c.y):
				bad += 1
		if bad > 0:
			narrow_hits += 1
			fallback += 1
		steps += wide.size()
	print("PROBE wide stage=%d terrain=%d pairs=%d narrowHits=%d empty=%d fallback=%d avgSteps=%.1f" % [
		stage, terrain, pairs, narrow_hits, empty, fallback,
		float(steps) / maxf(float(pairs - empty - fallback), 1.0)])


func _open_cell() -> Vector2i:
	for _try in 200:
		var x := _rnd(2, Arena.GRID_W - 2)
		var y := _rnd(2, Arena.GRID_H - 2)
		if not _a.blocks_tank(x, y):
			return Vector2i(x, y)
	return Vector2i(-1, -1)


func _rnd(a: int, b: int) -> int:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return a + _seed % maxi(b - a, 1)
