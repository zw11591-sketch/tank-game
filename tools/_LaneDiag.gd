extends Node
## 临时诊断：地图生成完之后，还剩下多少单格宽通道，以及夹住它们的两侧是什么格。
## 打印标签全用 ASCII。

var _main: Node


func _ready() -> void:
	await get_tree().process_frame
	_main = get_node("Main")
	for stage in [1, 2, 3, 4, 5]:
		for terrain in range(Arena.TERRAINS.size()):
			_main.arena.generate(stage, terrain)
			await get_tree().process_frame
			_scan(stage, terrain)
	get_tree().quit(0)


func _scan(stage: int, terrain: int) -> void:
	var a: Arena = _main.arena
	var lanes := 0
	var kinds := {}
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			if a.blocks_tank(x, y):
				continue
			var vertical := a.blocks_tank(x - 1, y) and a.blocks_tank(x + 1, y)
			var horizontal := a.blocks_tank(x, y - 1) and a.blocks_tank(x, y + 1)
			if not vertical and not horizontal:
				continue
			lanes += 1
			var key := ""
			if vertical:
				key = "%s|%s" % [_kind(a, x - 1, y), _kind(a, x + 1, y)]
			else:
				key = "%s|%s" % [_kind(a, x, y - 1), _kind(a, x, y + 1)]
			kinds[key] = int(kinds.get(key, 0)) + 1
	if lanes == 0:
		return
	var parts: Array = []
	for k in kinds.keys():
		parts.append("%s=%d" % [k, kinds[k]])
	parts.sort()
	print("PROBE lane stage=%d terrain=%d lanes=%d  %s" % [
		stage, terrain, lanes, " ".join(parts)])


func _kind(a: Arena, x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= Arena.GRID_W or y >= Arena.GRID_H:
		return "edge"
	match a.cell(x, y):
		Arena.BRICK: return "brick"
		Arena.STEEL: return "steel"
		Arena.WATER: return "water"
		Arena.BARRICADE: return "barr"
		Arena.BASE: return "base"
		_: return "empty"
