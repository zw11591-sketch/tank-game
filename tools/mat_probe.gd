extends SceneTree
## 材质契约校验（开发期工具，不参与游戏运行）：
##   godot --headless --path . --script res://tools/mat_probe.gd
##
## 贴图是**导出的**一回事、**被 Godot 认出来的**又是另一回事。check_models.gd 查的是
## 节点与材质名，管不到贴图通道；而 ORM 贴图的通道映射错了不会有任何报错，
## 只会让金属件悄悄变成"全粗糙"——看起来就是用错了一档参数，很难反查到导入器。
## 所以这里把导入结果直接摊开：
##   * albedo / normal / orm 三张贴图是否都在；
##   * 粗糙度与金属度各自读的是哪个通道（错了就会整体走样）；
##   * M_Paint 的 baseColorFactor 是否仍是白的（阵营涂装赖以相乘的前提）。
##
## 打印刻意全用 ASCII：中文经 PowerShell 管道会被二次编码成乱码。

const KEYS := [
	"tank_player", "tank_scout", "tank_medium", "tank_heavy",
	"tank_artillery", "tank_destroyer", "tank_boss",
]

var _bad := 0


func _init() -> void:
	for key in KEYS:
		_report(key)
	print("MATPROBE ---- bad=%d ----" % _bad)
	quit(1 if _bad else 0)


func _report(key: String) -> void:
	var path := "res://assets/models/%s.glb" % key
	if not ResourceLoader.exists(path):
		print("MATPROBE %-16s MISSING" % key)
		_bad += 1
		return
	var inst := (load(path) as PackedScene).instantiate()
	var seen := {}
	_collect(inst, seen)
	inst.free()
	if seen.is_empty():
		print("MATPROBE %-16s 没有网格" % key)
		_bad += 1
		return
	var names := seen.keys()
	names.sort()
	for n in names:
		_print_mat(key, n, seen[n])


func _collect(n: Node, out: Dictionary) -> void:
	if n is MeshInstance3D and n.mesh != null:
		var mesh: Mesh = n.mesh
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as BaseMaterial3D
			if m != null:
				out[String(m.resource_name)] = m
	for c in n.get_children():
		_collect(c, out)


func _print_mat(key: String, name: String, m: BaseMaterial3D) -> void:
	var alb := m.albedo_texture != null
	var nrm := m.normal_texture != null
	# Godot 4 的 glTF 导入器把一张 metallicRoughnessTexture 拆到
	# roughness_texture / metallic_texture 两个属性上，orm_texture 是另一条路
	# （Godot 自有的打包格式）。只查 orm_texture 会误判成"没导入"。
	var orm := m.orm_texture != null or (m.roughness_texture != null and m.metallic_texture != null)
	print("MATPROBE %-16s %-13s albedo=%s normal=%s orm=%s rough=%.2f metal=%.2f rc=%s mc=%s" % [
		key, name, _yn(alb), _yn(nrm), _yn(orm),
		m.roughness, m.metallic,
		_chan(m.roughness_texture_channel), _chan(m.metallic_texture_channel),
	])
	# 三条会静默毁掉观感的契约
	if name == "M_Paint":
		var c := m.albedo_color
		if not alb:
			print("MATPROBE   ! M_Paint 丢了 albedo 贴图")
			_bad += 1
		if absf(c.r - 1.0) > 0.01 or absf(c.g - 1.0) > 0.01 or absf(c.b - 1.0) > 0.01:
			print("MATPROBE   ! M_Paint 的 albedo_color 不是白的（%.2f,%.2f,%.2f），阵营涂装会被二次相乘"
					% [c.r, c.g, c.b])
			_bad += 1
	if name == "M_TankMetal" and not alb:
		print("MATPROBE   ! M_TankMetal 丢了 albedo 贴图（钢色烘在贴图里，会变纯白）")
		_bad += 1
	if alb and not orm:
		print("MATPROBE   ! %s 有 albedo 但没接上 ORM（粗糙度/金属度会退回因子值）" % name)
		_bad += 1


func _yn(v: bool) -> String:
	return "Y" if v else "N"


func _chan(c: int) -> String:
	match c:
		BaseMaterial3D.TEXTURE_CHANNEL_RED: return "R"
		BaseMaterial3D.TEXTURE_CHANNEL_GREEN: return "G"
		BaseMaterial3D.TEXTURE_CHANNEL_BLUE: return "B"
		BaseMaterial3D.TEXTURE_CHANNEL_ALPHA: return "A"
		_: return "?"
