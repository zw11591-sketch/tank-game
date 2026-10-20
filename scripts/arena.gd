class_name Arena
extends Node3D
## 3D 战场：网格化地形、可破坏掩体、基地、A* 寻路网格与视线查询。
##
## 网格坐标 (x, y) 中 y 沿 +Z 增长，因此"下方"(y 大) 是玩家基地一侧，
## 玩家默认朝 -Z（画面深处）前进。所有几何体均在运行时用图元网格生成。

const CELL := 4.0
const GRID_W := 24
const GRID_H := 24
const ORIGIN_X := -GRID_W * CELL * 0.5
const ORIGIN_Z := -GRID_H * CELL * 0.5

const EMPTY := 0
const BRICK := 1
const STEEL := 2
const WATER := 3
## 路障格：沙袋 / 拒马 / 残骸堆成的低矮障碍。挡车不挡弹不挡视线，
## 于是"能打过去但开不过去"，与水面是同一类规则，战术上多一种可用地形。
const BARRICADE := 4
const BASE := 5

const BRICK_H := 3.0
const STEEL_H := 4.4
const WATER_H := 0.5
const BARRICADE_H := 1.5
const BASE_H := 3.2

const BRICK_HP := 60

## 贴花上限：超过就回收最旧的一枚，避免一局打下来堆出几千个 Decal
const MAX_SCORCH := 90
const MAX_TRACK := 160

# 基地所在的两格与其外围可加固的砖墙格
const BASE_CELLS := [Vector2i(11, 21), Vector2i(12, 21)]

## 地形表。每一项同时决定两件事：掩体的摆法（layout）与整张图的光照色调。
## 玩法规则对所有地形一致——变的是掩体密度、通路形状与可视环境，
## 所以同一套操控与 AI 在六张图上都成立，但战斗节奏完全不同。
##
## 配光照时有一条硬约束：**敌人必须看得见**。可读性不是感觉，是两个能量出来的数
## （tools/vis_probe.gd 逐张图测：45 米外放一辆中型敌车，侧身受光，量像素）：
##   enemyLum >= 0.20   敌车自身像素的平均亮度。低于这个值，车体在普通显示器上
##                      已经压进黑场，朝向、炮管、受击面全都读不出来。
##   weber    >= 0.10   敌车与紧邻背景的亮度差 |Le-Lb|/Lb。亮度够但差值不够，
##                      就是"迷彩生效"——车和地面同一个灰阶，轮廓挑不出来。
## 两条缺一不可，而且是**结果**判据：下面这些颜色与强度只是手段，改完必须重测。
##
## 以前这里写的是手段判据（ambient >= 0.80 / sun_energy >= 0.90 / fog <= 0.0055），
## 十二张图全部"达标"，但夜战与熔岩两张图实测 enemyLum 只有 0.11-0.16。
## 原因是 ambient 是**乘在天空颜色上的系数**而不是光量：夜图天空本身就接近黑，
## 系数填到 0.82 乘出来仍然是 0.15。所以手段判据根本没在约束任何东西——
## 这就是"场景太暗看不见敌人"的根。现在环境光由 _apply_terrain_env() 兜底
## （见 AMBIENT_SKY_REF），判据也换成直接量敌车。
##
## layout 取值见 _build_layout()：
##   ruins 街区废墟 / fortress 纵向回廊 / valley 水网渡口
##   maze 细墙迷宫 / badlands 开阔荒原 / snow 冰原哨所
##   docks 工业港区 / crater 环形弹坑 / jungle 丛林小径 / night 夜战市区
##   desert 沙漠沙垄 / rail 铁路枢纽
## 环境光兜底的参考天空亮度。天空（上半球 + 地平 + 下半球加权）的亮度到这个值时，
## 纯天空环境光已经足够把阴影面提出黑场；低于它就按比例掺入显式环境色补足。
## 于是"这张图很暗"仍然成立（太阳、雾、地面色都没动），但阴影面不会掉进纯黑，
## 车体朝向与受击面始终读得出来——压的是色调，不是信息。
const AMBIENT_SKY_REF := 0.26
## 显式环境色最多占到多少。留一点天空成分，环境光才仍有地形的冷暖倾向，
## 不会十二张图共用一盏白灯。
const AMBIENT_FILL_MAX := 0.62

const TERRAINS := [
	{
		"name": "废墟城区", "layout": "ruins",
		"sky_top": Color(0.09, 0.13, 0.25), "sky_hor": Color(0.46, 0.36, 0.30),
		"gnd_bot": Color(0.08, 0.08, 0.075), "gnd_hor": Color(0.32, 0.27, 0.23),
		"sun": Color(1.00, 0.88, 0.72), "sun_energy": 1.32, "sun_rot": Vector3(-46, -38, 0),
		"fill": Color(0.55, 0.68, 0.95),
		"fog": Color(0.34, 0.31, 0.32), "fog_density": 0.0032, "ambient": 0.88,
		"soil_low": Color(0.18, 0.18, 0.15), "soil_high": Color(0.35, 0.33, 0.27),
		"props": 0.32, "exposure": 1.18,
	},
	{
		# 要塞回廊：纵向回廊把天空挡掉大半，环境光几乎只剩补光，
		# 于是它是改造中重点提亮的两张图之一（当时的读数 0.14，判据 0.20）。
		# 定住相机后重测：45 米外敌车的最暗一面 0.32（tools/vis_probe.gd）。
		"name": "要塞回廊", "layout": "fortress",
		"sky_top": Color(0.05, 0.07, 0.12), "sky_hor": Color(0.24, 0.27, 0.33),
		"gnd_bot": Color(0.05, 0.06, 0.07), "gnd_hor": Color(0.20, 0.22, 0.25),
		"sun": Color(0.80, 0.86, 1.00), "sun_energy": 1.30, "sun_rot": Vector3(-58, 24, 0),
		"fill": Color(0.42, 0.52, 0.72),
		"fog": Color(0.30, 0.33, 0.38), "fog_density": 0.0042, "ambient": 0.86,
		"soil_low": Color(0.17, 0.18, 0.20), "soil_high": Color(0.32, 0.33, 0.36),
		"props": 0.22, "exposure": 1.10,
	},
	{
		"name": "河谷渡口", "layout": "valley",
		"sky_top": Color(0.08, 0.17, 0.26), "sky_hor": Color(0.52, 0.52, 0.42),
		"gnd_bot": Color(0.06, 0.09, 0.07), "gnd_hor": Color(0.26, 0.31, 0.22),
		"sun": Color(1.00, 0.95, 0.84), "sun_energy": 1.35, "sun_rot": Vector3(-52, -115, 0),
		"fill": Color(0.58, 0.78, 0.86),
		"fog": Color(0.42, 0.46, 0.42), "fog_density": 0.0040, "ambient": 0.92,
		"soil_low": Color(0.12, 0.15, 0.10), "soil_high": Color(0.27, 0.31, 0.19),
		"props": 0.28, "exposure": 1.12,
	},
	{
		"name": "迷宫街区", "layout": "maze",
		"sky_top": Color(0.13, 0.10, 0.20), "sky_hor": Color(0.62, 0.34, 0.22),
		"gnd_bot": Color(0.09, 0.07, 0.06), "gnd_hor": Color(0.36, 0.25, 0.18),
		"sun": Color(1.00, 0.80, 0.60), "sun_energy": 1.40, "sun_rot": Vector3(-34, -62, 0),
		"fill": Color(0.46, 0.52, 0.86),
		"fog": Color(0.40, 0.29, 0.26), "fog_density": 0.0036, "ambient": 0.86,
		"soil_low": Color(0.20, 0.17, 0.14), "soil_high": Color(0.38, 0.32, 0.25),
		"props": 0.26, "exposure": 1.12,
	},
	{
		"name": "开阔荒原", "layout": "badlands",
		"sky_top": Color(0.16, 0.26, 0.42), "sky_hor": Color(0.72, 0.62, 0.45),
		"gnd_bot": Color(0.14, 0.12, 0.09), "gnd_hor": Color(0.48, 0.40, 0.28),
		"sun": Color(1.00, 0.96, 0.86), "sun_energy": 1.55, "sun_rot": Vector3(-68, -14, 0),
		"fill": Color(0.62, 0.72, 0.92),
		"fog": Color(0.56, 0.50, 0.40), "fog_density": 0.0022, "ambient": 1.00,
		"soil_low": Color(0.22, 0.18, 0.12), "soil_high": Color(0.45, 0.38, 0.26),
		"props": 0.18,
	},
	{
		"name": "雪原哨所", "layout": "snow",
		"sky_top": Color(0.18, 0.24, 0.34), "sky_hor": Color(0.68, 0.72, 0.78),
		"gnd_bot": Color(0.30, 0.34, 0.38), "gnd_hor": Color(0.62, 0.66, 0.70),
		"sun": Color(0.92, 0.95, 1.00), "sun_energy": 1.40, "sun_rot": Vector3(-34, 56, 0),
		"fill": Color(0.70, 0.80, 1.00),
		"fog": Color(0.62, 0.66, 0.72), "fog_density": 0.0050, "ambient": 1.05,
		"soil_low": Color(0.46, 0.50, 0.54), "soil_high": Color(0.76, 0.80, 0.84),
		"props": 0.20,
	},
	{
		# 纵向船坞 + 码头水道。掩体极密、通路笔直，是最适合埋伏与贴脸的一张图。
		"name": "工业港区", "layout": "docks",
		"sky_top": Color(0.07, 0.11, 0.17), "sky_hor": Color(0.38, 0.44, 0.48),
		"gnd_bot": Color(0.06, 0.08, 0.09), "gnd_hor": Color(0.24, 0.28, 0.30),
		"sun": Color(0.86, 0.92, 1.00), "sun_energy": 1.30, "sun_rot": Vector3(-50, 132, 0),
		"fill": Color(0.48, 0.62, 0.80),
		"fog": Color(0.33, 0.38, 0.42), "fog_density": 0.0046, "ambient": 0.88,
		"soil_low": Color(0.19, 0.20, 0.21), "soil_high": Color(0.36, 0.38, 0.39),
		"props": 0.34, "exposure": 1.06,
	},
	{
		# 同心环形掩体：中央是一座火山口阵地，越往里打越难退，适合打攻防拉锯。
		# 色调是熔岩红，但红光的亮度本身就低（同样强度的红光比白光暗三成），
		# 所以这里的太阳与补光都要比视觉印象更强，否则整张图糊成一片暗红、
		# 敌车连轮廓都挑不出来——实测修前 enemyLum 只有 0.09。
		#
		# 全场最难看清的一张图：亮的是成片沙袋与熔岩，敌车却是深红棕，
		# 背光那一面与亮背景差出 0.42 的韦伯对比度——轮廓挑得出来，车本身却压进黑里
		# （实测 enemyLum 最暗 0.12，判据 0.20）。这里给的是曝光 + 环境光两档：
		# 曝光把暗部整体抬起来（ACES 在低光端更陡，抬暗部比抬亮部划算），
		# 环境光再单独补一档背光面的入射量。
		"name": "熔岩弹坑", "layout": "crater",
		"sky_top": Color(0.16, 0.06, 0.07), "sky_hor": Color(0.74, 0.34, 0.16),
		"gnd_bot": Color(0.12, 0.06, 0.05), "gnd_hor": Color(0.44, 0.22, 0.14),
		"sun": Color(1.00, 0.72, 0.50), "sun_energy": 1.42, "sun_rot": Vector3(-34, -96, 0),
		"fill": Color(1.00, 0.58, 0.40),
		"fog": Color(0.50, 0.28, 0.20), "fog_density": 0.0042, "ambient": 1.30,
		"soil_low": Color(0.26, 0.18, 0.14), "soil_high": Color(0.54, 0.34, 0.24),
		"props": 0.24, "exposure": 2.05,
	},
	{
		# 斜向小径织成的网。视野短、拐角多，炮塔回转速度在这里比机动更值钱。
		"name": "丛林小径", "layout": "jungle",
		"sky_top": Color(0.08, 0.16, 0.14), "sky_hor": Color(0.44, 0.54, 0.34),
		"gnd_bot": Color(0.05, 0.09, 0.06), "gnd_hor": Color(0.20, 0.30, 0.17),
		"sun": Color(0.92, 1.00, 0.80), "sun_energy": 1.30, "sun_rot": Vector3(-72, 18, 0),
		"fill": Color(0.52, 0.76, 0.56),
		"fog": Color(0.30, 0.40, 0.29), "fog_density": 0.0048, "ambient": 0.92,
		"soil_low": Color(0.09, 0.14, 0.08), "soil_high": Color(0.22, 0.30, 0.15),
		"props": 0.40,
	},
	{
		# 夜间街区：全场最暗的一张图，但"暗"只能压低色调，不能压掉敌人的轮廓。
		# 旧配置（sun 0.42 / ambient 0.34 / 雾 0.0095 近黑）实测 enemyLum 只有 0.11，
		# 把 sun / ambient 提到 0.92 / 0.82 之后仍然只有 0.15——因为 ambient 是
		# 乘在天空色上的系数，而这张图的天空本身就接近黑，怎么乘都是黑。
		# 现在按"月光夜"重配：月光本身加强、地面反照率翻倍、再给一档曝光补偿。
		# 结果仍然是整场最暗的一张（场景亮度约为白天图的一半），但车看得见。
		#
		# 补一档曝光（1.32 -> 1.50）：重配之后实测最暗一面仍有 0.19 的样本
		# （判据 0.20，见 tools/vis_probe.gd），差一口气。曝光抬的是暗部，
		# 所以"整场最暗"这个定位没变（sceneLum 0.24，全场最低），暗部却过了线。
		"name": "夜战市区", "layout": "night",
		"sky_top": Color(0.06, 0.09, 0.18), "sky_hor": Color(0.22, 0.28, 0.42),
		"gnd_bot": Color(0.07, 0.08, 0.12), "gnd_hor": Color(0.20, 0.23, 0.31),
		"sun": Color(0.72, 0.80, 1.00), "sun_energy": 1.15, "sun_rot": Vector3(-66, 72, 0),
		"fill": Color(0.46, 0.58, 0.90),
		"fog": Color(0.20, 0.24, 0.34), "fog_density": 0.0042, "ambient": 0.95,
		"soil_low": Color(0.17, 0.18, 0.23), "soil_high": Color(0.36, 0.39, 0.47),
		"props": 0.30, "exposure": 1.50,
	},
	{
		# 沙漠风暴：斜向沙垄把开阔地切成几条长廊，沙尘把交战距离压到中段。
		# 掩体长而薄，所以"绕到沙垄另一头"比正面对推更划算。
		"name": "沙漠风暴", "layout": "desert",
		"sky_top": Color(0.42, 0.34, 0.20), "sky_hor": Color(0.80, 0.64, 0.38),
		"gnd_bot": Color(0.28, 0.22, 0.13), "gnd_hor": Color(0.62, 0.50, 0.30),
		"sun": Color(1.00, 0.84, 0.56), "sun_energy": 1.45, "sun_rot": Vector3(-40, -72, 0),
		"fill": Color(0.86, 0.72, 0.52),
		"fog": Color(0.66, 0.54, 0.34), "fog_density": 0.0055, "ambient": 1.10,
		"soil_low": Color(0.34, 0.27, 0.16), "soil_high": Color(0.66, 0.55, 0.34),
		"props": 0.16,
	},
	{
		# 铁路枢纽：平行的车厢与站台。纵向通路极长、横向穿越口稀少，
		# 于是"在哪一排"几乎决定了这一次交火的胜负。
		"name": "铁路枢纽", "layout": "rail",
		"sky_top": Color(0.10, 0.12, 0.16), "sky_hor": Color(0.46, 0.42, 0.38),
		"gnd_bot": Color(0.08, 0.08, 0.08), "gnd_hor": Color(0.26, 0.25, 0.24),
		"sun": Color(0.96, 0.90, 0.80), "sun_energy": 1.32, "sun_rot": Vector3(-56, 152, 0),
		"fill": Color(0.52, 0.58, 0.72),
		"fog": Color(0.34, 0.32, 0.31), "fog_density": 0.0044, "ambient": 0.88,
		"soil_low": Color(0.20, 0.19, 0.18), "soil_high": Color(0.39, 0.37, 0.34),
		"props": 0.30, "exposure": 1.18,
	},
]

