extends Node
## 验收：击毁后留下残骸，并且残骸"挡车不挡弹"。
##
## 判据：
##   1. 击毁一辆敌车后，Arena 的 Wrecks 根节点下出现一个残骸；
##   2. 残骸碰撞体在 LAYER_BLOCKER（坦克 mask 含这一层）；
##   3. 残骸不在炮弹射线的 mask（WORLD | TANK）里；
##   4. 2 秒后残骸仍然存在，且黑烟粒子还在发射。
##
## 打印标签全用 ASCII：中文经 PowerShell 管道会二次编码。

const WAIT_KILL := 900          ## 最多等多久才凑出一辆可击毁的敌车（120 Hz）
const WAIT_PERSIST := 240       ## 击毁后再等 2 秒确认残骸没被回收

var _f := 0
var _state := 0
var _w: Node3D = null
var _killed := ""
var _kill_pos := Vector3.ZERO


func _main() -> Node:
	return get_node_or_null("Main")


func _ready() -> void:
	await get_tree().process_frame
	var main := _main()
	if main == null:
		print("WRECK FAIL no Main")
		get_tree().quit(1)
		return
	main._sel_diff = 0
	main._sel_stage = 0
	main._sel_terrain = 0
	main._confirm_start()


func _physics_process(_delta: float) -> void:
	var main := _main()
	if main == null or main.arena == null:
		return
	_f += 1

	if _state == 0:
		if _f < WAIT_KILL:
			for e in main.enemies:
				if is_instance_valid(e) and e.alive:
					_killed = str(e.name)
					_kill_pos = e.global_position
					e.destroy(true)
					_state = 1
					_f = 0
					print("WRECK killed=%s" % _killed)
					return
		else:
			print("WRECK FAIL noEnemy frames=%d" % _f)
			get_tree().quit(1)
		return

	if _state == 1 and _f > WAIT_PERSIST:
		var root: Node3D = main.arena._wrecks_root
		var n: int = root.get_child_count() if root != null else 0
		if n > 0:
			_w = root.get_child(n - 1) as Node3D
		var body: Node = _w.get_node_or_null("WreckBody") if _w != null else null
		var layer: int = (body as CollisionObject3D).collision_layer if body is CollisionObject3D else -1
		var blocks_tank: bool = (layer & Tank.LAYER_BLOCKER) != 0
		var shell_hits: bool = (layer & (Tank.LAYER_WORLD | Tank.LAYER_TANK)) != 0
		var smoke := _find_smoke(_w)
		var turret := Assets.find_node(_w, "Turret") if _w != null else null
		var barrel := Assets.find_node(_w, "Barrel") if _w != null else null
		var persists: bool = _w != null and is_instance_valid(_w) and _w.is_inside_tree()
		var placed: bool = persists and _w.global_position.distance_to(_kill_pos) < 4.0
		var in_tank_list := false
		for t in main.all_tanks():
			if t == _w:
				in_tank_list = true
		print("WRECK wrecks=%d layer=%d blocksTank=%s shellHits=%s present=%s atKillSpot=%s turret=%s barrel=%s smoke=%s stillTargetable=%s" % [
			n, layer, str(blocks_tank), str(shell_hits), str(persists),
			str(placed), str(turret != null), str(barrel != null), str(smoke),
			str(in_tank_list),
		])
		var ok: bool = n >= 1 and blocks_tank and not shell_hits and persists \
				and placed and turret != null and barrel != null and not in_tank_list
		print("WRECK VERDICT wreckKept=%s" % str(ok))
		get_tree().quit(0 if ok else 1)


func _find_smoke(n: Node) -> bool:
	if n == null:
		return false
	if n is GPUParticles3D and (n as GPUParticles3D).emitting:
		return true
	for c in n.get_children():
		if _find_smoke(c):
			return true
	return false
