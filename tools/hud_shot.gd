extends Node
## 渲染验收：HUD 的雷达补给标记与关卡行的地形名。
##
## 无头模式不执行 Control._draw()，所以雷达与准星的改动在无头自检里是测不到的。
## 这里开一个真实窗口，强制在场上放几个补给（含一个远到超出雷达量程的），
## 然后截图——于是"雷达标记"与"地形名"是不是真的画出来了有图可查。
##
## 打印标签刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

const DIR := "d:/IdeaProjects/tank-game/tools/shots/"
## 看哪几张图：覆盖最亮与最暗的两种光照，确认 HUD 在两端都读得清
const TERRAINS := [0, 9]

var _f := 0
var _idx := 0
var _busy := false


func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	Settings.display_mode = Settings.Disp.WINDOWED
	Settings.windowed_size = Vector2i(1600, 900)
	Settings.apply_display()
	DirAccess.make_dir_recursive_absolute(DIR)
	_start(0)


func _start(i: int) -> void:
	_idx = i
	_f = 0
	var main := _main()
	main._sel_diff = 1
	main._sel_stage = 2
	main._sel_terrain = TERRAINS[i]
	main._confirm_start()


func _physics_process(_d: float) -> void:
	if _busy:
		return
	var main := _main()
	if main == null or main.arena == null:
		return
	_f += 1

	if _f == 200:
		# 进入战斗态，并清掉重生护盾，免得护盾球糊住画面
		main.state = "play"
		if main.player != null:
			main.player.shield_t = 0.0

	if _f == 240:
		_seed_powerups(main)

	# 关卡横幅在进入战斗后还要停留 2.6 s。截图必须等它消失，
	# 否则文档图正中永远是"第 3 关 · 废墟城区 · 普通"这行字。
	# 300 帧时横幅早已结束（200 帧进入战斗 + 2.6 s ≈ 356 帧）。
	if _f == 460:
		_report(main)
		await _shot("HUD_%d_%s" % [_idx, str(Arena.TERRAINS[TERRAINS[_idx]]["layout"])])
		if _idx + 1 < TERRAINS.size():
			_start(_idx + 1)
		else:
			get_tree().quit(0)


## 在场上铺开补给：近处两个（雷达量程内）+ 远处一个（必须贴边显示）。
## 远处那个是关键用例：它正是"空投落在场地深处"的情形。
func _seed_powerups(main) -> void:
	var p = main.player
	if p == null or not is_instance_valid(p):
		return
	var base: Vector3 = p.global_position
	var near1: Vector3 = main.arena.random_open_cell([base], 12.0)
	var near2: Vector3 = main.arena.random_open_cell([base], 24.0)
	# 最远的那个必须确定地落在雷达量程外，所以直接扫全图取最远空格，
	# 而不是靠随机采样去碰——随机采样在 96 米见方的场地上几乎碰不到
	var far: Vector3 = _farthest_open(main.arena, base)
	var made := 0
	for item in [[near1, true], [near2, false], [far, true]]:
		var pos: Vector3 = item[0]
		if pos == Vector3.INF:
			continue
		main._spawn_powerup(pos, PowerUp.Type.FIREPOWER if item[1] else PowerUp.Type.REPAIR, item[1])
		made += 1
	print("SHOT seeded=%d" % made)


## 全图最远的一个空格。用来构造"补给落在雷达量程外"这个用例。
func _farthest_open(a: Arena, from: Vector3) -> Vector3:
	var best := Vector3.INF
	var bd := -1.0
	for y in range(1, Arena.GRID_H - 1):
		for x in range(1, Arena.GRID_W - 1):
			if a.blocks_tank(x, y):
				continue
			var p := Arena.cell_center(x, y)
			var d := p.distance_to(from)
			if d > bd:
				bd = d
				best = p
	return best


func _report(main) -> void:
	var p = main.player
	var inrange := 0
	var outrange := 0
	for pu in main.powerups:
		if not is_instance_valid(pu) or p == null:
			continue
		var d: float = pu.global_position.distance_to(p.global_position)
		if d > HUD.Radar.RANGE:
			outrange += 1
		else:
			inrange += 1
	print("SHOT %-9s powerups=%d inRange=%d outOfRange=%d stageLine=%s" % [
		str(Arena.TERRAINS[TERRAINS[_idx]]["layout"]), main.powerups.size(),
		inrange, outrange, main.terrain_name(),
	])


func _shot(tag: String) -> void:
	_busy = true
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(DIR + tag + ".png")
	print("SHOT saved %s.png" % tag)
	_busy = false