var game: Node
var grid: Array = []                  # grid[y][x] -> int
var brick_hp: Dictionary = {}         # Vector2i -> int
var base_hp := 300
var base_max_hp := 300
## 当前地形索引（TERRAINS 的下标）
var terrain := 0

var astar := AStarGrid2D.new()
## 宽体寻路网格：把单格宽通道也当作不可通行。
##
## 普通网格只问"这一格是不是实心"，于是 4.7 m 宽的 Boss 会把 4 m 宽的通道
## 当成正常路线，开进去之后车身左右各压进砖墙 0.345 m
## （tools/_BossCorridorProbe.tscn）——玩家看到的就是"坦克穿墙"。
## 车体轮廓比一格还宽的那些车改走这张网格，于是它会绕远路，而不是硬挤。
##
## 只在**有绕行路线**时生效：宽网格上无路可走时 `find_path(..., true)` 会退回
## 普通网格，宁可挤一次也不能让 AI 因为地图构造而站在那儿不动。
var astar_wide := AStarGrid2D.new()

var _blocks: Dictionary = {}          # Vector2i -> Node3D
var _fortify_cells: Array = []
var _fortified := false
var _blocks_root: Node3D
var _base_node: Node3D
var _base_flag: MeshInstance3D
var _base_model: Node3D
var _mats: Dictionary = {}
var _water_mat: ShaderMaterial
var _props_root: Node3D
var _dust: GPUParticles3D
var _decal_root: Node3D
var _scorches: Array = []
var _tracks: Array = []
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _ground_mi: MeshInstance3D
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
static var _decal_cache: Texture2D
## 地形 → 地面材质。噪声贴图生成有成本，按地形缓存一次即可。
static var _soil_cache: Dictionary = {}


func _ready() -> void:
	_build_materials()
	_build_environment()
	_build_ground()

	_blocks_root = Node3D.new()
	add_child(_blocks_root)
	_decal_root = Node3D.new()
	_decal_root.name = "Decals"
	add_child(_decal_root)

	for grid in [astar, astar_wide]:
		var g: AStarGrid2D = grid
		g.region = Rect2i(0, 0, GRID_W, GRID_H)
		g.cell_size = Vector2(CELL, CELL)
		g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		g.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
		g.update()

	Settings.quality_changed.connect(_apply_quality)
	_apply_quality(Settings.quality)


# ---------------- 坐标换算 ----------------

static func cell_center(x: int, y: int) -> Vector3:
	return Vector3(ORIGIN_X + (x + 0.5) * CELL, 0.0, ORIGIN_Z + (y + 0.5) * CELL)


static func to_cell(p: Vector3) -> Vector2i:
	return Vector2i(int(floor((p.x - ORIGIN_X) / CELL)), int(floor((p.z - ORIGIN_Z) / CELL)))


