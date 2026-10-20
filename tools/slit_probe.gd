extends Node
## 临时诊断：地图上"单格宽（4 米）通道"到底是不是必经之路。
##
## 4 米通道是车宽（3 米）只多 1 米的缝——车在里面几乎不能转向（几何上只能偏 ~19°）。
## 所以"它是不是必经"决定了"窄通道不顺畅"该往哪边修：
##   * 必经 → 只能从地图生成侧动手（把需要打通的路线凿成两格宽），操控侧已经没有余量；
##   * 可选 → 玩家本来就会绕开，问题不在这些缝上。
##
## 判定"必经"的办法：把那一格临时当成掩体，从基地门口重新泛洪，
## 只要有一个敌人出生点因此不可达，它就是必经的独木桥。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --path <proj> res://tools/SlitProbe.tscn

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1280, 720)
	Settings.apply_display()
	var main := get_node("Main")
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 30 and not _started:
		_started = true
		_run()


## 单格宽通道的格：沿某个轴向两侧都是掩体。
func _slit_cells(a: Arena) -> Array:
	var out: Array = []
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			if a.blocks_tank(x, y):
				continue
			var vert: bool = a.blocks_tank(x, y - 1) and a.blocks_tank(x, y + 1)
			var horz: bool = a.blocks_tank(x - 1, y) and a.blocks_tank(x + 1, y)
			if vert or horz:
				out.append(Vector2i(x, y))
	return out


## 从基地门口泛洪；extra 里的格当作掩体。返回所有敌人出生点是否都可达。
func _reachable(a: Arena, extra: Array) -> bool:
	const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var start := Vector2i(11, 19)
	var seen := {start: true}
	var stack: Array[Vector2i] = [start]
	while stack.size() > 0:
		var c: Vector2i = stack.pop_back()
		for d in DIRS:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= Arena.GRID_W or n.y >= Arena.GRID_H:
				continue
			if seen.has(n) or extra.has(n) or a.blocks_tank(n.x, n.y):
				continue
			seen[n] = true
			stack.append(n)
	for sp in a.spawn_cells():
		if not seen.has(sp):
			return false
	return true


## 与 corridor_probe 的 census 同一套数法：两侧都是掩体的连续空格段，按格数分档
func _runs(a: Arena) -> Dictionary:
	var hist := {1: 0, 2: 0, 3: 0, 4: 0}
	for y in range(1, Arena.GRID_H - 1):
		var x := 1
		while x < Arena.GRID_W - 1:
			if a.blocks_tank(x, y):
				x += 1
				continue
			var x0 := x
			while x < Arena.GRID_W - 1 and not a.blocks_tank(x, y):
				x += 1
			if a.blocks_tank(x0 - 1, y) and a.blocks_tank(x, y):
				hist[mini(x - x0, 4)] += 1
	for x in range(1, Arena.GRID_W - 1):
		var y := 1
		while y < Arena.GRID_H - 1:
			if a.blocks_tank(x, y):
				y += 1
				continue
			var y0 := y
			while y < Arena.GRID_H - 1 and not a.blocks_tank(x, y):
				y += 1
			if a.blocks_tank(x, y0 - 1) and a.blocks_tank(x, y):
				hist[mini(y - y0, 4)] += 1
	return hist


func _run() -> void:
	var main := get_node("Main")
	var a: Arena = main.arena
	var tot_cells := 0
	var tot_req := 0
	for t in Arena.TERRAINS.size():
		a.generate(1, t)
		var cells := _slit_cells(a)
		var required: Array = []
		for c in cells:
			if not _reachable(a, [c]):
				required.append(c)
		tot_cells += cells.size()
		tot_req += required.size()
		var hist := _runs(a)
		var coords := PackedStringArray()
		for c in required:
			coords.append("(%d,%d)" % [c.x, c.y])
		print("PROBE slit %-2d %-8s cells=%3d required=%2d runs1=%2d runs2=%2d %s"
			% [t, Arena.TERRAINS[t]["name"], cells.size(), required.size(),
				hist[1], hist[2], " ".join(coords)])
	print("PROBE slit TOTAL cells=%d required=%d" % [tot_cells, tot_req])
	get_tree().quit(0)
