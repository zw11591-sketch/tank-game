extends Node
## 临时诊断：让**游戏自己的敌方 AI**在真实地图上从出生点开到基地，
## 量"车辆能不能顺畅通过这张图"。
##
## 为什么不用自己的路线跟随器：手搓一个"沿 A* 路径按住 W"的驾驶员，
## 它的转弯半径与减速策略都是我拍的，量出来的卡顿可能只是我的驾驶员不会开车。
## 敌方 AI 是游戏里本来就在用的那一套（_follow_path + 按舵角收油门 + 卡住脱困），
## 它卡住了就是玩家也会卡住；而它的 `_unstuck_t` 更是现成的"卡住"计数器——
## 不需要我再定义什么叫卡住。
##
## 判据：
##   still    实际位移 < 1.2cm 的帧数（真的一米没走）
##   unstuck  自行触发脱困（倒车转向）的帧数
##   low      最低速
##   dist     行驶距离
##   park     走完/停下之后不再计入统计的那个帧号（到基地就停，不算"卡住"）
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。
## 用法：godot --headless --path <proj> res://tools/FlowProbe.tscn

const STEP := 1.0 / 120.0
const STILL_STEP := 0.012
const MAX_FRAMES := 1200

var _f := 0
var _started := false


func _ready() -> void:
	await get_tree().process_frame
	var main := get_node("Main")
	main._sel_diff = 1
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _main() -> Node:
	return get_node("Main")


func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 40 and not _started:
		_started = true
		_run()


func _run() -> void:
	var main := _main()
	var a: Arena = main.arena
	# 关掉 main 自己的 process：不需要补给出了，也不希望关卡计数器推进
	main.set_process(false)

	for t in Arena.TERRAINS.size():
		a.generate(1, t)
		main._clear_battle()
		await get_tree().physics_frame
		await get_tree().physics_frame
		# 没有玩家 → 所有敌人进入 SEEK、目标就是基地，于是每辆车都要横穿整张图
		main.lives = 0
		main.player = null
		main.state = "play"
		main.state_timer = 1e9
		main.spawn_queue.clear()
		main.max_active = 0

		var foes: Array = []
		for i in 5:
			if main._spawn_enemy(0 if i % 2 == 0 else 1):
				pass
		foes = main.all_tanks()
		await get_tree().physics_frame

		var stat: Dictionary = {}
		for e in foes:
			stat[e.get_instance_id()] = {
				"still": 0, "unstuck": 0, "low": INF, "dist": 0.0,
				"park": -1, "since": 0, "prev": e.global_position, "spd": 0.0,
			}

		for i in MAX_FRAMES:
			await get_tree().physics_frame
			for e in foes:
				if not is_instance_valid(e) or not e.alive:
					continue
				var s: Dictionary = stat[e.get_instance_id()]
				if s["park"] >= 0:
					continue
				var now: Vector3 = e.global_position
				var step: float = now.distance_to(s["prev"])
				s["prev"] = now
				s["dist"] = float(s["dist"]) + step
				s["spd"] = e.speed()
				if e._unstuck_t > 0.0:
					s["unstuck"] = int(s["unstuck"]) + 1
				if step < STILL_STEP:
					s["still"] = int(s["still"]) + 1
					s["since"] = int(s["since"]) + 1
					if s["since"] >= 90:
						s["park"] = i
				else:
					s["since"] = 0
					s["low"] = minf(float(s["low"]), e.speed())
			if _all_parked(stat, foes):
				break

		var nm: String = Arena.TERRAINS[t]["name"]
		var tot_still := 0
		var tot_unstuck := 0
		var tot_dist := 0.0
		var worst := 999
		var lines := PackedStringArray()
		for e in foes:
			if not is_instance_valid(e):
				continue
			var s: Dictionary = stat[e.get_instance_id()]
			tot_still += int(s["still"])
			tot_unstuck += int(s["unstuck"])
			tot_dist += float(s["dist"])
			worst = mini(worst, int(s["still"]))
			lines.append("%.0fm/st%d/un%d" % [s["dist"], s["still"], s["unstuck"]])
		print("PROBE flow %-2d %-8s cars=%d dist=%5.0fm still=%4d unstuck=%4d | %s"
			% [t, nm, foes.size(), tot_dist, tot_still, tot_unstuck, " ".join(lines)])
	get_tree().quit(0)


func _all_parked(stat: Dictionary, foes: Array) -> bool:
	for e in foes:
		if not is_instance_valid(e) or not e.alive:
			continue
		if stat[e.get_instance_id()]["park"] < 0:
			return false
	return true