func cell(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= GRID_W or y >= GRID_H:
		return STEEL
	return grid[y][x]


## 阻挡坦克通行
func blocks_tank(x: int, y: int) -> bool:
	var c := cell(x, y)
	return c == BRICK or c == STEEL or c == WATER or c == BARRICADE or c == BASE


## 阻挡炮弹与视线（水面不挡，形成"能打不能过"的射击走廊）
func blocks_sight(x: int, y: int) -> bool:
	var c := cell(x, y)
	return c == BRICK or c == STEEL or c == BASE


# ---------------- 地图生成 ----------------

func generate(stage: int, terrain_id := 0) -> void:
	terrain = clampi(terrain_id, 0, TERRAINS.size() - 1)
	for n in _blocks.values():
		n.queue_free()
	_blocks.clear()
	brick_hp.clear()
	base_hp = base_max_hp
	_fortified = false
	_clear_decals()

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260910 + stage * 7919 + terrain * 104729

	_new_grid()
	_border()
	_build_layout(rng, stage)
	_place_base()
	_carve_zones()
	_ensure_connectivity()
	_plan_barricades(rng, stage)
	# 收窄检查必须放在路障之后：路障把双车道挤成单车道同样是"转不出去"的来源。
	_widen_lanes()
	_rebuild_all()
	_refresh_base_visual()
	_apply_terrain_env()
	_scatter_props(stage)


func terrain_name() -> String:
	return TERRAINS[terrain]["name"]


func _clear_decals() -> void:
	for pool in [_scorches, _tracks]:
		for d in pool:
			if is_instance_valid(d):
				d.queue_free()
		pool.clear()


func _new_grid() -> void:
	grid.clear()
	for y in GRID_H:
		var row: Array = []
		for x in GRID_W:
			row.append(EMPTY)
		grid.append(row)


func _border() -> void:
	for x in GRID_W:
		grid[0][x] = STEEL
		grid[GRID_H - 1][x] = STEEL
	for y in GRID_H:
		grid[y][0] = STEEL
		grid[y][GRID_W - 1] = STEEL


## 左右镜像放置，保证地图对称、双方进攻路线公平
func _put_mirror(x: int, y: int, t: int) -> void:
	if y < 1 or y >= GRID_H - 1 or x < 1 or x >= GRID_W - 1:
		return
	grid[y][x] = t
	var mx := GRID_W - 1 - x
	if mx != x:
		grid[y][mx] = t


## 地形分派。每种布局只负责往网格里摆 BRICK / STEEL / WATER；
## 基地、出生走廊与连通性由后续统一的 _place_base / _carve_zones / _ensure_connectivity 兜底，
## 所以新增一种地形不必再操心"会不会把路堵死"。
func _build_layout(rng: RandomNumberGenerator, stage: int) -> void:
	match String(TERRAINS[terrain]["layout"]):
		"fortress":
			_layout_fortress(rng, stage)
		"valley":
			_layout_valley(rng, stage)
		"maze":
			_layout_maze(rng, stage)
		"badlands":
			_layout_badlands(rng, stage)
		"snow":
			_layout_snow(rng, stage)
		"docks":
			_layout_docks(rng, stage)
		"crater":
			_layout_crater(rng, stage)
		"jungle":
			_layout_jungle(rng, stage)
		"night":
			_layout_night(rng, stage)
		"desert":
			_layout_desert(rng, stage)
		"rail":
			_layout_rail(rng, stage)
		_:
			_layout_ruins(rng, stage)


## 街区废墟：成团的掩体 + 一两条横向水带。节奏最均衡，是默认战场。
func _layout_ruins(rng: RandomNumberGenerator, stage: int) -> void:
	_scatter_clusters(rng, 9 + mini(stage, 6), 0.14 + minf(stage * 0.05, 0.28))
	_water_bands(rng, 1 if stage < 3 else 2, 1)


## 要塞回廊：纵向长墙切出几条平行通道，交战变成"抢走廊"与侧向偷袭。
func _layout_fortress(rng: RandomNumberGenerator, stage: int) -> void:
	var steel_ratio := 0.45 + minf(stage * 0.04, 0.3)
	for cx in [3, 7, 11]:
		var y := 4
		while y < GRID_H - 6:
			var seg := rng.randi_range(3, 5)
			var t: int = STEEL if rng.randf() < steel_ratio else BRICK
			for i in seg:
				_put_mirror(cx, y + i, t)
			# 段与段之间留 2~3 格的横向穿越口
			y += seg + rng.randi_range(2, 3)
	# 横向短墙：把长走廊切断成若干段，避免变成纯粹的对狙长廊
	for i in 5 + mini(stage, 4):
		var x := rng.randi_range(2, GRID_W / 2 - 1)
		var y := rng.randi_range(6, GRID_H - 7)
		for dx in rng.randi_range(2, 3):
			_put_mirror(x + dx, y, BRICK)


## 河谷渡口：三条水带把战场横向切开，只留少数几处可通行的渡口。
## 水面挡车不挡弹，于是隔河对射与争夺渡口成了主线。
func _layout_valley(rng: RandomNumberGenerator, stage: int) -> void:
	var bands := 2 if stage < 3 else 3
	for i in bands:
		var y := 6 + i * int((GRID_H - 13) / float(maxi(bands, 1)))
		y = clampi(y + rng.randi_range(-1, 1), 5, GRID_H - 7)
		for x in range(1, GRID_W - 1):
			grid[y][x] = WATER
			grid[y + 1][x] = WATER
		# 每条水带开两处渡口（镜像，双方机会对等）
		for k in 2:
			var bx := rng.randi_range(2, GRID_W / 2 - 2)
			for dy in 2:
				_put_mirror(bx, y + dy, EMPTY)
				_put_mirror(bx + 1, y + dy, EMPTY)
		# 渡口两侧的桥头堡
		_put_mirror(rng.randi_range(2, GRID_W / 2 - 1), y - 1, BRICK)
	_scatter_clusters(rng, 5, 0.2)


## 迷宫街区：2~3 格一道细墙织成的网，近战缠斗与拐角遭遇为主。
func _layout_maze(rng: RandomNumberGenerator, stage: int) -> void:
	var fill := 0.6 + minf(stage * 0.03, 0.18)
	for gy in range(5, GRID_H - 5, 3):
		for x in range(1, GRID_W / 2 + 1):
			if rng.randf() < fill:
				_put_mirror(x, gy, BRICK if rng.randf() < 0.82 else STEEL)
	for gx in range(3, GRID_W / 2 + 1, 3):
		for y in range(5, GRID_H - 5):
			if rng.randf() < fill * 0.75:
				_put_mirror(gx, y, BRICK if rng.randf() < 0.86 else STEEL)
	# 开一圈环形外道，保证绕行路线永远存在
	for y in range(4, GRID_H - 4):
		_put_mirror(1, y, EMPTY)


## 开阔荒原：极少的大块掩体 + 一池死水。远距离机动战，几乎无处躲藏。
func _layout_badlands(rng: RandomNumberGenerator, stage: int) -> void:
	for i in 4 + mini(stage / 2, 3):
		var x := rng.randi_range(2, GRID_W / 2 - 2)
		var y := rng.randi_range(5, GRID_H - 8)
		var w := rng.randi_range(2, 3)
		var h := rng.randi_range(2, 3)
		var t: int = STEEL if rng.randf() < 0.55 else BRICK
		for dy in h:
			for dx in w:
				_put_mirror(x + dx, y + dy, t)
	var py := rng.randi_range(8, GRID_H - 11)
	for dy in 3:
		for dx in 4:
			_put_mirror(rng.randi_range(3, 5) + dx, py + dy, WATER)


## 雪原哨所：大片冰湖 + 零散沙袋哨位。通路被湖面挤得很窄，走位代价高。
func _layout_snow(rng: RandomNumberGenerator, stage: int) -> void:
	for i in 2 + mini(stage / 3, 2):
		var cx := rng.randi_range(3, GRID_W / 2 - 1)
		var cy := rng.randi_range(6, GRID_H - 9)
		var r := rng.randi_range(2, 3)
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if dx * dx + dy * dy <= r * r:
					_put_mirror(cx + dx, cy + dy, WATER)
	_scatter_clusters(rng, 6 + mini(stage, 4), 0.3)


## 工业港区：纵向船坞成排排列，中间夹两条码头水道。
## 通路笔直而密集，交战距离被压到很近——这是最适合贴脸与埋伏的一张图。
func _layout_docks(rng: RandomNumberGenerator, stage: int) -> void:
	# 船坞：每隔 3 格一排纵向钢制长条，排与排之间就是泊位通道
	for cx in [2, 5, 8, 11]:
		var y := 5
		while y < GRID_H - 7:
			var seg := rng.randi_range(4, 6)
			for i in seg:
				_put_mirror(cx, y + i, STEEL if rng.randf() < 0.6 else BRICK)
			y += seg + rng.randi_range(2, 3)
	# 两条纵向水道：挡车不挡弹，把港区切成"看得见打得到却过不去"的几块
	for cx in [3, GRID_W - 4]:
		var y0 := rng.randi_range(6, 9)
		var len_ := rng.randi_range(5, 8) + mini(stage, 4)
		for dy in len_:
			var y := y0 + dy
			if y < GRID_H - 6:
				grid[y][cx] = WATER
	# 横向货箱堆：打断过长的直线对狙
	for i in 4 + mini(stage, 4):
		var x := rng.randi_range(2, GRID_W / 2 - 2)
		var y := rng.randi_range(6, GRID_H - 8)
		for dx in rng.randi_range(2, 3):
			_put_mirror(x + dx, y, BRICK)


## 熔岩弹坑：三圈同心环形掩体，每圈只开两个缺口且逐圈错开。
## 往里推进要连破三道口子，退出去同样要绕——攻防拉锯最明显的一张图。
func _layout_crater(rng: RandomNumberGenerator, stage: int) -> void:
	var cx := GRID_W / 2
	var cy := GRID_H / 2
	var rings := [9, 6, 3]
	for ri in rings.size():
		var r: int = rings[ri]
		# 每圈的两个缺口按圈号错开，于是三圈的缺口不会连成一条直线
		var gate := (ri * 2 + rng.randi_range(0, 1)) % 4
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var dd := dx * dx + dy * dy
				if dd < (r - 1) * (r - 1) or dd > r * r:
					continue
				var x := cx + dx
				var y := cy + dy
				if x < 1 or x >= GRID_W - 1 or y < 4 or y >= GRID_H - 5:
					continue
				# 沿着缺口方向开口：把 8 个扇区里的两个留空
				var sector := int((atan2(float(dy), float(dx)) + PI) / (PI * 0.25)) % 8
				if sector == gate or sector == (gate + 4) % 8:
					continue
				grid[y][x] = STEEL if ri == rings.size() - 1 else BRICK
	# 中央熔池：挡车不挡弹，中心阵地因此只能绕着打
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			grid[cy + dy][cx + dx] = WATER
	_scatter_clusters(rng, 4 + mini(stage / 2, 3), 0.25)


## 丛林小径：斜向的短墙织成网，视野被切得很碎。
## 每个拐角都可能贴脸遭遇，炮塔回转速度在这里比机动性更值钱。
func _layout_jungle(rng: RandomNumberGenerator, stage: int) -> void:
	var lines := 10 + mini(stage, 6)
	for i in lines:
		var x := rng.randi_range(2, GRID_W / 2)
		var y := rng.randi_range(5, GRID_H - 8)
		var len_ := rng.randi_range(3, 6)
		# 斜向推进：45° 的短墙既挡视线又不会围成封闭的死格
		var sx := 1 if rng.randf() < 0.5 else -1
		for k in len_:
			_put_mirror(x + k * sx, y + k, BRICK if rng.randf() < 0.88 else STEEL)
	# 两三处林间水洼
	for i in 2 + mini(stage / 3, 2):
		var wx := rng.randi_range(3, GRID_W / 2 - 2)
		var wy := rng.randi_range(7, GRID_H - 9)
		for dy in 2:
			for dx in 2:
				_put_mirror(wx + dx, wy + dy, WATER)


## 夜战市区：规整的方形街区 + 窄街。能见度最低，
## 炮口焰与曳光弹成了判断敌人位置的主要线索。
func _layout_night(rng: RandomNumberGenerator, stage: int) -> void:
	# 2x2 的街块按 3 格间距排布，街道因此永远是贯通的
	for by in range(5, GRID_H - 7, 4):
		for bx in range(2, GRID_W / 2 + 1, 4):
			if rng.randf() < 0.12:
				continue      # 偶尔空出一个街块当广场
			var t: int = STEEL if rng.randf() < 0.22 + minf(stage * 0.03, 0.2) else BRICK
			for dy in 2:
				for dx in 2:
					_put_mirror(bx + dx, by + dy, t)
			# 街块被轰开一角的概率：让轮廓不至于太规整
			if rng.randf() < 0.35:
				_put_mirror(bx + rng.randi_range(0, 1), by + rng.randi_range(0, 1), EMPTY)
	_water_bands(rng, 1, 1)


## 沙漠风暴：几道斜向沙垄（砖）+ 零星岩堆（钢）+ 一小片绿洲。
## 沙垄长而薄，正面绕不过去就得吃亏，于是机动与绕后比对推更有价值。
func _layout_desert(rng: RandomNumberGenerator, stage: int) -> void:
	for i in 5 + mini(stage / 2, 4):
		var x := rng.randi_range(2, GRID_W / 2)
		var y := rng.randi_range(5, GRID_H - 10)
		var len_ := rng.randi_range(4, 8)
		var sx := 1 if rng.randf() < 0.5 else -1
		# 两格进一格的缓坡：沙垄斜着铺开，又不会围成封闭的死格
		for k in len_:
			_put_mirror(x + k * sx, y + int(k / 2), BRICK)
	for i in 3 + mini(stage / 2, 3):
		var rx := rng.randi_range(2, GRID_W / 2 - 1)
		var ry := rng.randi_range(6, GRID_H - 9)
		for dy in 2:
			_put_mirror(rx, ry + dy, STEEL)
	_water_bands(rng, 1, 1)


## 铁路枢纽：几排纵向车厢（钢）夹着站台（砖），每排留错开的穿越口；
## 再用几道横向检修道把过长的纵向通路切断。
func _layout_rail(rng: RandomNumberGenerator, stage: int) -> void:
	for cx in [2, 6, 10]:
		var y := 4 + rng.randi_range(0, 2)
		while y < GRID_H - 7:
			var seg := rng.randi_range(5, 7)
			var platform: bool = rng.randf() < 0.55
			for i in seg:
				_put_mirror(cx, y + i, STEEL)
				if platform and rng.randf() < 0.6:
					_put_mirror(cx + 1, y + i, BRICK)
			y += seg + rng.randi_range(2, 3)
	for i in 3 + mini(stage / 2, 3):
		var x := rng.randi_range(2, GRID_W / 2 - 2)
		var y := rng.randi_range(7, GRID_H - 8)
		for dx in rng.randi_range(2, 4):
			_put_mirror(x + dx, y, BRICK)


## 成团掩体：细长块比方块更适合当掩体，所以 3x3 以上的块会被压成一条。
func _scatter_clusters(rng: RandomNumberGenerator, clusters: int, steel_ratio: float) -> void:
	for i in clusters:
		var x := rng.randi_range(2, GRID_W / 2)
		var y := rng.randi_range(3, GRID_H - 5)
		var w := rng.randi_range(1, 4)
		var h := rng.randi_range(1, 4)
		if w >= 3 and h >= 3:
			if rng.randf() < 0.5:
				h = 1
			else:
				w = 1
		var t: int = STEEL if rng.randf() < steel_ratio else BRICK
		for dy in h:
			for dx in w:
				_put_mirror(x + dx, y + dy, t)


## 横向水带：切断通路、留出对射走廊
func _water_bands(rng: RandomNumberGenerator, bands: int, thickness: int) -> void:
	for i in bands:
		var y := rng.randi_range(6, GRID_H - 9)
		var x0 := rng.randi_range(1, 5)
		var len_ := rng.randi_range(3, 6)
		for dx in len_:
			_put_mirror(x0 + dx, y, WATER)
			if thickness > 1 or rng.randf() < 0.5:
				_put_mirror(x0 + dx, y + 1, WATER)


func _place_base() -> void:
	_fortify_cells.clear()
	for c in BASE_CELLS:
		grid[c.y][c.x] = BASE
	# 基地外圈一圈砖墙
	for x in range(10, 15):
		for y in range(20, 23):
			var cv := Vector2i(x, y)
			if cv in BASE_CELLS:
				continue
			if y == GRID_H - 1:
				continue
			grid[y][x] = BRICK
			_fortify_cells.append(cv)


func _carve_zones() -> void:
	# 敌人出生走廊（顶部三行）
	for y in range(1, 4):
		for x in range(1, GRID_W - 1):
			grid[y][x] = EMPTY
	# 玩家活动区（基地正前方）
	for y in range(17, 20):
		for x in range(9, 15):
			grid[y][x] = EMPTY
	# 基地正上方留一条进出口
	grid[20][11] = EMPTY
	grid[20][12] = EMPTY


## 保证每个敌人出生点都能走到基地，否则沿直线凿开砖墙。
## 迷宫与要塞这类高密度地形要凿的格子更多，所以上限给得宽。
func _ensure_connectivity() -> void:
	_sync_astar()
	var goal := Vector2i(11, 19)
	for sp in spawn_cells():
		var guard := 0
		while astar.get_id_path(sp, goal).is_empty() and guard < 160:
			guard += 1
			_carve_line(sp, goal)
			_sync_astar()


func _carve_line(from: Vector2i, to: Vector2i) -> void:
	var cur := from
	while cur != to:
		if cur.x != to.x:
			cur.x += signi(to.x - cur.x)
		elif cur.y != to.y:
			cur.y += signi(to.y - cur.y)
		var c := cell(cur.x, cur.y)
		var interior := cur.x > 0 and cur.x < GRID_W - 1 and cur.y > 0 and cur.y < GRID_H - 1
		if interior and (c == BRICK or c == WATER or c == STEEL):
			grid[cur.y][cur.x] = EMPTY
			return


## 路障格规划：把一部分空格变成低矮的工事障碍（沙袋 / 拒马 / 残骸 / 管材）。
##
## 散布物过去只是贴在地上的 MultiMesh 装饰——看着是障碍物，开过去却毫无反应，
## 这正是"穿越障碍物"最直接的来源。现在凡是看着实心的散布物都独占一格、
## 进入网格、带真实碰撞体，于是寻路、视线、炮弹与车体碰撞四者说的是同一件事。
##
## 路障挡车但不挡弹、不挡视线，所以它不是墙的替代品，而是一种新的战术地形：
## 能隔着沙袋对射，却不能直接压过去。
##
## 每放一格都立刻重验"所有出生点仍能走到基地"，放不下就原样退回——
## 于是"路障把地图堵死"在构造上不可能发生，不需要事后调参去规避。
func _plan_barricades(rng: RandomNumberGenerator, stage: int) -> void:
	const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var want := 8 + mini(stage, 8)
	var placed := 0
	for attempt in 240:
		if placed >= want:
			break
		var x := rng.randi_range(2, GRID_W / 2)
		var y := rng.randi_range(5, GRID_H - 7)
		if grid[y][x] != EMPTY or not _scatterable(x, y):
			continue
		# 贴着已有掩体长出来的路障才像战场工事；孤零零堵在空地中央既难看又容易挡路，
		# 所以只给它四分之一的概率
		var touching := false
		for d in DIRS:
			if blocks_tank(x + d.x, y + d.y):
				touching = true
				break
		if not touching and rng.randf() > 0.25:
			continue

		var mx := GRID_W - 1 - x
		var mirrored: bool = mx != x and grid[y][mx] == EMPTY and _scatterable(mx, y)
		grid[y][x] = BARRICADE
		if mirrored:
			grid[y][mx] = BARRICADE
		if _spawns_connected():
			placed += 2 if mirrored else 1
			continue
		grid[y][x] = EMPTY
		if mirrored:
			grid[y][mx] = EMPTY


## 单格宽通道对车体是"转向死区"。
##
## 车体要自由回转，需要一块短边不小于**车身对角线**的空地：游隼 3.59 × 5.25 m，
## 对角线 6.34 m，而一格只有 4 m。实测（tools/TurnProbe.tscn）单格走廊里按住 A
## 两秒，车体只转了 9.9° 就再也转不动——玩家读到的就是"左右转向不灵活"。
## Boss（4.70 m 宽）更直接：在单格走廊里整条车身压进砖墙 0.35 m
## （tools/_BossCorridorProbe.gd），这就是"有时候还能看到坦克穿墙"。
##
## 所以地形生成完之后把所有单格通道拓宽一格（4 m → 8 m）。规则是"只做加法"：
##   * 清 BRICK / BARRICADE 优先；STEEL（永久工事）也允许清，但排在砖块之后。
##     原来的规则是"钢墙一律不动"，可单格通道的两侧经常正好是两排钢墙——
##     铁轨（terrain 11）每张图有 22~28 格单格通道，两侧**全是** STEEL，
##     于是最需要拓宽的那三张图一格都没拓宽过（tools/_LaneDiag.tscn）；
##   * WATER（水网）与基地格、基地外围加固墙（_fortify_cells）不动：
##     水是"能打不能过"的地形，抽干它等于改规则；
##   * 至少要有**连续 2 格**可以拓宽才动手。2 格是几何下限而不是随手取的：
##     车体在 55.6° 时外接盒最大，恰好等于对角线 6.34 m；只拓宽一格形成的是
##     4 × 8 m 的壁龛，仍然容不下车身回转，连续两格扩出 8 × 8 m 才够；
##   * 只剩一格长的孤立"门洞"退而求其次：清掉一侧的一格，局部净宽变成 8 m。
##     这种格子容不下原地掉头，但 Boss（4.70 m 宽）能平直通过——
##     而它原来在这里是把 0.345 m 的车身压进两侧砖墙。
##
## 于是"通道再窄也能开过去、但只能在个别地方调头"变成"整条通道都能调头"。
func _widen_lanes() -> void:
	# 多趟：每趟拓宽之后，新露出来的墙面上又可能出现新的单格段。
	# 实测（tools/_LaneDiag.tscn）第 4 趟之后剩余单格段不再随趟数下降。
	for _pass in 4:
		if not _widen_lanes_once():
			return


func _widen_lanes_once() -> bool:
	var changed := false
	# 先纵向（左右夹住）再横向（上下夹住）。同一条通道整段朝同一侧拓宽，
	# 结果是一条干净的 8 m 通道，而不是锯齿状的壁龛。
	for vertical in [true, false]:
		for run in _single_lane_runs(vertical):
			if _widen_lane_run(run, vertical):
				changed = true
	return changed


## 被两侧实心格夹住、只剩一格宽的空地，按列（纵向通道）或按行（横向通道）
## 切成连续段。段长可以只有 1 格：那是一个门洞，对 Boss 的通行宽度同样重要。
func _single_lane_runs(vertical: bool) -> Array:
	var out: Array = []
	var outer := GRID_W if vertical else GRID_H
	var inner := GRID_H if vertical else GRID_W
	for a in range(1, outer - 1):
		var run: Array = []
		for b in range(1, inner - 1):
			var x := a if vertical else b
			var y := b if vertical else a
			if _narrow_at(x, y, vertical):
				run.append(Vector2i(x, y))
			elif run.size() > 0:
				out.append(run)
				run = []
		if run.size() > 0:
			out.append(run)
	return out


## 该空格是不是只有一格宽（沿 vertical 方向延伸、被左右/上下两堵墙夹住）。
## 寻路的宽度惩罚（_sync_astar）也用它，所以两条判据说的是同一件事。
func _narrow_at(x: int, y: int, vertical: bool) -> bool:
	if blocks_tank(x, y):
		return false
	if vertical:
		return blocks_tank(x - 1, y) and blocks_tank(x + 1, y)
	return blocks_tank(x, y - 1) and blocks_tank(x, y + 1)


## 把一段单格通道朝一侧拓宽。
func _widen_lane_run(run: Array, vertical: bool) -> bool:
	var step := Vector2i(1, 0) if vertical else Vector2i(0, 1)

	# 1) 路障造成的收窄：先拆路障。它本来就是"可绕的临时工事"，拆它比拆两格
	#    永久砖墙便宜，也不会改变地图的结构。
	var barricades: Array = []
	for c in run:
		for s in [1, -1]:
			var t: Vector2i = c + step * s
			if cell(t.x, t.y) == BARRICADE and _widenable(t.x, t.y):
				barricades.append(t)
	if barricades.size() > 0:
		for t in barricades:
			grid[t.y][t.x] = EMPTY
		return true

	# 2) 地形造成的收窄：两侧各找最长的一段可拓宽格（2 格起），同长时取拆钢更少的
	#    那一侧。能拆砖就不动钢——钢墙是"永久工事"，只有绕不开时才牺牲它。
	var best: Array = []
	var best_cost := 1 << 30
	for s in [1, -1]:
		var stretch: Array = []
		for c in run + [Vector2i(-1, -1)]:
			var t: Vector2i = c + step * s
			if c != Vector2i(-1, -1) and _widenable(t.x, t.y):
				stretch.append(t)
			else:
				if stretch.size() > 0:
					var cost := _stretch_cost(stretch)
					if stretch.size() > best.size() \
							or (stretch.size() == best.size() and cost < best_cost):
						best = stretch.duplicate()
						best_cost = cost
				stretch = []
	if best.size() >= 2:
		for t in best:
			grid[t.y][t.x] = EMPTY
		return true

	# 3) 只剩一格长的孤立门洞：两侧凑不出连续两格，退而清一格。
	#    局部净宽因此从 4 m 变成 8 m——容不下原地掉头，但 4.70 m 宽的 Boss 能
	#    平直通过（原来在这里它左右各压进砖墙 0.345 m）。只对长度 1 的段动手：
	#    长段这样处理会在一面墙上打出一排门洞。
	if run.size() == 1:
		var c: Vector2i = run[0]
		var pick := Vector2i(-1, -1)
		var pick_cost := 1 << 30
		for s in [1, -1]:
			var t: Vector2i = c + step * s
			if not _widenable(t.x, t.y):
				continue
			var cost := 0 if cell(t.x, t.y) == BRICK else 1
			if cost < pick_cost:
				pick = t
				pick_cost = cost
		if pick.x >= 0:
			grid[pick.y][pick.x] = EMPTY
			return true
	return false


## 一段可拓宽格的"代价"：拆钢墙比拆砖墙贵。清一色砖块 = 0。
func _stretch_cost(stretch: Array) -> int:
	var n := 0
	for t in stretch:
		if cell(t.x, t.y) != BRICK:
			n += 1
	return n


## 这一格能不能为了拓宽通道而清掉。
##
## BRICK / BARRICADE 是首选，STEEL 也允许（调用方会优先选砖块那一侧，见
## `_stretch_cost`）。水、基地格、基地加固圈、基地正面进出口两侧一律不动。
func _widenable(x: int, y: int) -> bool:
	if x < 1 or y < 1 or x >= GRID_W - 1 or y >= GRID_H - 1:
		return false
	var c := cell(x, y)
	if c != BRICK and c != BARRICADE and c != STEEL:
		return false
	var v := Vector2i(x, y)
	if v in _fortify_cells or v in BASE_CELLS:
		return false
	# 基地正前方的进出口两侧是基地的防御工事，拆掉等于把基地敞开
	if y >= 20 and x >= 9 and x <= 15:
		return false
	return true


## 从基地门口泛洪，检查所有敌人出生点与玩家出生格是否仍然可达。
## 直接读 grid 而不碰 astar，所以可以在地图构造中途随意调用。
func _spawns_connected() -> bool:
	const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var start := Vector2i(11, 19)
	var seen := {start: true}
	var stack: Array[Vector2i] = [start]
	while stack.size() > 0:
		var c: Vector2i = stack.pop_back()
		for d in DIRS:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= GRID_W or n.y >= GRID_H:
				continue
			if seen.has(n) or blocks_tank(n.x, n.y):
				continue
			seen[n] = true
			stack.append(n)
	for sp in spawn_cells():
		if not seen.has(sp):
			return false
	return seen.has(Vector2i(GRID_W / 2 - 1, 18))


func spawn_cells() -> Array:
	return [Vector2i(2, 2), Vector2i(GRID_W / 2, 2), Vector2i(GRID_W - 3, 2), Vector2i(6, 2), Vector2i(GRID_W - 7, 2)]


func player_spawn() -> Vector3:
	return cell_center(GRID_W / 2 - 1, 18)


func base_position() -> Vector3:
	return (cell_center(BASE_CELLS[0].x, BASE_CELLS[0].y) + cell_center(BASE_CELLS[1].x, BASE_CELLS[1].y)) * 0.5


# ---------------- 寻路 ----------------

func _sync_astar() -> void:
	for y in GRID_H:
		for x in GRID_W:
			_apply_solid(Vector2i(x, y))


## 把一格的"实心"同步到两张网格上。
##
## 宽体网格额外把**单格宽通道**判成实心，判据与地形生成用的 `_narrow_at()` 是同一个
## 函数，于是"生成时认为这里转不开"与"寻路时认为这里过不去"说的是同一件事。
func _apply_solid(c: Vector2i) -> void:
	var solid := blocks_tank(c.x, c.y)
	astar.set_point_solid(c, solid)
	astar_wide.set_point_solid(c, solid or _narrow_any(c.x, c.y))


func _narrow_any(x: int, y: int) -> bool:
	return _narrow_at(x, y, true) or _narrow_at(x, y, false)


## 拆掉 / 重建一格之后，刷新它自己与周围一圈的两张网格。
##
## 单格宽是一个**邻居关系**：拆掉一格墙会让邻格从"窄"变成"宽"，所以只刷自己
## 是不够的——不刷邻格的话，宽体网格会一直认为那条路走不通，Boss 就永远绕远。
func _refresh_solid_around(c: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			if astar.is_in_boundsv(n):
				_apply_solid(n)


## 返回世界坐标路径点（不含起点）。目标格不可通行时退回到最近的可通行邻格。
##
## `wide` 为 true 时走宽体网格：单格宽通道视为不可通行。Boss 这类车体比一格还宽
## 的目标不能进那种通道（进去就是 0.345 m 的穿墙，见 astar_wide 的注释）。
## 宽网格上无路可走时退回普通网格——绕不过去的时候，能挤过去也比起步就不动好。
func find_path(from: Vector3, to: Vector3, wide := false) -> Array:
	var g := astar_wide if wide else astar
	var a := to_cell(from)
	var b := to_cell(to)
	if not g.is_in_boundsv(a) or not g.is_in_boundsv(b):
		return []
	if g.is_point_solid(a):
		a = _nearest_open(a, g)
	if g.is_point_solid(b):
		b = _nearest_open(b, g)
	if a == Vector2i(-1, -1) or b == Vector2i(-1, -1):
		return find_path(from, to, false) if wide else []
	var ids := g.get_id_path(a, b)
	if ids.is_empty():
		return find_path(from, to, false) if wide else []
	var out: Array = []
	for i in range(1, ids.size()):
		out.append(cell_center(ids[i].x, ids[i].y))
	return out


func _nearest_open(c: Vector2i, g: AStarGrid2D = astar) -> Vector2i:
	for r in range(1, 5):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var n := Vector2i(c.x + dx, c.y + dy)
				if g.is_in_boundsv(n) and not g.is_point_solid(n):
					return n
	return Vector2i(-1, -1)


## 网格步进的视线判定：水面与空地不挡视线
func has_line_of_sight(from: Vector3, to: Vector3) -> bool:
	var d := to - from
	d.y = 0.0
	var dist := d.length()
	if dist < 0.01:
		return true
	var step := d / dist * (CELL * 0.4)
	var n := int(dist / (CELL * 0.4))
	var p := from
	for i in range(1, n):
		p += step
		var c := to_cell(p)
		if blocks_sight(c.x, c.y):
			return false
	return true


# ---------------- 几何约束 ----------------

## 把一个半径为 radius 的圆推出所有实心格，返回修正后的坐标。
##
## move_and_slide() 只保证"这一步不会穿过去"：高速、刁钻入射角、被另一辆坦克挤压、
## 或者刚好站在砖墙被炸开又被加固还原的格子上，都可能让车体啃进掩体里。
## 网格本身是规则的，所以这里直接做一次圆-矩形解交当硬约束——
## 于是"穿过障碍物"在几何上不再可能发生，而不是靠调参去降低概率。
##
## from 是上一个确认安全的位置。两件事靠它：
##   1. 圆心已经完全陷进某格时，沿"来的方向"退出去。原来取最浅的那条边，
##      在单格厚的墙里会把车从墙的另一侧弹出来——那本身就是一次穿墙。
##   2. 实在解不开时（被夹在两堵墙之间）直接回退到 from，宁可顿一下也不穿墙。
func depenetrate(pos: Vector3, radius: float, from := Vector3.INF) -> Vector3:
	var out := pos
	var half := CELL * 0.5
	var has_from: bool = from.x < INF
	for _pass in 3:
		# 分方向累计最深的推出量，最后一次性合成。
		# 关键在于对向的两面墙（单格宽走廊）会在这里相互抵消，车体停在走廊中线上；
		# 原来逐格依次写回坐标，两边的墙会轮流把车推来推去，表现就是走廊里卡死。
		var push_px := 0.0
		var push_nx := 0.0
		var push_pz := 0.0
		var push_nz := 0.0
		var c0 := to_cell(out)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cx: int = c0.x + dx
				var cy: int = c0.y + dy
				if not blocks_tank(cx, cy):
					continue
				var center := cell_center(cx, cy)
				# 圆心到该格矩形的最近点
				var nx := clampf(out.x, center.x - half, center.x + half)
				var nz := clampf(out.z, center.z - half, center.z + half)
				var d := Vector2(out.x - nx, out.z - nz)
				var dist := d.length()
				if dist > radius:
					continue
				var p: Vector2
				if dist > 0.0001:
					p = d / dist * (radius - dist)
				else:
					p = _eject_inside(out, center, half, radius, from, has_from)
				if p.x > 0.0:
					push_px = maxf(push_px, p.x)
				else:
					push_nx = maxf(push_nx, -p.x)
				if p.y > 0.0:
					push_pz = maxf(push_pz, p.y)
				else:
					push_nz = maxf(push_nz, -p.y)
		var off := Vector2(push_px - push_nx, push_pz - push_nz)
		if off.length_squared() < 1e-8:
			return out
		out.x += off.x
		out.z += off.y

	# 三趟还没解开：被夹在两面墙中间。退回上一个安全点，顿一帧远好过穿墙。
	if has_from and blocks_tank(to_cell(out).x, to_cell(out).y):
		return from
	return out


## 圆心已经落在实心格内部时的脱出方向。
## 有来向就朝来向退（沿主轴退出最近的那条边），否则退回"最浅的一条边"。
func _eject_inside(pos: Vector3, center: Vector3, half: float, radius: float,
		from: Vector3, has_from: bool) -> Vector2:
	if has_from:
		var back := Vector2(from.x - center.x, from.z - center.z)
		if back.length_squared() > 1e-6:
			# 沿来向的主轴退出：斜着退会蹭进相邻格，反而更难解
			if absf(back.x) >= absf(back.y):
				var sx := signf(back.x)
				return Vector2(center.x + sx * (half + radius) - pos.x, 0.0)
			var sz := signf(back.y)
			return Vector2(0.0, center.z + sz * (half + radius) - pos.z)
	var lx := pos.x - (center.x - half)
	var rx := (center.x + half) - pos.x
	var lz := pos.z - (center.z - half)
	var rz := (center.z + half) - pos.z
	var m := minf(minf(lx, rx), minf(lz, rz))
	if is_equal_approx(m, lx):
		return Vector2(center.x - half - radius - pos.x, 0.0)
	if is_equal_approx(m, rx):
		return Vector2(center.x + half + radius - pos.x, 0.0)
	if is_equal_approx(m, lz):
		return Vector2(0.0, center.z - half - radius - pos.z)
	return Vector2(0.0, center.z + half + radius - pos.z)


## 随机取一个适合空投补给的空格：避开出生走廊与基地周边，
## 并要求至少两面通路，免得补给落在死胡同里拿不到。
##
## avoid / min_dist 是硬性回避（基地与玩家当前位置），
## soft_avoid / soft_dist 用于彼此拉开距离（已落地的其它补给）——
## 分成两档是因为"离基地远"和"别和另一个箱子挤在一起"要求的距离差了一个量级。
## 找不到合适位置返回 Vector3.INF。
func random_open_cell(avoid: Array, min_dist: float,
		soft_avoid: Array = [], soft_dist: float = 0.0) -> Vector3:
	const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in 90:
		var x := randi_range(2, GRID_W - 3)
		var y := randi_range(5, GRID_H - 5)
		if cell(x, y) != EMPTY:
			continue
		var open := 0
		for d in DIRS:
			if not blocks_tank(x + d.x, y + d.y):
				open += 1
		if open < 2:
			continue
		var p := cell_center(x, y)
		var ok := true
		for a in avoid:
			if p.distance_to(a) < min_dist:
				ok = false
				break
		if ok and soft_dist > 0.0:
			for a in soft_avoid:
				if p.distance_to(a) < soft_dist:
					ok = false
					break
		if ok:
			return p
	return Vector3.INF


# ---------------- 破坏与伤害 ----------------

## 单点命中一格。返回 "brick" / "brick_break" / "steel" / "base" / "none"
func hit_cell(c: Vector2i, dmg: int, pierce_steel: bool) -> String:
	var t := cell(c.x, c.y)
	if t == BRICK:
		var hp: int = brick_hp.get(c, BRICK_HP) - dmg
		if hp <= 0:
			_clear_cell(c)
			return "brick_break"
		brick_hp[c] = hp
		_shade_brick(c, float(hp) / float(BRICK_HP))
		return "brick"
	if t == STEEL:
		if pierce_steel and c.x > 0 and c.x < GRID_W - 1 and c.y > 0 and c.y < GRID_H - 1:
			_clear_cell(c)
			return "brick_break"
		return "steel"
	if t == BASE:
		damage_base(dmg)
		return "base"
	return "none"


## HE 溅射：清除半径内的砖墙
func splash_cells(center: Vector3, radius: float, dmg: int) -> int:
	var broken := 0
	var c0 := to_cell(center)
	var r := int(ceil(radius / CELL))
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := Vector2i(c0.x + dx, c0.y + dy)
			if cell_center(c.x, c.y).distance_to(center) > radius:
				continue
			var t := cell(c.x, c.y)
			if t == BRICK:
				if hit_cell(c, dmg, false) == "brick_break":
					broken += 1
			elif t == BASE:
				damage_base(dmg)
	return broken


func damage_base(dmg: int) -> void:
	if base_hp <= 0:
		return
	base_hp = maxi(0, base_hp - dmg)
	_refresh_base_visual()
	if base_hp <= 0 and game != null:
		game.on_base_destroyed()


func _clear_cell(c: Vector2i) -> void:
	grid[c.y][c.x] = EMPTY
	brick_hp.erase(c)
	if _blocks.has(c):
		_blocks[c].queue_free()
		_blocks.erase(c)
	_refresh_solid_around(c)


## 铁锹道具：临时把基地外圈换成钢墙
func set_fortify(active: bool) -> void:
	if active == _fortified:
		return
	_fortified = active
	for c in _fortify_cells:
		var t := cell(c.x, c.y)
		if active and (t == BRICK or t == EMPTY):
			grid[c.y][c.x] = STEEL
			_respawn_block(c)
		elif not active and t == STEEL:
			grid[c.y][c.x] = BRICK
			brick_hp[c] = BRICK_HP
			_respawn_block(c)


func _respawn_block(c: Vector2i) -> void:
	if _blocks.has(c):
		_blocks[c].queue_free()
		_blocks.erase(c)
	_spawn_block(c)
	_refresh_solid_around(c)


# ---------------- 几何体构建 ----------------

func _rebuild_all() -> void:
	for y in GRID_H:
		for x in GRID_W:
			var c := Vector2i(x, y)
			var t: int = grid[y][x]
			if t == BRICK:
				brick_hp[c] = BRICK_HP
			if t != EMPTY and t != BASE:
				_spawn_block(c)
	_sync_astar()


func _spawn_block(c: Vector2i) -> void:
	var t := cell(c.x, c.y)
	if t == EMPTY or t == BASE:
		return
	var h := BRICK_H
	var mat_key := "brick"
	match t:
		STEEL:
			h = STEEL_H
			mat_key = "steel"
		WATER:
			h = WATER_H
			mat_key = "water"
		BARRICADE:
			h = BARRICADE_H
			mat_key = "barricade"

	var body := StaticBody3D.new()
	body.position = cell_center(c.x, c.y) + Vector3(0, h * 0.5, 0)
	# 水面与路障只挡坦克不挡炮弹：放到第 3 层，炮弹射线不检测该层
	body.collision_layer = 4 if (t == WATER or t == BARRICADE) else 1
	body.collision_mask = 0
	body.set_meta("cell", c)
	body.set_meta("kind", t)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# 水面与路障的碰撞体都高于其网格，确保坦克可靠地被挡住
	box.size = Vector3(CELL, h, CELL)
	if t == WATER:
		box.size.y = 3.0
		shape.position = Vector3(0, 1.5 - h * 0.5, 0)
	elif t == BARRICADE:
		box.size.y = 2.4
		shape.position = Vector3(0, 1.2 - h * 0.5, 0)
	shape.shape = box
	body.add_child(shape)

	if t == BARRICADE:
		# 路障的外观由 _scatter_props 的重型散布物提供（沙袋 / 拒马 / 残骸 / 管材），
		# 所以这里通常不挂任何网格。只有模型整体缺失时才退回一块矮土垒，
		# 免得出现"看不见却撞得到"的隐形墙。
		if Assets.mesh_of("prop_sandbags") == null:
			_attach_block_primitive(body, t, h, mat_key)
	elif not _attach_block_model(body, c, t, h):
		_attach_block_primitive(body, t, h, mat_key)

	_blocks_root.add_child(body)
	_blocks[c] = body


## 按格挂 Blender 模型。变体与朝向由格坐标哈希决定，所以同一张地图每次重建长得一样，
## 相邻两格却不会撞车——这是打破 24x24 网格重复感最省事的办法。
func _attach_block_model(body: StaticBody3D, c: Vector2i, t: int, h: float) -> bool:
	var key := _block_model_key(c, t, 1.0)
	if key.is_empty():
		return false
	var mesh := Assets.block_mesh(key)
	if mesh == null:
		return false

	var mi := MeshInstance3D.new()
	mi.name = "Visual"
	mi.mesh = mesh
	# 模型原点在底面（`Assets.block_mesh` 烘过，横坐标居中、底面 y=0），
	# 碰撞体原点在几何中心，差一个 h/2
	mi.position = Vector3(0, -h * 0.5, 0)
	var rot := _cell_hash(c, 31) % 4
	mi.rotation.y = rot * PI * 0.5
	# 轻微尺寸抖动：横向 ±3%，高度 ±2%，不触碰碰撞体
	var jx := 1.0 + (float(_cell_hash(c, 7) % 61) - 30.0) * 0.001
	var jz := 1.0 + (float(_cell_hash(c, 11) % 61) - 30.0) * 0.001
	var jy := 1.0 + (float(_cell_hash(c, 13) % 41) - 20.0) * 0.001
	mi.scale = Vector3(jx, jy, jz)
	if t == WATER:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = _water_material()
	body.add_child(mi)
	body.set_meta("model", true)
	body.set_meta("model_key", key)
	return true


func _attach_block_primitive(body: StaticBody3D, t: int, h: float, mat_key: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Visual"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(CELL * 0.98, h, CELL * 0.98)
	mi.mesh = mesh
	mi.material_override = _mats[mat_key]
	if t == WATER:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)


## ratio 为砖墙剩余耐久比例，<0.5 时取受损态模型
func _block_model_key(c: Vector2i, t: int, ratio: float) -> String:
	match t:
		BRICK:
			var pool := Assets.BRICK_DAMAGED if ratio < 0.5 else Assets.BRICK_VARIANTS
			return pool[_cell_hash(c, 17) % pool.size()]
		STEEL:
			return Assets.STEEL_VARIANTS[_cell_hash(c, 19) % Assets.STEEL_VARIANTS.size()]
		WATER:
			return Assets.WATER_KEY
	return ""


## 格坐标 → 稳定伪随机数。用乘法散列而非 randi()，保证同一张地图可复现。
func _cell_hash(c: Vector2i, salt: int) -> int:
	var v := (c.x * 73856093) ^ (c.y * 19349663) ^ (salt * 83492791)
	return absi(v) % 1000003


## 砖墙受损反馈：有模型时换成"缺口 + 裸露钢筋"的受损态，
## 没模型时沿用原来的逐渐变暗。两条路径都只改视觉，碰撞体与血量逻辑不动。
func _shade_brick(c: Vector2i, ratio: float) -> void:
	if not _blocks.has(c):
		return
	var body: Node3D = _blocks[c]
	var mi := body.get_node_or_null("Visual") as MeshInstance3D
	if mi == null:
		return

	if body.get_meta("model", false):
		var want := _block_model_key(c, BRICK, ratio)
		if body.get_meta("model_key", "") == want:
			return
		var mesh := Assets.block_mesh(want)
		if mesh != null:
			mi.mesh = mesh
			body.set_meta("model_key", want)
			# 受损态换上去时崩一把碎砖，让"墙快塌了"这件事有听觉与视觉反馈
			Fx.debris(_blocks_root, body.global_position, Vector3.UP, Color(0.5, 0.26, 0.17))
		return

	var m: StandardMaterial3D = _mats["brick"].duplicate()
	m.albedo_color = _mats["brick"].albedo_color * (0.45 + 0.55 * ratio)
	mi.material_override = m


func _build_ground() -> void:
	var size := Vector2(GRID_W * CELL + 60.0, GRID_H * CELL + 60.0)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	# 细分到 48x48：顶点多了才吃得住后面的光照与 SDFGI，单片四边形会出大块色阶
	pm.subdivide_width = 48
	pm.subdivide_depth = 48
	mi.mesh = pm
	mi.material_override = _soil_material(terrain)
	add_child(mi)
	_ground_mi = mi

	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, 2.0, size.y)
	shape.shape = box
	shape.position = Vector3(0, -1.0, 0)
	body.add_child(shape)
	add_child(body)


## 地面材质：两层程序化噪声（泥土底色 + 碎石细节），不落任何贴图文件。
## 底色取自地形表，所以雪原是白的、荒原是黄的，而噪声结构保持一致。
static func _soil_material(idx: int) -> Material:
	if _soil_cache.has(idx):
		return _soil_cache[idx]
	var t: Dictionary = TERRAINS[clampi(idx, 0, TERRAINS.size() - 1)]
	var low: Color = t["soil_low"]
	var high: Color = t["soil_high"]
	var m := StandardMaterial3D.new()
	m.albedo_texture = _noise_tex(512, 7.0, low, high)
	m.uv1_scale = Vector3(14.0, 14.0, 1.0)
	m.roughness = 1.0
	m.roughness_texture = _noise_tex(256, 11.0, Color(0.55, 0.55, 0.55), Color(1, 1, 1))
	m.detail_enabled = true
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	m.detail_albedo = _noise_tex(256, 23.0, Color(0.62, 0.62, 0.62), Color(1.08, 1.06, 1.0))
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
	m.uv2_scale = Vector3(56.0, 56.0, 1.0)
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_soil_cache[idx] = m
	return m


static func _noise_tex(size: int, freq: float, low: Color, high: Color) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq / float(size)
	n.fractal_octaves = 4
	var t := NoiseTexture2D.new()
	t.width = size
	t.height = size
	t.seamless = true
	t.noise = n
	var g := Gradient.new()
	g.set_color(0, low)
	g.set_color(1, high)
	t.color_ramp = g
	return t


## 水面：法线扰动 + 深度边缘渐变 + 屏幕空间折射。
## 玩法规则不变——碰撞体仍是"挡车不挡弹"，这里只换视觉。
func _water_material() -> Material:
	if _water_mat != null:
		return _water_mat
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow : source_color = vec4(0.16, 0.42, 0.44, 1.0);
uniform vec4 deep : source_color = vec4(0.03, 0.10, 0.17, 1.0);
uniform float wave_speed = 0.35;
uniform float wave_height = 0.045;
uniform float edge_fade = 1.4;
uniform float refraction = 0.022;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

// 两组错频的正弦叠加出不重复的涌动，比单波自然得多
float wave(vec2 p, float t) {
	return sin(p.x * 1.7 + t) * 0.5 + sin(p.y * 2.3 - t * 1.3) * 0.3
		+ sin((p.x + p.y) * 3.1 + t * 0.7) * 0.2;
}

void vertex() {
	float t = TIME * wave_speed;
	VERTEX.y += wave(VERTEX.xz, t) * wave_height;
}

void fragment() {
	float t = TIME * wave_speed;
	vec2 p = (NODE_POSITION_WORLD.xz + VERTEX.xz);
	// 以波形的梯度当法线扰动，省掉一张法线贴图
	float e = 0.35;
	float hx = wave(p + vec2(e, 0.0), t) - wave(p - vec2(e, 0.0), t);
	float hz = wave(p + vec2(0.0, e), t) - wave(p - vec2(0.0, e), t);
	NORMAL_MAP = normalize(vec3(-hx * 0.5 + 0.5, -hz * 0.5 + 0.5, 1.0));
	NORMAL_MAP_DEPTH = 1.6;

	// 用深度缓冲算水下厚度：岸边浅、中间深，于是有自然的边缘渐变
	float raw = texture(depth_tex, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float thickness = clamp((-view.z + VERTEX.z) / edge_fade, 0.0, 1.0);

	vec2 off = vec2(hx, hz) * refraction;
	vec3 behind = texture(screen_tex, SCREEN_UV + off).rgb;

	vec3 body = mix(shallow.rgb, deep.rgb, thickness);
	ALBEDO = mix(behind, body, clamp(0.35 + thickness * 0.55, 0.0, 0.92));
	ROUGHNESS = 0.06;
	METALLIC = 0.1;
	SPECULAR = 0.6;
	ALPHA = 1.0;
}
"""
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = sh
	return _water_mat


# ---------------- 场景散布 ----------------

## 散布物分三类，差别在于"看着能不能开过去"必须和实际一致：
##
##   HEAVY  沙袋 / 拒马 / 残骸 / 管材 / 弹药箱 / 油桶——看着实心，
##          只摆在 BARRICADE 格里，每格塞几件填满，背后有真实碰撞体。
##   TALL   路灯 / 枯树——立起来的高杆，视觉上绝不可能开过去，
##          所以同样只摆在 BARRICADE 格里，当工事里立着的那根杆子。
##   FLAT   碎石 / 铁丝网——压过去才合理的东西，随便撒在空地上，不带碰撞。
##
## 过去路灯与枯树走的是 FLAT 这条路：一根 5 米的水泥灯杆撒在空地上却没有碰撞体，
## 开过去直接穿过去——这就是"穿越障碍物"里最刺眼的一种。
const PROP_HEAVY: Array[String] = [
	"prop_sandbags", "prop_hedgehog", "prop_wreck", "prop_pipe",
	"prop_ammocrate", "prop_barrel",
]
const PROP_TALL: Array[String] = ["prop_lamp", "prop_deadtree"]
const PROP_FLAT: Array[String] = ["prop_rubble", "prop_wire"]

## 各散布物的水平足迹半径（米）。只有它决定能不能塞进一格：
## 残骸本体就有 3x4 米，照原样再放大 1.3 倍会整整越过格子边界，
## 伸进旁边那个没有碰撞体的空格里去——于是"看着是障碍物，开过去毫无反应"。
## 格半宽是 2.0 米，所以摆放时一律按 (2.0 - 偏移 - 0.1) / 足迹 去压缩尺寸。
const PROP_FOOT := {
	"prop_sandbags": 1.7, "prop_hedgehog": 1.2, "prop_wreck": 2.6, "prop_pipe": 1.6,
	"prop_ammocrate": 0.7, "prop_barrel": 0.4, "prop_lamp": 1.0, "prop_deadtree": 0.9,
}


## 在空格里散布道具与碎石。每种道具一个 MultiMeshInstance3D，于是无论摆了多少个，
## 每种也只是一次 draw call。出生走廊、玩家活动区与基地通道一律避开，不影响玩法。
func _scatter_props(stage: int) -> void:
	if _props_root != null:
		_props_root.queue_free()
	_props_root = Node3D.new()
	_props_root.name = "Props"
	add_child(_props_root)

	var rng := RandomNumberGenerator.new()
	rng.seed = 918273 + stage * 104729 + terrain * 7919

	var density: float = TERRAINS[terrain]["props"]
	var slots: Dictionary = {}       # 模型键 -> Array[Transform3D]
	for key in Assets.PROP_KEYS:
		slots[key] = []

	for y in range(1, GRID_H - 1):
		for x in range(1, GRID_W - 1):
			var t := cell(x, y)
			if t == BARRICADE:
				_fill_barricade(rng, slots, x, y)
				continue
			if t != EMPTY or not _scatterable(x, y):
				continue
			if rng.randf() > density:
				continue
			var key: String = PROP_FLAT[rng.randi() % PROP_FLAT.size()]
			var pos := cell_center(x, y) + Vector3(
				rng.randf_range(-1.1, 1.1), 0.0, rng.randf_range(-1.1, 1.1))
			var tr := Transform3D.IDENTITY
			tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			tr = tr.scaled(Vector3.ONE * rng.randf_range(0.82, 1.18))
			tr.origin = pos
			slots[key].append(tr)

	for key in slots.keys():
		var list: Array = slots[key]
		if list.is_empty():
			continue
		var mesh := Assets.mesh_of(key)
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = key
		mmi.multimesh = mm
		# 散布物不投阴影：几百个实例的阴影 pass 代价远大于它带来的观感
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_props_root.add_child(mmi)

	_build_dust()


## 把一个路障格塞满：主件居中 + 两三件配件围在边上，偶尔再立一根高杆。
##
## 格子整格都有碰撞体，所以视觉上必须填得够满，玩家才不会觉得"明明有缝却过不去"；
## 反过来，任何一件都不许探出格子边界，否则它会伸进旁边没有碰撞体的空格，
## 变成一个"看得见、撞不到"的假障碍——那正是穿越障碍物的观感来源。
func _fill_barricade(rng: RandomNumberGenerator, slots: Dictionary, x: int, y: int) -> void:
	var center := cell_center(x, y)
	var main: String = PROP_HEAVY[_cell_hash(Vector2i(x, y), 23) % PROP_HEAVY.size()]
	slots[main].append(_prop_xform(rng, main, center, Vector3.ZERO, 1.3))

	for i in rng.randi_range(2, 3):
		var key: String = PROP_HEAVY[rng.randi() % PROP_HEAVY.size()]
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(0.7, 1.15)
		var off := Vector3(cos(a) * d, 0.0, sin(a) * d)
		slots[key].append(_prop_xform(rng, key, center, off, 1.05))

	# 四分之一的路障格立一根高杆（路灯或枯树）。它只出现在实心格里，
	# 所以"立着的东西一定撞得到"这条规则不会被破坏。
	if rng.randf() < 0.25:
		var tall: String = PROP_TALL[rng.randi() % PROP_TALL.size()]
		var off2 := Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
		slots[tall].append(_prop_xform(rng, tall, center, off2, 1.0))


## 按足迹把尺寸压到格内。cap 是期望的最大放大倍数，实际取它与"塞得进去"的较小值。
func _prop_xform(rng: RandomNumberGenerator, key: String, center: Vector3,
		off: Vector3, cap: float) -> Transform3D:
	var foot: float = PROP_FOOT.get(key, 1.0)
	var room := maxf(CELL * 0.5 - off.length() - 0.1, 0.3)
	var s := minf(cap, room / foot)
	s = clampf(s * rng.randf_range(0.88, 1.0), 0.35, cap)
	var tr := Transform3D.IDENTITY
	tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
	tr = tr.scaled(Vector3.ONE * s)
	tr.origin = center + off
	return tr


## 可散布区：避开敌人出生走廊、玩家活动区与基地周边通道
func _scatterable(x: int, y: int) -> bool:
	if y < 4:
		return false
	if y >= 17 and y <= 19 and x >= 9 and x <= 14:
		return false
	if y >= 19 and x >= 9 and x <= 15:
		return false
	return true


## 低强度扬尘：给静止的战场加一点空气感
func _build_dust() -> void:
	var p := GPUParticles3D.new()
	p.name = "Dust"
	p.amount = 160
	p.lifetime = 9.0
	p.preprocess = 5.0
	p.visibility_aabb = AABB(
		Vector3(-GRID_W * CELL * 0.5, 0, -GRID_H * CELL * 0.5),
		Vector3(GRID_W * CELL, 14.0, GRID_H * CELL))

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(GRID_W * CELL * 0.5, 5.0, GRID_H * CELL * 0.5)
	pm.direction = Vector3(0.6, 0.25, 0.2)
	pm.spread = 35.0
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 1.6
	pm.gravity = Vector3(0.2, -0.05, 0.1)
	pm.scale_min = 0.05
	pm.scale_max = 0.16
	pm.color = Color(0.72, 0.66, 0.54, 0.16)
	p.process_material = pm
	p.draw_pass_1 = _soft_quad(Color(0.72, 0.66, 0.54, 0.16))
	p.position = Vector3(0, 5.0, 0)
	add_child(p)
	_dust = p


func _soft_quad(col: Color) -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.albedo_texture = _soft_dot()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.disable_receive_shadows = true
	q.material = m
	return q


## 径向渐变软点：烟雾与扬尘的粒子贴图，取代原来的纯色立方体
static func _soft_dot() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.55, Color(1, 1, 1, 0.55))
	var t := GradientTexture2D.new()
	t.width = 64
	t.height = 64
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t


# ---------------- 贴花：战场痕迹 ----------------

## 爆炸烧灼痕。半径按爆炸规模缩放，超出上限时回收最旧的一枚。
func add_scorch(pos: Vector3, size := 1.0) -> void:
	_push_decal(pos, randf_range(0.0, TAU), Vector3(4.0 * size, 2.0, 4.0 * size),
		Color(0.05, 0.045, 0.04, 0.85), _scorches, MAX_SCORCH)


## HE 弹坑：比烧灼痕更小更深
func add_crater(pos: Vector3, size := 1.0) -> void:
	_push_decal(pos, randf_range(0.0, TAU), Vector3(2.6 * size, 1.6, 2.6 * size),
		Color(0.10, 0.08, 0.06, 0.95), _scorches, MAX_SCORCH)


## 履带印：按行驶距离间隔投放，拉长成矩形
func add_track(pos: Vector3, yaw: float) -> void:
	_push_decal(pos, yaw, Vector3(3.2, 1.2, 1.5),
		Color(0.14, 0.12, 0.10, 0.5), _tracks, MAX_TRACK)


func _push_decal(pos: Vector3, yaw: float, size: Vector3, col: Color,
		pool: Array, cap: int) -> void:
	if _decal_root == null or Settings.quality == Settings.Quality.LOW:
		return
	var d := Decal.new()
	d.texture_albedo = _decal_tex()
	d.size = size
	d.modulate = col
	d.albedo_mix = col.a
	d.upper_fade = 1.5
	d.lower_fade = 0.3
	d.position = Vector3(pos.x, 0.02, pos.z)
	d.rotation.y = yaw
	d.cull_mask = 0xFFFFF
	_decal_root.add_child(d)
	pool.append(d)
	while pool.size() > cap:
		var old = pool.pop_front()
		if is_instance_valid(old):
			old.queue_free()


static func _decal_tex() -> Texture2D:
	if _decal_cache == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.45, Color(1, 1, 1, 0.8))
		g.add_point(0.75, Color(1, 1, 1, 0.25))
		var t := GradientTexture2D.new()
		t.width = 128
		t.height = 128
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		_decal_cache = t
	return _decal_cache


func _build_base_node() -> void:
	_base_node = Node3D.new()
	_base_node.position = base_position()
	add_child(_base_node)

	if not _build_base_model():
		_build_base_primitive()

	# 基地光柱，远处也能一眼看到
	var light := OmniLight3D.new()
	light.light_color = Color(0.4, 0.9, 1.0)
	light.light_energy = 3.0
	light.omni_range = 18.0
	light.position = Vector3(0, 4.0, 0)
	_base_node.add_child(light)

	# 两格基地的碰撞体
	for c in BASE_CELLS:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta("cell", c)
		body.set_meta("kind", BASE)
		body.position = cell_center(c.x, c.y) - base_position() + Vector3(0, BASE_H * 0.5, 0)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(CELL, BASE_H, CELL)
		shape.shape = box
		body.add_child(shape)
		_base_node.add_child(body)


## 碉堡模型：射击口朝 -Z（敌人来向），与 gen_base.py 的坐标约定一致，无需额外旋转
func _build_base_model() -> bool:
	_base_model = Assets.instantiate(Assets.BASE_KEY)
	if _base_model == null:
		return false
	_base_node.add_child(_base_model)
	return true


func _build_base_primitive() -> void:
	var plinth := MeshInstance3D.new()
	var pb := BoxMesh.new()
	pb.size = Vector3(CELL * 1.7, 1.0, CELL * 1.7)
	plinth.mesh = pb
	plinth.position = Vector3(0, 0.5, 0)
	plinth.material_override = _mats["steel"]
	_base_node.add_child(plinth)

	_base_flag = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.9
	cm.bottom_radius = 1.5
	cm.height = BASE_H
	_base_flag.mesh = cm
	_base_flag.position = Vector3(0, 1.0 + BASE_H * 0.5, 0)
	_base_flag.material_override = _mats["base"]
	_base_node.add_child(_base_flag)


## 基地血量反馈：旗面与信号灯（M_Accent）从青蓝烧到警告红。
## 两条路径表达的是同一条视觉语言，只是着色对象不同。
func _refresh_base_visual() -> void:
	if _base_node == null:
		_build_base_node()
	var ratio := float(base_hp) / float(base_max_hp)
	var col := Color(0.35, 0.85, 1.0).lerp(Color(0.9, 0.2, 0.12), 1.0 - ratio)
	var energy := 0.6 + 1.4 * ratio
	if _base_model != null:
		Assets.tint_emission(_base_model, Assets.MAT_ACCENT, col, energy)
		return
	if _base_flag == null:
		return
	var m: StandardMaterial3D = _mats["base"].duplicate()
	m.albedo_color = col
	m.emission = col
	m.emission_energy_multiplier = energy
	_base_flag.material_override = m


func _build_materials() -> void:
	_mats = {
		"ground": _mat(Color(0.20, 0.21, 0.18), 0.95, 0.0),
		"brick": _mat(Color(0.55, 0.26, 0.16), 0.9, 0.0),
		"steel": _mat(Color(0.42, 0.45, 0.50), 0.35, 0.85),
		"water": _mat(Color(0.10, 0.28, 0.42), 0.08, 0.2),
		"barricade": _mat(Color(0.34, 0.31, 0.24), 0.95, 0.0),
		"base": _mat(Color(0.35, 0.85, 1.0), 0.4, 0.3),
	}
	_mats["water"].albedo_color.a = 0.75
	_mats["water"].transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats["base"].emission_enabled = true
	_mats["base"].emission = Color(0.35, 0.85, 1.0)


func _mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


## 黄昏战场基调。环境本体一次建好，具体开哪些效果交给 _apply_quality 按档位决定，
## 所以低画质能退回改造前的轻量环境，高画质才上 SSAO/SSIL/SDFGI/体积雾。
func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var pm := ProceduralSkyMaterial.new()
	pm.sky_curve = 0.12
	pm.sun_angle_max = 22.0
	pm.sun_curve = 0.08
	sky.sky_material = pm
	env.sky = sky
	_sky_mat = pm

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.75
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# ACES 比 Filmic 更能压住爆炸与炮口焰的高光，不会一开火就糊成白块
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	# 分级 glow：低频层给大范围光晕，高频层保留炮口焰的锐度
	env.set_glow_level(1, 0.6)
	env.set_glow_level(3, 0.9)
	env.set_glow_level(5, 0.5)

	env.ssao_radius = 1.6
	env.ssao_intensity = 2.4
	env.ssao_power = 1.8
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.9

	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.4
	env.sdfgi_energy = 0.9

	env.fog_light_color = Color(0.34, 0.31, 0.32)
	env.fog_density = 0.0032
	env.fog_sky_affect = 0.35
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.52, 0.47, 0.44)
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_gi_inject = 0.6
	env.volumetric_fog_length = 120.0

	# 对比度与饱和度曲线：战场该是灰黄的，但不能灰到看不清敌我涂装
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.06
	env.adjustment_brightness = 1.0

	we.environment = env
	_env = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-46.0, -38.0, 0.0)
	_sun.light_energy = 1.25
	_sun.light_color = Color(1.0, 0.88, 0.72)
	_sun.light_angular_distance = 0.6
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = 190.0
	_sun.directional_shadow_split_1 = 0.05
	_sun.directional_shadow_split_2 = 0.14
	_sun.directional_shadow_split_3 = 0.42
	_sun.directional_shadow_blend_splits = true
	# bias 调小 + normal_bias 兜底：坦克在墙根下不再出现悬空的接触阴影
	_sun.shadow_bias = 0.035
	_sun.shadow_normal_bias = 1.4
	add_child(_sun)

	# 冷色天空填充光：把阴影面从死黑提回来，车体侧面的轮廓才读得出来。
	# 一盏不投影的平行光，开销可以忽略，所以它不随画质档位关闭——
	# 低画质玩家同样需要看得见敌人。
	_fill = DirectionalLight3D.new()
	_fill.rotation_degrees = Vector3(-62.0, 140.0, 0.0)
	_fill.light_energy = 0.3
	_fill.light_color = Color(0.55, 0.68, 0.95)
	_fill.shadow_enabled = false
	add_child(_fill)

	_apply_terrain_env()


## 把当前地形的色调写进天空、太阳、雾与地面材质。
## 只改颜色与强度，不碰任何几何或玩法参数，所以换地形不会影响判定；
## 具体开哪些后处理仍由 _apply_quality 的档位决定。
func _apply_terrain_env() -> void:
	var t: Dictionary = TERRAINS[terrain]
	if _sky_mat != null:
		_sky_mat.sky_top_color = t["sky_top"]
		_sky_mat.sky_horizon_color = t["sky_hor"]
		_sky_mat.ground_bottom_color = t["gnd_bot"]
		_sky_mat.ground_horizon_color = t["gnd_hor"]
	if _env != null:
		_env.ambient_light_energy = t["ambient"]
		# 天空当环境光源时，ambient_light_energy 乘的是天空颜色而不是光量，
		# 所以夜图这种天空接近黑的地形，系数填多少都等于没填。
		# 这里按天空亮度缺多少就掺多少显式环境色，给环境光一个与色调无关的底。
		var sky_lum: float = (
				float((t["sky_top"] as Color).get_luminance()) * 0.2
				+ float((t["sky_hor"] as Color).get_luminance()) * 0.5
				+ float((t["gnd_hor"] as Color).get_luminance()) * 0.3)
		var fill_share := clampf(1.0 - sky_lum / AMBIENT_SKY_REF, 0.0, AMBIENT_FILL_MAX)
		_env.ambient_light_sky_contribution = 1.0 - fill_share
		# 补的是"天上散下来的光"，所以取补光色往白里提一点，而不是直接用白光
		_env.ambient_light_color = (t["fill"] as Color).lerp(Color(1, 1, 1), 0.35)
		_env.fog_light_color = t["fog"]
		_env.fog_density = t["fog_density"]
		_env.volumetric_fog_albedo = (t["fog"] as Color).lightened(0.15)
		_env.volumetric_fog_density = clampf(float(t["fog_density"]) * 3.4, 0.006, 0.03)
		_apply_exposure()
	if _sun != null:
		_sun.light_color = t["sun"]
		_sun.light_energy = t["sun_energy"]
		_sun.rotation_degrees = t["sun_rot"]
	if _fill != null:
		_fill.light_color = t["fill"]
		# 补光强度与阳光**实际光量**反向（强度 × 颜色亮度，不是强度本身）：
		# 偏暖偏冷的太阳颜色亮度能差三成，只看 sun_energy 会把橙色低阳的图
		# 误判成"阳光很足"，于是该补的光没补上，暗图上的坦克只剩一团黑影。
		var sun_power := float(t["sun_energy"]) * float((t["sun"] as Color).get_luminance())
		_fill.light_energy = lerpf(0.62, 0.30, clampf(sun_power / 1.3, 0.0, 1.0))
	if _ground_mi != null:
		_ground_mi.material_override = _soil_material(terrain)


## 曝光 = 玩家的亮度设置 × 该地形的曝光补偿。
##
## 补偿是必要的：ACES 曲线在低光端压得很狠，夜战与熔岩这类图把太阳和地面色
## 一起压暗之后，画面落在曲线最平的那一段，再怎么调环境光也只是把黑抬成深灰。
## 曝光补偿作用在色调映射之前，等于"给这张图换一档快门"，整体提亮而不改相对对比，
## 所以暗图仍然比亮图暗，只是不再暗到看不见车。
func _apply_exposure() -> void:
	if _env == null:
		return
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	_env.tonemap_exposure = Settings.brightness * float(t.get("exposure", 1.0))


## 画质档位：低档只留雾与阴影，中档加 SSAO + 体积雾，高档再开 SSIL 与 SDFGI。
func _apply_quality(level: int) -> void:
	if _env == null:
		return
	var mid := level >= Settings.Quality.MEDIUM
	var high := level >= Settings.Quality.HIGH

	_env.ssao_enabled = mid
	_env.ssil_enabled = high
	_env.sdfgi_enabled = high
	_env.fog_enabled = true
	_env.volumetric_fog_enabled = mid
	_env.glow_enabled = mid
	_env.adjustment_enabled = mid
	# 曝光不归画质管：它是可读性的总开关，低画质下同样要生效
	_apply_exposure()

	if _sun != null:
		_sun.directional_shadow_mode = (
			DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if high
			else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		)
		_sun.directional_shadow_max_distance = 190.0 if mid else 120.0
	if _dust != null:
		_dust.emitting = mid
	if _decal_root != null:
		_decal_root.visible = mid
		if not mid:
			_clear_decals()
