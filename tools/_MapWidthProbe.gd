extends Node
## 临时诊断：真实关卡里"单格宽通道"的占比，以及各车型在通道里能原地转多少度。
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
	var open := 0
	var corridor := 0
	var single_w := 0
	var single_h := 0
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			if a.blocks_tank(x, y):
				continue
			open += 1
			var l: bool = a.blocks_tank(x - 1, y)
			var r: bool = a.blocks_tank(x + 1, y)
			var u: bool = a.blocks_tank(x, y - 1)
			var d: bool = a.blocks_tank(x, y + 1)
			# 纵向通道被左右夹住 = 宽度 1 格
			if l and r and not u and not d:
				single_w += 1
				corridor += 1
			# 横向通道被上下夹住 = 高度 1 格
			elif u and d and not l and not r:
				single_h += 1
				corridor += 1
	print("PROBE map stage=%d terrain=%d open=%4d corridor=%4d single_w=%3d single_h=%3d pct=%.0f%%" % [
		stage, terrain, open, corridor, single_w, single_h,
		100.0 * float(corridor) / maxf(float(open), 1.0)])
