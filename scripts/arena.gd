class_name Arena
extends Node3D
## 3D 战场：网格化地形、可破坏掩体、基地、A* 寻路网格与视线查
## 
## 网格坐标 (x, y) y +Z 增长，因下方"(y  是玩家基地一侧，
## 玩家默认-Z（画面深处）前进。所有几何体均在运行时用图元网格生成
const CELL := 4.0
const GRID_W := 24
const GRID_H := 24
const ORIGIN_X := -GRID_W * CELL * 0.5
const ORIGIN_Z := -GRID_H * CELL * 0.5

const EMPTY := 0
const BRICK := 1
const STEEL := 2
const WATER := 3
## 路障格：沙袋 / 拒马 / 残骸堆成的低矮障碍。挡车不挡弹不挡视线## 于是"能打过去但开不过，与水面是同一类规则，战术上多一种可用地
const BARRICADE := 4
const BASE := 5
## 半高掩体：一排沙袋墙。挡住车体、挡不住炮弹与视线
## 玩家能躲在后面只露出炮塔开火，这是"全高实体之外最缺的一类掩
const SAND := 6

const BRICK_H := 3.0
const STEEL_H := 4.4
const WATER_H := 0.5
const BARRICADE_H := 1.5
const SAND_H := 1.12
const BASE_H := 3.2

const BRICK_HP := 60

## 贴花上限：超过就回收最旧的一枚，避免一局打下来堆出几千个 Decal
const MAX_SCORCH := 90
const MAX_TRACK := 160

# 基地所在的两格与其外围可加固的砖墙
const BASE_CELLS := [Vector2i(11, 21), Vector2i(12, 21)]

## 边界土坡的断面：(距最外圈墙内侧面的水平距
## 高度)
## 内坡陡、坡肩圆、外坡缓；坡脚压到地面以下，坡体才不会与地面留一条硬边
## 放在类常量里是为了让 `_cliff_surface_y()` 能按同一份断面算坡面高度
## 坡面顶点会被低频起伏（_cliff_swell）同时平
## out 与缩
## y
## 散落石头如果直接查这份名义断面，就会浮在坡面上方
const CLIFF_PROFILE := [
	Vector2(0.0, -1.4),
	Vector2(0.9, 0.6),
	Vector2(2.2, 2.5),
	Vector2(3.8, 4.4),
	Vector2(5.4, 5.2),
	Vector2(7.2, 4.8),
	Vector2(9.4, 3.4),
	Vector2(12.2, 1.0),
	Vector2(14.6, -1.4),
]

## 地形表。每一项同时决定两件事：掩体的摆法（layout）与整张图的光照色调## 玩法规则对所有地形一致——变的是掩体密度、通路形状与可视环境，
## 所以同一套操控与 AI 在六张图上都成立，但战斗节奏完全不同##
## 配光照时有一条硬约束*敌人必须看得*。可读性不是感觉，是两个能量出来的## （tools/vis_probe.gd 逐张图测5 米外放一辆中型敌车，侧身受光，量像素）：
##   enemyLum >= 0.20   敌车自身像素的平均亮度。低于这个值，车体在普通显示器##                      已经压进黑场，朝向、炮管、受击面全都读不出来##   weber    >= 0.10   敌车与紧邻背景的亮度|Le-Lb|/Lb。亮度够但差值不够，
##                      就是"迷彩生效"——车和地面同一个灰阶，轮廓挑不出来## 两条缺一不可，而且*结果**判据：下面这些颜色与强度只是手段，改完必须重
## 
## 以前这里写的是手段判据（ambient >= 0.80 / sun_energy >= 0.90 / fog <= 0.0055），
## 十二张图全部"达标"，但夜战与熔岩两张图实测 enemyLum 只有 0.11-0.16## 原因ambient *乘在天空颜色上的系数**而不是光量：夜图天空本身就接近黑## 系数填到 0.82 乘出来仍然是 0.15。所以手段判据根本没在约束任何东西
## 这就场景太暗看不见敌的根。现在环境光_apply_terrain_env() 兜底
## （见 AMBIENT_SKY_REF），判据也换成直接量敌车##
## layout 取值见 _build_layout()##   ruins 街区废墟 / fortress 纵向回廊 / valley 水网渡口
##   maze 细墙迷宫 / badlands 开阔荒/ snow 冰原哨所
##   docks 工业港区 / crater 环形弹坑 / jungle 丛林小径 / night 夜战市区
##   desert 沙漠沙垄 / rail 铁路枢纽
## 环境光兜底的参考天空亮度。天空（上半+ 地平 + 下半球加权）的亮度到这个值时## 纯天空环境光已经足够把阴影面提出黑场；低于它就按比例掺入显式环境色补
## 于是"这张图很仍然成立（太阳、雾、地面色都没动），但阴影面不会掉进纯黑，
## 车体朝向与受击面始终读得出来——压的是色调，不是信
const AMBIENT_SKY_REF := 0.26
## 显式环境色最多占到多少。留一点天空成分，环境光才仍有地形的冷暖倾向## 不会十二张图共用一盏白
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
		"props": 0.32, "exposure": 1.18, "enemy_lift": 0.85,
	},
	{
		# 要塞回廊：纵向回廊把天空挡掉大半，环境光几乎只剩补光，
		# 所以它是重点提亮的两张图之一（原读数 0.14，判据 0.20）。
		# 定住相机后重测：45 米外敌车最暗一面 0.32（见 tools/vis_probe.gd）。
		# enemy_lift 只抬车体底光，不抬整场环境光，否则画面又回到平光。
		"name": "要塞回廊", "layout": "fortress",
		"sky_top": Color(0.05, 0.07, 0.12), "sky_hor": Color(0.24, 0.27, 0.33),
		"gnd_bot": Color(0.05, 0.06, 0.07), "gnd_hor": Color(0.20, 0.22, 0.25),
		"sun": Color(0.80, 0.86, 1.00), "sun_energy": 1.30, "sun_rot": Vector3(-58, 24, 0),
		"fill": Color(0.42, 0.52, 0.72),
		"fog": Color(0.30, 0.33, 0.38), "fog_density": 0.0042, "ambient": 0.86,
		"soil_low": Color(0.17, 0.18, 0.20), "soil_high": Color(0.32, 0.33, 0.36),
		"props": 0.22, "exposure": 1.22, "enemy_lift": 2.00,
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
		"props": 0.26, "exposure": 1.22, "enemy_lift": 1.05,
	},
	{
		"name": "开阔荒漠", "layout": "badlands",
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
		# 纵向船坞 + 码头水道。掩体极密、通路笔直，是最适合埋伏与贴脸的一张图
		"name": "工业港区", "layout": "docks",
		"sky_top": Color(0.07, 0.11, 0.17), "sky_hor": Color(0.38, 0.44, 0.48),
		"gnd_bot": Color(0.06, 0.08, 0.09), "gnd_hor": Color(0.24, 0.28, 0.30),
		"sun": Color(0.86, 0.92, 1.00), "sun_energy": 1.30, "sun_rot": Vector3(-50, 132, 0),
		"fill": Color(0.48, 0.62, 0.80),
		"fog": Color(0.33, 0.38, 0.42), "fog_density": 0.0046, "ambient": 0.88,
		"soil_low": Color(0.19, 0.20, 0.21), "soil_high": Color(0.36, 0.38, 0.39),
		"props": 0.34, "exposure": 1.06, "enemy_lift": 0.85,
	},
	{
		# 同心环形掩体：中央是一座火山口阵地，越往里打越难退，适合打攻防拉
		# 色调是熔岩红，但红光的亮度本身就低（同样强度的红光比白光暗三成）
		# 所以这里的太阳与补光都要比视觉印象更强，否则整张图糊成一片暗
		# 敌车连轮廓都挑不出来——实测修enemyLum 只有 0.09
		# 
		# 全场最难看清的一张图：亮的是成片沙袋与熔岩，敌车却是深红棕，
		# 背光那一面与亮背景差0.42 的韦伯对比度——轮廓挑得出来，车本身却压进黑里
		# （实enemyLum 最0.12，判0.20）。这里给的是曝光 + 环境光两档：
		# 曝光把暗部整体抬起来（ACES 在低光端更陡，抬暗部比抬亮部划算），
		# 环境光再单独补一档背光面的入射量
		"name": "熔岩弹坑", "layout": "crater",
		"sky_top": Color(0.16, 0.06, 0.07), "sky_hor": Color(0.74, 0.34, 0.16),
		"gnd_bot": Color(0.12, 0.06, 0.05), "gnd_hor": Color(0.44, 0.22, 0.14),
		"sun": Color(1.00, 0.72, 0.50), "sun_energy": 1.42, "sun_rot": Vector3(-34, -96, 0),
		"fill": Color(1.00, 0.58, 0.40),
		"fog": Color(0.50, 0.28, 0.20), "fog_density": 0.0042, "ambient": 1.30,
		"soil_low": Color(0.26, 0.18, 0.14), "soil_high": Color(0.54, 0.34, 0.24),
		"props": 0.24, "exposure": 2.05, "enemy_lift": 0.40,
	},
	{
		# 斜向小径织成的网。视野短、拐角多，炮塔回转速度在这里比机动更值钱
		"name": "丛林小径", "layout": "jungle",
		"sky_top": Color(0.08, 0.16, 0.14), "sky_hor": Color(0.44, 0.54, 0.34),
		"gnd_bot": Color(0.05, 0.09, 0.06), "gnd_hor": Color(0.20, 0.30, 0.17),
		"sun": Color(0.92, 1.00, 0.80), "sun_energy": 1.30, "sun_rot": Vector3(-72, 18, 0),
		"fill": Color(0.52, 0.76, 0.56),
		"fog": Color(0.30, 0.40, 0.29), "fog_density": 0.0048, "ambient": 0.92,
		"soil_low": Color(0.09, 0.14, 0.08), "soil_high": Color(0.22, 0.30, 0.15),
		"props": 0.40, "enemy_lift": 0.40,
	},
	{
		# 夜间街区：全场最暗的一张图，但"只能压低色调，不能压掉敌人的轮廓
		# 旧配置（sun 0.42 / ambient 0.34 / 0.0095 近黑）实enemyLum 只有 0.11
		# sun / ambient 提到 0.92 / 0.82 之后仍然只有 0.15——因ambient
		# 乘在天空色上的系数，而这张图的天空本身就接近黑，怎么乘都是黑
		# 现在月光重配：月光本身加强、地面反照率翻倍、再给一档曝光补
		# 结果仍然是整场最暗的一张（场景亮度约为白天图的一半），但车看得见
		# 
		# 补一档曝光（1.32 -> 1.50）：重配之后实测最暗一面仍有 0.19
		# （判据 0.20，见 tools/vis_probe.gd），差一口气。曝光抬的是暗部。
		# 整场最暗的定位没变（sceneLum 0.24，全场最低），暗部却过了线。
		"name": "夜战市区", "layout": "night",
		"sky_top": Color(0.06, 0.09, 0.18), "sky_hor": Color(0.20, 0.24, 0.34),
		"gnd_bot": Color(0.075, 0.08, 0.095), "gnd_hor": Color(0.20, 0.215, 0.25),
		"sun": Color(0.78, 0.84, 1.00), "sun_energy": 1.15, "sun_rot": Vector3(-66, 72, 0),
		"fill": Color(0.56, 0.61, 0.80),
		"fog": Color(0.20, 0.225, 0.27), "fog_density": 0.0042, "ambient": 0.95,
		# 地面反照率向中性灰收：
		# 0.24,0.26,0.33) 的蓝分量比红38%
		# 在满屏都是地面的第三人称视角里，这就整张图泡在蓝墨水的来
		# 冷色只留给月光与天空，地面本身按湿沥青的中性灰
		"soil_low": Color(0.115, 0.12, 0.128), "soil_high": Color(0.245, 0.25, 0.265),
		"props": 0.30, "exposure": 1.62, "enemy_lift": 2.0,
	},
	{
		# 沙漠风暴：斜向沙垄把开阔地切成几条长廊，沙尘把交战距离压到中段
		# 掩体长而薄，所绕到沙垄另一比正面对推更划算
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
		# 于是"在哪一几乎决定了这一次交火的胜负
		"name": "铁路枢纽", "layout": "rail",
		"sky_top": Color(0.10, 0.12, 0.16), "sky_hor": Color(0.46, 0.42, 0.38),
		"gnd_bot": Color(0.08, 0.08, 0.08), "gnd_hor": Color(0.26, 0.25, 0.24),
		"sun": Color(0.96, 0.90, 0.80), "sun_energy": 1.32, "sun_rot": Vector3(-56, 152, 0),
		"fill": Color(0.52, 0.58, 0.72),
		"fog": Color(0.34, 0.32, 0.31), "fog_density": 0.0044, "ambient": 0.88,
		"soil_low": Color(0.20, 0.19, 0.18), "soil_high": Color(0.39, 0.37, 0.34),
		"props": 0.30, "exposure": 1.34, "enemy_lift": 0.45,
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
## 宽体寻路网格：把单格宽通道也当作不可通行##
## 普通网格只这一格是不是实心"，于4.7 m 宽的 Boss 会把 4 m 宽的通道
## 当成正常路线，开进去之后车身左右各压进砖0.345 m
## （tools/_BossCorridorProbe.tscn）——玩家看到的就是"坦克穿墙"## 车体轮廓比一格还宽的那些车改走这张网格，于是它会绕远路，而不是硬
## 
## 只在**有绕行路*时生效：宽网格上无路可走`find_path(..., true)` 会退## 普通网格，宁可挤一次也不能AI 因为地图构造而站在那儿不
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
var _wrecks_root: Node3D
var _scorches: Array = []
var _tracks: Array = []
var _env: Environment
var _sky_mat: ShaderMaterial
var _ridge_near: MeshInstance3D
var _ridge_far: MeshInstance3D
var _ridge_mat_near: StandardMaterial3D
var _ridge_mat_far: StandardMaterial3D
## 场地外的一圈土丘：只负责把"盒子边缘"藏进起伏的地平线
var _berm: MultiMeshInstance3D
var _berm_mat: StandardMaterial3D
## 最外圈钢墙的可见替身：一圈实心球体拼成的土坡。碰撞仍按格，外观不再是一排方
var _cliff: MeshInstance3D
var _cliff_mat: ShaderMaterial
## 坡体每一块的颜色扰动。球体共用一份材质，
## MultiMesh 的实例色打散重复
var _cliff_shade: Array[Color] = []
var _ground_mi: MeshInstance3D
var _roads_root: Node3D
var _road_mat: ShaderMaterial
var _road_cells: Dictionary = {}
var _veg_root: Node3D
var _shore_root: Node3D
## 连续墙段。同一行里视觉状态相同的相邻墙格合成一个 MultiMesh 段：
## 每格仍是一块 4 m 瓦片，但瓦片按格子名义宽度精确平铺，砖缝跨过格界连续，
## 端面只留在段的两端——12 m 的墙才读成一堵墙，而不是三块各自收边的积木。
var _runs_root: Node3D
var _runs_dirty := false
var _runs_pending := false
## 上一次构建墙段时每格的状态，用来判断"这次受击有没有真的改变外观"
var _built_state: Dictionary = {}
## 连续墙的接缝壁柱。现在只在**材质交界**处立一根，
## 段内接缝已经由平铺瓦片消掉，再每 4 m 补柱子会把一面墙重新切成三块
var _joints_root: Node3D
var _joints_dirty := false
var _joints_pending := false
static var _grass_tex_cache: Texture2D
static var _foam_shader: Shader
static var _wet_shader: Shader
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
static var _decal_cache: Dictionary = {}
static var _decal_normal_cache: Dictionary = {}
## 地形 地面材质。噪声贴图生成有成本，按地形缓存一次即
static var _soil_cache: Dictionary = {}


func _ready() -> void:
	_build_materials()
	_build_environment()
	_build_ground()
	_build_berms()
	_build_far_ridge()
	_build_boundary_cliff()

	_blocks_root = Node3D.new()
	add_child(_blocks_root)
	_decal_root = Node3D.new()
	_decal_root.name = "Decals"
	add_child(_decal_root)
	_wrecks_root = Node3D.new()
	_wrecks_root.name = "Wrecks"
	add_child(_wrecks_root)

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
	return c == BRICK or c == STEEL or c == WATER or c == BARRICADE or c == SAND or c == BASE


## 阻挡炮弹与视线（水面不挡，形能打不能的射击走廊）
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
	if _wrecks_root != null:
		for w in _wrecks_root.get_children():
			w.queue_free()

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260910 + stage * 7919 + terrain * 104729

	_new_grid()
	_border()
	_build_layout(rng, stage)
	_place_base()
	_carve_zones()
	_ensure_connectivity()
	_plan_barricades(rng, stage)
	# 收窄检查必须放在路障之后：路障把双车道挤成单车道同样是"转不出去"的来
	_widen_lanes()
	_rebuild_all()
	_refresh_base_visual()
	_road_mat = null
	_build_roads()
	_apply_terrain_env()
	_scatter_props(stage)
	_build_night_street()
	_build_vegetation()


func terrain_name() -> String:
	return TERRAINS[terrain]["name"]


## 敌车涂装的可读性底光。默0.035；暗图在地形表里enemy_lift 抬高## 判据tools/vis_probe.gd enemyLum 0.205 m、三方向两朝向取最暗）## 之所以按地形给值而不是全图统一调亮环境光：环境光一抬，暗部与受光面一## 变亮，画面又回到"没有体积"的平光；底光只作用在车体上，场景对比不受影响
func enemy_readability() -> float:
	return float((TERRAINS[terrain] as Dictionary).get("enemy_lift", 0.035))


func _clear_decals() -> void:
	for pool in [_scorches, _tracks]:
		for d in pool:
			if is_instance_valid(d):
				d.queue_free()
		pool.clear()


## 残骸挂到独立的根节点下：换关时统一清掉，局内则一直留着当掩
func add_wreck(w: Node3D) -> void:
	if _wrecks_root == null:
		_wrecks_root = Node3D.new()
		_wrecks_root.name = "Wrecks"
		add_child(_wrecks_root)
	_wrecks_root.add_child(w)


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


## 左右镜像放置，保证地图对称、双方进攻路线公
func _put_mirror(x: int, y: int, t: int) -> void:
	if y < 1 or y >= GRID_H - 1 or x < 1 or x >= GRID_W - 1:
		return
	grid[y][x] = t
	var mx := GRID_W - 1 - x
	if mx != x:
		grid[y][mx] = t


## 地形分派。每种布局只负责往网格里摆 BRICK / STEEL / WATER## 基地、出生走廊与连通性由后续统一_place_base / _carve_zones / _ensure_connectivity 兜底## 所以新增一种地形不必再操心"会不会把路堵
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


## 街区废墟：成团的掩体 + 一两条横向水带。节奏最均衡，是默认战场
func _layout_ruins(rng: RandomNumberGenerator, stage: int) -> void:
	_scatter_clusters(rng, 9 + mini(stage, 6), 0.14 + minf(stage * 0.05, 0.28))
	_water_bands(rng, 1 if stage < 3 else 2, 1)


## 要塞回廊：纵向长墙切出几条平行通道，交战变抢走与侧向偷
func _layout_fortress(rng: RandomNumberGenerator, stage: int) -> void:
	var steel_ratio := 0.45 + minf(stage * 0.04, 0.3)
	for cx in [3, 7, 11]:
		var y := 4
		while y < GRID_H - 6:
			var seg := rng.randi_range(3, 5)
			var t: int = STEEL if rng.randf() < steel_ratio else BRICK
			for i in seg:
				_put_mirror(cx, y + i, t)
			# 段与段之间留 2~3 格的横向穿越
			y += seg + rng.randi_range(2, 3)
	# 横向短墙：把长走廊切断成若干段，避免变成纯粹的对狙长
	for i in 5 + mini(stage, 4):
		var x := rng.randi_range(2, GRID_W / 2 - 1)
		var y := rng.randi_range(6, GRID_H - 7)
		for dx in rng.randi_range(2, 3):
			_put_mirror(x + dx, y, BRICK)


## 河谷渡口：三条水带把战场横向切开，只留少数几处可通行的渡
## 水面挡车不挡弹，于是隔河对射与争夺渡口成了主
func _layout_valley(rng: RandomNumberGenerator, stage: int) -> void:
	var bands := 2 if stage < 3 else 3
	for i in bands:
		var y := 6 + i * int((GRID_H - 13) / float(maxi(bands, 1)))
		y = clampi(y + rng.randi_range(-1, 1), 5, GRID_H - 7)
		for x in range(1, GRID_W - 1):
			grid[y][x] = WATER
			grid[y + 1][x] = WATER
		# 每条水带开两处渡口（镜像，双方机会对等
		for k in 2:
			var bx := rng.randi_range(2, GRID_W / 2 - 2)
			for dy in 2:
				_put_mirror(bx, y + dy, EMPTY)
				_put_mirror(bx + 1, y + dy, EMPTY)
		# 渡口两侧的桥头堡
		_put_mirror(rng.randi_range(2, GRID_W / 2 - 1), y - 1, BRICK)
	_scatter_clusters(rng, 5, 0.2)


## 迷宫街区~3 格一道细墙织成的网，近战缠斗与拐角遭遇为
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


## 开阔荒原：极少的大块掩+ 一池死水。远距离机动战，几乎无处躲藏
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


## 雪原哨所：大片冰+ 零散沙袋哨位。通路被湖面挤得很窄，走位代价
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


## 工业港区：纵向船坞成排排列，中间夹两条码头水
## 通路笔直而密集，交战距离被压到很近——这是最适合贴脸与埋伏的一张图
func _layout_docks(rng: RandomNumberGenerator, stage: int) -> void:
	# 船坞：每3 格一排纵向钢制长条，排与排之间就是泊位通道
	for cx in [2, 5, 8, 11]:
		var y := 5
		while y < GRID_H - 7:
			var seg := rng.randi_range(4, 6)
			for i in seg:
				_put_mirror(cx, y + i, STEEL if rng.randf() < 0.6 else BRICK)
			y += seg + rng.randi_range(2, 3)
	# 两条纵向水道：挡车不挡弹，把港区切成"看得见打得到却过不去"的几
	for cx in [3, GRID_W - 4]:
		var y0 := rng.randi_range(6, 9)
		var len_ := rng.randi_range(5, 8) + mini(stage, 4)
		for dy in len_:
			var y := y0 + dy
			if y < GRID_H - 6:
				grid[y][cx] = WATER
	# 横向货箱堆：打断过长的直线对
	for i in 4 + mini(stage, 4):
		var x := rng.randi_range(2, GRID_W / 2 - 2)
		var y := rng.randi_range(6, GRID_H - 8)
		for dx in rng.randi_range(2, 3):
			_put_mirror(x + dx, y, BRICK)


## 熔岩弹坑：三圈同心环形掩体，每圈只开两个缺口且逐圈错开## 往里推进要连破三道口子，退出去同样要绕——攻防拉锯最明显的一张图
func _layout_crater(rng: RandomNumberGenerator, stage: int) -> void:
	var cx := GRID_W / 2
	var cy := GRID_H / 2
	var rings := [9, 6, 3]
	for ri in rings.size():
		var r: int = rings[ri]
		# 每圈的两个缺口按圈号错开，于是三圈的缺口不会连成一条直
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
				# 沿着缺口方向开口：8 个扇区里的两个留
				var sector := int((atan2(float(dy), float(dx)) + PI) / (PI * 0.25)) % 8
				if sector == gate or sector == (gate + 4) % 8:
					continue
				grid[y][x] = STEEL if ri == rings.size() - 1 else BRICK
	# 中央熔池：挡车不挡弹，中心阵地因此只能绕着
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			grid[cy + dy][cx + dx] = WATER
	_scatter_clusters(rng, 4 + mini(stage / 2, 3), 0.25)


## 丛林小径：斜向的短墙织成网，视野被切得很
## 每个拐角都可能贴脸遭遇，炮塔回转速度在这里比机动性更值钱
func _layout_jungle(rng: RandomNumberGenerator, stage: int) -> void:
	var lines := 10 + mini(stage, 6)
	for i in lines:
		var x := rng.randi_range(2, GRID_W / 2)
		var y := rng.randi_range(5, GRID_H - 8)
		var len_ := rng.randi_range(3, 6)
		# 斜向推进5° 的短墙既挡视线又不会围成封闭的死
		var sx := 1 if rng.randf() < 0.5 else -1
		for k in len_:
			_put_mirror(x + k * sx, y + k, BRICK if rng.randf() < 0.88 else STEEL)
	# 两三处林间水
	for i in 2 + mini(stage / 3, 2):
		var wx := rng.randi_range(3, GRID_W / 2 - 2)
		var wy := rng.randi_range(7, GRID_H - 9)
		for dy in 2:
			for dx in 2:
				_put_mirror(wx + dx, wy + dy, WATER)


## 夜战市区：规整的方形街区 + 窄街。能见度最低，
## 炮口焰与曳光弹成了判断敌人位置的主要线索
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


## 沙漠风暴：几道斜向沙垄（砖）+ 零星岩堆（钢 一小片绿洲## 沙垄长而薄，正面绕不过去就得吃亏，于是机动与绕后比对推更有价
func _layout_desert(rng: RandomNumberGenerator, stage: int) -> void:
	for i in 5 + mini(stage / 2, 4):
		var x := rng.randi_range(2, GRID_W / 2)
		var y := rng.randi_range(5, GRID_H - 10)
		var len_ := rng.randi_range(4, 8)
		var sx := 1 if rng.randf() < 0.5 else -1
		# 两格进一格的缓坡：沙垄斜着铺开，又不会围成封闭的死
		for k in len_:
			_put_mirror(x + k * sx, y + int(k / 2), BRICK)
	for i in 3 + mini(stage / 2, 3):
		var rx := rng.randi_range(2, GRID_W / 2 - 1)
		var ry := rng.randi_range(6, GRID_H - 9)
		for dy in 2:
			_put_mirror(rx, ry + dy, STEEL)
	_water_bands(rng, 1, 1)


## 铁路枢纽：几排纵向车厢（钢）夹着站台（砖），每排留错开的穿越口
## 再用几道横向检修道把过长的纵向通路切断
func _layout_rail(rng: RandomNumberGenerator, stage: int) -> void:
	for cx in [2, 6, 10]:
		var y := 4 + rng.randi_range(0, 2)
		while y < GRID_H - 7:
			var seg := rng.randi_range(5, 7)
			var platform: bool = rng.randf() < 0.55
			for i in seg:
				_put_mirror(cx, y + i, STEEL)
				if platform and rng.randf() < 0.6:
					# 站台贴在车厢**内侧**（cx-1）。贴外侧会占掉 x=11 这条
					# 正中路：玩家出生就在 11 列，正前方整条主通道被站台砖墙
					# 封死，开局只能斜着绕——探针在这张图上连一条 45 m 视线
					# 都找不到，量不出敌车亮度。
					_put_mirror(cx - 1, y + i, BRICK)
			y += seg + rng.randi_range(2, 3)
	for i in 3 + mini(stage / 2, 3):
		var x := rng.randi_range(2, GRID_W / 2 - 2)
		var y := rng.randi_range(7, GRID_H - 8)
		for dx in rng.randi_range(2, 4):
			_put_mirror(x + dx, y, BRICK)


## 成团掩体：细长块比方块更适合当掩体，所3x3 以上的块会被压成一
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


## 横向水带：切断通路、留出对射走
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
	# 基地外圈一圈砖
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


## 保证每个敌人出生点都能走到基地，否则沿直线凿开砖墙## 迷宫与要塞这类高密度地形要凿的格子更多，所以上限给得宽
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


## 路障格规划：把一部分空格变成低矮的工事障碍（沙袋 / 拒马 / 残骸 / 管材
## 
## 散布物过去只是贴在地上的 MultiMesh 装饰——看着是障碍物，开过去却毫无反应，
## 这正穿越障碍最直接的来源。现在凡是看着实心的散布物都独占一
## 进入网格、带真实碰撞体，于是寻路、视线、炮弹与车体碰撞四者说的是同一件事##
## 路障挡车但不挡弹、不挡视线，所以它不是墙的替代品，而是一种新的战术地形：
## 能隔着沙袋对射，却不能直接压过
## 
## 每放一格都立刻重验"所有出生点仍能走到基地"，放不下就原样退回
## 于是"路障把地图堵在构造上不可能发生，不需要事后调参去规避
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
		# 贴着已有掩体长出来的路障才像战场工事；孤零零堵在空地中央既难看又容易挡路
		# 所以只给它四分之一的概
		var touching := false
		for d in DIRS:
			if blocks_tank(x + d.x, y + d.y):
				touching = true
				break
		if not touching and rng.randf() > 0.25:
			continue

		var mx := GRID_W - 1 - x
		var mirrored: bool = mx != x and grid[y][mx] == EMPTY and _scatterable(mx, y)
		# 四成路障改成长条沙袋墙：同样挡车不挡，但它是连续的一段实体视觉，
		# 比一堆油桶更像掩体，也给"半高掩体"这条路补上一种可读的语言
		var kind := SAND if rng.randf() < 0.4 else BARRICADE
		grid[y][x] = kind
		if mirrored:
			grid[y][mx] = kind
		if _spawns_connected():
			placed += 2 if mirrored else 1
			continue
		grid[y][x] = EMPTY
		if mirrored:
			grid[y][mx] = EMPTY


## 单格宽通道对车体是"转向死区"##
## 车体要自由回转，需要一块短边不小于**车身对角*的空地：游隼 3.59 × 5.25 m## 对角6.34 m，而一格只4 m。实测（tools/TurnProbe.tscn）单格走廊里按住 A
## 两秒，车体只转了 9.9° 就再也转不动——玩家读到的就是"左右转向不灵## Boss.70 m 宽）更直接：在单格走廊里整条车身压进砖墙 0.35 m
## （tools/_BossCorridorProbe.gd），这就有时候还能看到坦克穿##
## 所以地形生成完之后把所有单格通道拓宽一格（4 m 8 m）。规则是"只做加法"##   * BRICK / BARRICADE 优先；STEEL（永久工事）也允许清，但排在砖块之后##     原来的规则是"钢墙一律不，可单格通道的两侧经常正好是两排钢墙
## 铁轨（terrain 11）每张图22~28 格单格通道，两*全是** STEEL##     于是最需要拓宽的那三张图一格都没拓宽过（tools/_LaneDiag.tscn）；
##   * WATER（水网）与基地格、基地外围加固墙（_fortify_cells）不动：
##     水是"能打不能的地形，抽干它等于改规则##   * 至少要有**连续 2 *可以拓宽才动
## 格是几何下限而不是随手取的：
##     车体55.6° 时外接盒最大，恰好等于对角6.34 m；只拓宽一格形成的##     4 × 8 m 的壁龛，仍然容不下车身回转，连续两格扩出 8 × 8 m 才够##   * 只剩一格长的孤门洞"退而求其次：清掉一侧的一格，局部净宽变8 m##     这种格子容不下原地掉头，Boss.70 m 宽）能平直通过
## 而它原来在这里是0.345 m 的车身压进两侧砖
## 
## 于是"通道再窄也能开过去、但只能在个别地方调变成"整条通道都能调头"
func _widen_lanes() -> void:
	# 多趟：每趟拓宽之后，新露出来的墙面上又可能出现新的单格段
	# 实测（tools/_LaneDiag.tscn）第 4 趟之后剩余单格段不再随趟数下
	for _pass in 4:
		if not _widen_lanes_once():
			return


func _widen_lanes_once() -> bool:
	var changed := false
	# 先纵向（左右夹住）再横向（上下夹住）。同一条通道整段朝同一侧拓宽，
	# 结果是一条干净8 m 通道，而不是锯齿状的壁
	for vertical in [true, false]:
		for run in _single_lane_runs(vertical):
			if _widen_lane_run(run, vertical):
				changed = true
	return changed


## 被两侧实心格夹住、只剩一格宽的空地，按列（纵向通道）或按行（横向通道## 切成连续段。段长可以只1 格：那是一个门洞，Boss 的通行宽度同样重要
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


## 该空格是不是只有一格宽（沿 vertical 方向延伸、被左右/上下两堵墙夹住）## 寻路的宽度惩罚（_sync_astar）也用它，所以两条判据说的是同一件事
func _narrow_at(x: int, y: int, vertical: bool) -> bool:
	if blocks_tank(x, y):
		return false
	if vertical:
		return blocks_tank(x - 1, y) and blocks_tank(x + 1, y)
	return blocks_tank(x, y - 1) and blocks_tank(x, y + 1)


## 把一段单格通道朝一侧拓
func _widen_lane_run(run: Array, vertical: bool) -> bool:
	var step := Vector2i(1, 0) if vertical else Vector2i(0, 1)

	# 1) 路障造成的收窄：先拆路障。它本来就是"可绕的临时工，拆它比拆两
	# 永久砖墙便宜，也不会改变地图的结
	var barricades: Array = []
	for c in run:
		for s in [1, -1]:
			var t: Vector2i = c + step * s
			if cell(t.x, t.y) == BARRICADE or cell(t.x, t.y) == SAND:
				if _widenable(t.x, t.y):
					barricades.append(t)
	if barricades.size() > 0:
		for t in barricades:
			grid[t.y][t.x] = EMPTY
		return true

	# 2) 地形造成的收窄：两侧各找最长的一段可拓宽格（2 格起），同长时取拆钢更少
	# 那一侧。能拆砖就不动钢——钢墙是"永久工事"，只有绕不开时才牺牲
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

	# 3) 只剩一格长的孤立门洞：两侧凑不出连续两格，退而清一
	# 局部净宽因此从 4 m 变成 8 m——容不下原地掉头，但 4.70 m 宽的 Boss
	# 平直通过（原来在这里它左右各压进砖墙 0.345 m）。只对长1 的段动手
	# 长段这样处理会在一面墙上打出一排门
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


## 一段可拓宽格的"代价"：拆钢墙比拆砖墙贵。清一色砖= 0
func _stretch_cost(stretch: Array) -> int:
	var n := 0
	for t in stretch:
		if cell(t.x, t.y) != BRICK:
			n += 1
	return n


## 这一格能不能为了拓宽通道而清
## 
## BRICK / BARRICADE 是首选，STEEL 也允许（调用方会优先选砖块那一侧，## `_stretch_cost`）。水、基地格、基地加固圈、基地正面进出口两侧一律不
func _widenable(x: int, y: int) -> bool:
	if x < 1 or y < 1 or x >= GRID_W - 1 or y >= GRID_H - 1:
		return false
	var c := cell(x, y)
	if c != BRICK and c != BARRICADE and c != SAND and c != STEEL:
		return false
	var v := Vector2i(x, y)
	if v in _fortify_cells or v in BASE_CELLS:
		return false
	# 基地正前方的进出口两侧是基地的防御工事，拆掉等于把基地敞开
	if y >= 20 and x >= 9 and x <= 15:
		return false
	return true


## 从基地门口泛洪，检查所有敌人出生点与玩家出生格是否仍然可达## 直接grid 而不astar，所以可以在地图构造中途随意调
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


## 把一格的"实心"同步到两张网格上##
## 宽体网格额外*单格宽通道**判成实心，判据与地形生成用的 `_narrow_at()` 是同一## 函数，于生成时认为这里转不开"寻路时认为这里过不去"说的是同一件事
func _apply_solid(c: Vector2i) -> void:
	var solid := blocks_tank(c.x, c.y)
	astar.set_point_solid(c, solid)
	astar_wide.set_point_solid(c, solid or _narrow_any(c.x, c.y))


func _narrow_any(x: int, y: int) -> bool:
	return _narrow_at(x, y, true) or _narrow_at(x, y, false)


## 拆掉 / 重建一格之后，刷新它自己与周围一圈的两张网格##
## 单格宽是一*邻居关系**：拆掉一格墙会让邻格变成"，所以只刷自## 是不够的——不刷邻格的话，宽体网格会一直认为那条路走不通，Boss 就永远绕
func _refresh_solid_around(c: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			if astar.is_in_boundsv(n):
				_apply_solid(n)


## 返回世界坐标路径点（不含起点）。目标格不可通行时退回到最近的可通行邻格##
## `wide` true 时走宽体网格：单格宽通道视为不可通行。Boss 这类车体比一格还## 的目标不能进那种通道（进去就0.345 m 的穿墙，astar_wide 的注释）## 宽网格上无路可走时退回普通网格——绕不过去的时候，能挤过去也比起步就不动好
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


## 网格步进的视线判定：水面与空地不挡视
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

## 把一个半径为 radius 的圆推出所有实心格，返回修正后的坐
## 
## move_and_slide() 只保这一步不会穿过去"：高速、刁钻入射角、被另一辆坦克挤
## 或者刚好站在砖墙被炸开又被加固还原的格子上，都可能让车体啃进掩体里## 网格本身是规则的，所以这里直接做一次圆-矩形解交当硬约束
## 于是"穿过障碍在几何上不再可能发生，而不是靠调参去降低概
## 
## from 是上一个确认安全的位置。两件事靠它##   1. 圆心已经完全陷进某格时，来的方向"退出去。原来取最浅的那条边，
##      在单格厚的墙里会把车从墙的另一侧弹出来——那本身就是一次穿
## 2. 实在解不开时（被夹在两堵墙之间）直接回退from，宁可顿一下也不穿
func depenetrate(pos: Vector3, radius: float, from := Vector3.INF) -> Vector3:
	var out := pos
	var half := CELL * 0.5
	var has_from: bool = from.x < INF
	for _pass in 3:
		# 分方向累计最深的推出量，最后一次性合
		# 关键在于对向的两面墙（单格宽走廊）会在这里相互抵消，车体停在走廊中线上；
		# 原来逐格依次写回坐标，两边的墙会轮流把车推来推去，表现就是走廊里卡死
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

	# 三趟还没解开：被夹在两面墙中间。退回上一个安全点，顿一帧远好过穿墙
	if has_from and blocks_tank(to_cell(out).x, to_cell(out).y):
		return from
	return out


## 圆心已经落在实心格内部时的脱出方
## 有来向就朝来向退（沿主轴退出最近的那条边），否则退最浅的一条边"
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
## 并要求至少两面通路，免得补给落在死胡同里拿不到##
## avoid / min_dist 是硬性回避（基地与玩家当前位置）## soft_avoid / soft_dist 用于彼此拉开距离（已落地的其它补给）
## 分成两档是因离基地远"别和另一个箱子挤在一要求的距离差了一个量
## 找不到合适位置返Vector3.INF
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


# ---------------- 破坏与伤----------------

## 单点命中一格。返"brick" / "brick_break" / "steel" / "base" / "none"
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


## HE 溅射：清除半径内的砖
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
	_schedule_runs()
	_schedule_joints()


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
	_schedule_runs()
	_schedule_joints()


# ---------------- 几何体构----------------

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
	_build_shoreline()
	_schedule_runs()
	_schedule_joints()


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
		SAND:
			h = SAND_H
			mat_key = "sandbag"

	var body := StaticBody3D.new()
	body.position = cell_center(c.x, c.y) + Vector3(0, h * 0.5, 0)
	# 水面、路障与沙袋墙只挡坦克不挡炮弹：放到3 层，炮弹射线不检测该
	body.collision_layer = 4 if (t == WATER or t == BARRICADE or t == SAND) else 1
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
	elif t == SAND:
		# 沙袋墙只1.1 m 高，但碰撞体给到 1.8 m：坦克是"浮空运动"
		# 没有踏台阶的自由度，宁可让碰撞体略高，也不要在贴墙时出现骑上去的抖动
		box.size.y = 1.8
		shape.position = Vector3(0, 0.9 - h * 0.5, 0)
	shape.shape = box
	body.add_child(shape)

	# 最外圈只保留碰撞，可见网格交给 _build_boundary_cliff 的连续土
	if c.x == 0 or c.y == 0 or c.x == GRID_W - 1 or c.y == GRID_H - 1:
		_blocks_root.add_child(body)
		_blocks[c] = body
		return

	if t == BARRICADE:
		# 路障的外观由 _scatter_props 的重型散布物提供（沙/ 拒马 / 残骸 / 管材），
		# 所以这里通常不挂任何网格。只有模型整体缺失时才退回一块矮土垒
		# 免得出现"看不见却撞得的隐形墙
		if Assets.mesh_of("prop_sandbags") == null:
			_attach_block_primitive(body, t, h, mat_key)
	elif t == SAND:
		_attach_sandbag_cover(body, c, h)
	elif t == WATER:
		_attach_water_tile(body, h)
	# 砖墙与钢墙：碰撞体按格保留，但**不在这里挂网格**。
	# 可见部分由 `_refresh_runs` 把同一行里连续的同类墙格合成一个墙段，
	# 否则每格各自收边，一面 12 m 的墙会读成三块积木。

	_blocks_root.add_child(body)
	_blocks[c] = body


## 按行构建连续墙段。
##
## 为什么不能一格一个网格：砖墙模型是"一整格"做的，两端各收半块砖并带端面，
## 单格摆放时相邻两块之间必然出现一条结构缝，只能靠壁柱去遮。而真实的墙是
## 连续的砌体——缝在砖缝里，不在每 4 m 处。
##
## 做法是把瓦片横向按格子名义宽度精确铺满，同一行相邻同状态墙格用一个
## MultiMesh 段沿 +X 平铺。碰撞体仍然一格一个（破坏、血量、寻路全按格），
## 这里只是可见层。
func _schedule_runs() -> void:
	_runs_dirty = true
	if _runs_pending:
		return
	_runs_pending = true
	if is_inside_tree():
		call_deferred("_refresh_runs")
	else:
		_refresh_runs()


## 墙格的可见状态。0 = 不是墙；1 = 完好砖墙；2 = 受损砖墙；3 = 钢墙。
## 只有状态相同的相邻格才会合并——受损格必须单独成段，否则一整段墙会
## 跟着一格血量一起"换脸"。
func _run_state(c: Vector2i) -> int:
	if c.x <= 0 or c.y <= 0 or c.x >= GRID_W - 1 or c.y >= GRID_H - 1:
		return 0
	var t := cell(c.x, c.y)
	if t == BRICK:
		return 2 if float(brick_hp.get(c, BRICK_HP)) < float(BRICK_HP) * 0.5 else 1
	if t == STEEL:
		return 3
	return 0


## 横向优先、纵向补位：先合并沿 X 的连续段，再合并没被横向段吃掉的、沿 Z 的
## 连续段，剩下的单格各自成段。十字/丁字路口于是自然分裂成几段，段与段在
## 交界处正好相接——那正是壁柱该出现的位置。
func _refresh_runs() -> void:
	_runs_pending = false
	if not _runs_dirty:
		return
	_runs_dirty = false
	if _runs_root != null:
		# 先摘下来再 free：queue_free 的节点要到帧末才真正消失，
		# 期间它会占着 "WallRuns" 这个名字，新节点只能叫 WallRuns2
		remove_child(_runs_root)
		_runs_root.queue_free()
	_runs_root = Node3D.new()
	_runs_root.name = "WallRuns"
	add_child(_runs_root)
	_built_state.clear()
	var done: Dictionary = {}

	for y in range(1, GRID_H - 1):
		var x := 1
		while x < GRID_W - 1:
			var st := _run_state(Vector2i(x, y))
			if st == 0:
				x += 1
				continue
			var x0 := x
			while x + 1 < GRID_W - 1 and _run_state(Vector2i(x + 1, y)) == st:
				x += 1
			if x > x0:
				_build_run(x0, x, y, st, true)
				for i in range(x0, x + 1):
					done[Vector2i(i, y)] = true
			x += 1

	for x in range(1, GRID_W - 1):
		var y := 1
		while y < GRID_H - 1:
			var st := _run_state(Vector2i(x, y))
			if st == 0 or done.has(Vector2i(x, y)):
				y += 1
				continue
			var y0 := y
			while y + 1 < GRID_H - 1 and not done.has(Vector2i(x, y + 1)) \
					and _run_state(Vector2i(x, y + 1)) == st:
				y += 1
			if y > y0:
				_build_run(y0, y, x, st, false)
				for i in range(y0, y + 1):
					done[Vector2i(x, i)] = true
			y += 1

	for y in range(1, GRID_H - 1):
		for x in range(1, GRID_W - 1):
			var st := _run_state(Vector2i(x, y))
			if st == 0 or done.has(Vector2i(x, y)):
				continue
			_build_run(x, x, y, st, true)
			done[Vector2i(x, y)] = true


## 段的两端格号 i0..i1（含），fixed 是另一轴。along_x 为 true 时格子是
## (i, fixed)，否则是 (fixed, i)。
func _build_run(i0: int, i1: int, fixed: int, st: int, along_x: bool) -> void:
	var n := i1 - i0 + 1
	var anchor := Vector2i(i0, fixed) if along_x else Vector2i(fixed, i0)
	var key: String
	if st == 1:
		key = Assets.BRICK_VARIANTS[_cell_hash(anchor, 17) % Assets.BRICK_VARIANTS.size()]
	elif st == 2:
		key = Assets.BRICK_DAMAGED[_cell_hash(anchor, 17) % Assets.BRICK_DAMAGED.size()]
	else:
		key = Assets.STEEL_VARIANTS[_cell_hash(anchor, 19) % Assets.STEEL_VARIANTS.size()]
	# 同一段墙只用一个变体：段内换变体等于把墙又切回格子
	var tile := Assets.block_tile(key, CELL)
	if tile == null:
		return
	for i in range(i0, i1 + 1):
		_built_state[Vector2i(i, fixed) if along_x else Vector2i(fixed, i)] = st

	var h := STEEL_H if st == 3 else BRICK_H
	var node := Node3D.new()
	node.name = "Run_%s_%d_%d" % ["X" if along_x else "Z", fixed, i0]
	node.set_meta("st", st)
	node.set_meta("along_x", along_x)
	node.set_meta("fixed", fixed)
	node.set_meta("i0", i0)
	node.set_meta("i1", i1)
	# 段心：两端格心的中点。瓦片沿局部 +X 平铺，所以只允许 0° / 180° 翻转；
	# 纵向段整体再转 -90°，让局部 +X 指向世界 +Z
	var ca := cell_center(i0, fixed) if along_x else cell_center(fixed, i0)
	var cb := cell_center(i1, fixed) if along_x else cell_center(fixed, i1)
	node.position = (ca + cb) * 0.5
	var yaw := 0.0 if along_x else -PI * 0.5
	if (_cell_hash(anchor, 31) % 2) != 0:
		yaw += PI
	node.rotation.y = yaw

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = tile
	mm.instance_count = n
	for i in n:
		var tr := Transform3D.IDENTITY
		# 按 CELL 整格平铺：模型中砖缝的周期与格子宽度一致，
		# 相邻瓦片首尾的半块砖正好补成一整块
		tr.origin = Vector3((float(i) - float(n - 1) * 0.5) * CELL, 0.0, 0.0)
		mm.set_instance_transform(i, tr)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Visual"
	mmi.multimesh = mm
	# 瓦片原点是底面中心，碰撞体原点在几何中心，差 h/2
	mmi.position = Vector3(0, -h * 0.5, 0)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.add_child(mmi)
	_runs_root.add_child(node)


## 水面：不再用 `water_surface.glb` 的整格模型。
##
## 那个模型是给"孤立一格水"做的：四边各压一条 0.3 m 的石岸，防止水面与地面
## 接缝露怯。可一张图里的水是连成片的，于是每 4 m 就多出一道石岸——俯视时
## 整片水被切成一张亮格子（雪原的冰面尤其明显）。
##
## 这里直接铺一张 4×4 m 的细分平面，靠 shader 做深度渐变、折射与岸边泡沫；
## 相邻水格的边严格对齐，既没有缝也没有重叠。顶点细分用于波浪位移。
func _attach_water_tile(body: StaticBody3D, h: float) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Visual"
	var pm := PlaneMesh.new()
	pm.size = Vector2(CELL, CELL)
	pm.subdivide_width = 3
	pm.subdivide_depth = 3
	mi.mesh = pm
	# 碰撞体原点在格中心，网格原点在底面；水面抬到 WATER_H
	mi.position = Vector3(0, WATER_H - h * 0.5, 0)
	mi.material_override = _water_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)


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


## 沙袋墙：三排错缝的袋子，一整格一draw call##
## 半高掩体的价值在挡住车体、露出炮：碰撞在 layer 3（挡车不挡弹），
## 视觉必须是一段连续的实体，而不是几件零散道具——玩家要能一眼读## "这里能蹲、后面能开。袋子的位置用格哈希做稳定抖动，换关不会
func _attach_sandbag_cover(body: StaticBody3D, c: Vector2i, h: float) -> void:
	var bag := SphereMesh.new()
	bag.radius = 0.34
	bag.height = 0.62
	bag.radial_segments = 8
	bag.rings = 4

	var rows := 3
	var per_row := 7
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = bag
	mm.instance_count = rows * per_row * 2
	var idx := 0
	for r in rows:
		for i in per_row:
			for zr in 2:
				var hashv := _cell_hash(c, 41 + r * 13 + i * 3 + zr)
				var x := (i - (per_row - 1) * 0.5) * 0.52 + (0.26 if r % 2 else 0.0)
				var z := (float(zr) - 0.5) * 0.40
				var y := 0.17 + r * 0.31
				var tr := Transform3D.IDENTITY
				tr = tr.rotated(Vector3.UP, deg_to_rad(float(hashv % 26) - 13.0))
				tr = tr.scaled(Vector3(1.22, 0.52, 0.94))
				tr.origin = Vector3(
					x + float(hashv % 7) * 0.008,
					y + float(hashv % 5) * 0.006,
					z + float(hashv % 3) * 0.01)
				mm.set_instance_transform(idx, tr)
				idx += 1

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Visual"
	mmi.multimesh = mm
	mmi.material_override = _mats["sandbag"]
	mmi.position = Vector3(0, -h * 0.5, 0)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(mmi)


## 砖墙受损反馈：状态跨过 50% 时把这一段墙换成"缺口 + 裸露钢筋"的受损态。
##
## 合并成墙段之后，受损格不能只换自己那一块——它会把整段墙的连续性打断，
## 所以这里只标记状态变化，由 `_refresh_runs` 重新切分墙段：受损格单独成段，
## 两侧完好的部分各自保持连续。碰撞体与血量逻辑完全不动。
func _shade_brick(c: Vector2i, ratio: float) -> void:
	if not _blocks.has(c):
		return
	var now := _run_state(c)
	if now == int(_built_state.get(c, 0)):
		return
	_schedule_runs()
	# 受损态第一次换上时崩一把碎砖，让"墙快塌了"这件事有听觉与视觉反馈
	if now == 2:
		var body: Node3D = _blocks[c]
		Fx.debris(_blocks_root, body.global_position, Vector3.UP, Color(0.5, 0.26, 0.17))


## 格坐稳定伪随机数。用乘法散列而非 randi()，保证同一张地图可复现
func _cell_hash(c: Vector2i, salt: int) -> int:
	var v := (c.x * 73856093) ^ (c.y * 19349663) ^ (salt * 83492791)
	return absi(v) % 1000003


func _build_ground() -> void:
	# 地面要比最外圈钢墙多铺出一大圈：近处山脊在 84 m，地面半98 m 才盖得住
	# 山脚，否则俯视时能看地面78 m 就断的硬边与一条天空缝
	var size := Vector2(GRID_W * CELL + 100.0, GRID_H * CELL + 100.0)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	# 细分48x48：顶点多了才吃得住后面的光照SDFGI，单片四边形会出大块色阶
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


## 土路：从基地通向三条进攻线的一段低对比色带##
## 十二张图原来都是"均匀噪声地面 + 随机掩体"，玩家没有路径引导，
## 每张图也没有记忆点。土路不改碰撞、不挡视线，只做两件事：
##   1. 把出生点与基地连起来，告诉玩主攻方向在哪"##   2. 用两道车辙与大尺度明度变化打破地面的均匀
## 路径直接复用 A* 网格，所以它一定绕开砖墙与水面，不会画进掩体
func _build_roads() -> void:
	if _roads_root != null:
		_roads_root.queue_free()
	_roads_root = Node3D.new()
	_roads_root.name = "Roads"
	add_child(_roads_root)
	_road_cells.clear()

	var base := base_position()
	var targets := [
		cell_center(GRID_W / 2, 2),
		cell_center(2, 2),
		cell_center(GRID_W - 3, 2),
	]
	var mat := _road_material()
	var lift := 0.0
	for target in targets:
		var pts := find_path(base, target)
		if pts.size() < 2:
			continue
		pts.push_front(base)
		_add_road_ribbon(pts, mat, 0.016 + lift)
		lift += 0.002


func _add_road_ribbon(points: Array, mat: ShaderMaterial, y: float) -> void:
	var n := points.size()
	if n < 2:
		return
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var run := 0.0
	for i in n:
		var p: Vector3 = points[i]
		_road_cells[to_cell(p)] = true
		var dir: Vector3
		if i == 0:
			dir = (points[1] as Vector3) - p
		elif i == n - 1:
			dir = p - (points[i - 1] as Vector3)
		else:
			dir = (points[i + 1] as Vector3) - (points[i - 1] as Vector3)
		dir.y = 0.0
		if dir.length() < 0.01:
			dir = Vector3.FORWARD
		dir = dir.normalized()
		var side := Vector3(-dir.z, 0.0, dir.x)
		var w := 1.42 + sin(run * 0.17) * 0.10
		verts.append(Vector3(p.x, y, p.z) - side * w)
		verts.append(Vector3(p.x, y, p.z) + side * w)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		uvs.append(Vector2(0.0, run * 0.25))
		uvs.append(Vector2(1.0, run * 0.25))
		if i > 0:
			var a := (i - 1) * 2
			idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
		if i < n - 1:
			run += p.distance_to(points[i + 1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_roads_root.add_child(mi)


func _road_material() -> ShaderMaterial:
	if _road_mat != null:
		return _road_mat
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 road_col : source_color = vec4(0.30, 0.26, 0.20, 1.0);
uniform vec4 rut_col : source_color = vec4(0.15, 0.13, 0.10, 1.0);
uniform vec4 edge_col : source_color = vec4(0.25, 0.23, 0.18, 1.0);
uniform float opacity = 0.90;

varying vec3 wpos;
varying vec2 ruv;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.11 + vec2(9.0, 3.0);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ruv = UV;
}

void fragment() {
	float n = fbm(ruv * vec2(3.4, 24.0) + wpos.xz * 0.11);
	// 两道车辙：压暗并略微去饱和，位置固定在路宽的 31% / 69%
	float rut = exp(-pow((ruv.x - 0.31) / 0.075, 2.0))
		+ exp(-pow((ruv.x - 0.69) / 0.075, 2.0));
	vec3 col = mix(road_col.rgb, rut_col.rgb, clamp(rut * 0.80, 0.0, 1.0));
	col = mix(col, edge_col.rgb, smoothstep(0.0, 0.24, abs(ruv.x - 0.5) * 2.0));
	col *= 0.80 + 0.40 * n;
	float edge = smoothstep(0.0, 0.15, ruv.x) * smoothstep(0.0, 0.15, 1.0 - ruv.x);
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.12;
	ALPHA = edge * opacity * (0.72 + 0.28 * n);
}
"""
	_road_mat = ShaderMaterial.new()
	_road_mat.shader = sh
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	var high: Color = t["soil_high"]
	var low: Color = t["soil_low"]
	_road_mat.set_shader_parameter("road_col", high.lerp(Color(0.42, 0.36, 0.27), 0.35))
	_road_mat.set_shader_parameter("rut_col", low.darkened(0.18))
	_road_mat.set_shader_parameter("edge_col", high.lerp(low, 0.45))
	return _road_mat


## 远景剪影：两圈低模山树线，把"地面平面切到天空"的硬边吃
## 
## 原来 96x96 的场地外只有一156 m 的地面，再往外直接是天空## 相机压低之后，地平线会像一张纸的边缘。这里放两圈朝内的单面山脊：
## 内圈低而近（树土坡），外圈高而远（山脊），颜色按地形雾色更新## 于是雾能把它们和天空接起来，而不用真的做地形起伏
func _build_berms() -> void:
	# 场地外一圈低矮土
	# m 的方盒子外面原来是一整片平到地平线的地面
	# 从任何角度看都是"盒子放在一张纸；土丘把墙外的空白填成起伏的郊野
	# 同时挡住地面与山脊之间的接缝。纯视觉，不带碰撞，不进入寻路网
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150 + terrain * 97
	var xfs: Array[Transform3D] = []
	for i in 46:
		var a := TAU * float(i) / 46.0 + rng.randf_range(-0.035, 0.035)
		var radius := rng.randf_range(74.0, 88.0)
		var sx := rng.randf_range(9.0, 18.0)
		var sy := rng.randf_range(2.0, 4.2)
		var sz := rng.randf_range(8.0, 15.0)
		var tr := Transform3D.IDENTITY
		tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
		tr = tr.scaled(Vector3(sx, sy, sz))
		tr.origin = Vector3(cos(a) * radius, -sy * 0.55, sin(a) * radius)
		xfs.append(tr)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "OuterBerms"
	mmi.multimesh = mm
	_berm_mat = StandardMaterial3D.new()
	_berm_mat.roughness = 1.0
	_berm_mat.metallic = 0.0
	mmi.material_override = _berm_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_berm = mmi
	_berm_tint()


func _berm_tint() -> void:
	if _berm_mat == null:
		return
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	_berm_mat.albedo_color = (t["soil_high"] as Color).darkened(0.42).lerp(
			t["fog"] as Color, 0.28)


## 最外圈不再
## 4 m 一块的钢墙##
## 边界碰撞仍由最外圈钢墙格负责（挡车、挡弹、寻路都不变），但这些格不生成可见网格：
## 按格拼出来的 4.4 m 方块从第三人称视角看就是一圈灰色围墙，把战场读成一个盒子
## 这里换成一圈土坡：坡脚压在最外圈钢墙的内侧面
## 4 m），坡顶 3.4~5.8 m
## 坡顶插拒马。纯视觉、无碰撞、不进寻路
## 
## 坡体由互相重叠的**实心扁球**堆成，而不是一条自定义坡面。薄壳坡面靠 winding 算法线，
## 四条边里总有两条边的顶点顺序是反的：一半坡面背光发黑、另一半过曝，看上去像一
## 白黑相间的碎片；即使显式给法线，单面坡也会自己接住自己的阴影，在坡腰压出大片黑斑
## 球体没有这两个问题——法线由几何保证，自遮挡也就是正常的体积阴影
func _build_boundary_cliff() -> void:
	if _cliff != null:
		_cliff.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = 6301
	var rim: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	var trees: Array[Transform3D] = []
	_cliff_shade.clear()

	# 断面
	# 距最外圈墙内侧面的水平距
	# 高度)
	# 内坡陡、坡肩圆、外坡缓。坡脚压到地面以下，坡体就不会与地面留一条硬边
	var profile := CLIFF_PROFILE
	var pcount := profile.size()
	var steps := 88

	# 四条边的顶点先全部算出来：法线要用相邻点做有限差分
	# 端点各多
	# 3%，让四条边在角上互相叠住——用球堆时角部露出的
	# 黑色竖缝，就
	# 两排物体没有真正接上"造成的
	var rows: Array = []
	var normals: Array = []
	for side in 4:
		var side_rows: Array = []
		var side_normals: Array = []
		var tangent := (_cliff_point(side, 1.0, 0.0, 0.0)
				- _cliff_point(side, 0.0, 0.0, 0.0)).normalized()
		var outward := -_cliff_inward(side)
		for i in steps + 1:
			var u := lerpf(-0.03, 1.03, float(i) / float(steps))
			var base := _cliff_point(side, u, 0.0, 0.0)
			# 低频起伏：整条坡
			# 2~3 个缓包，而不是一排等高的
			var wob := _cliff_swell(side, u)
			var row: Array = []
			for j in pcount:
				var out: float = profile[j].x
				var y: float = profile[j].y
				# 只有坡体跟着起伏；坡脚始终埋在地下，接缝才不会开
				if y > 0.0:
					y *= 1.0 + wob * 0.22
					out += wob * 0.60
				var p := base + outward * out + Vector3(0, y, 0)
				# 沿边方向再给一点细碎抖动，坡面不会像挤出体一样光
				p += tangent * sin(u * 41.0 + j * 1.7 + side) * 0.05
				# 中频侵蚀：竖向的冲沟与土棱。只按高度比例沿坡面法向平移
				# 坡脚保持贴地；这样近看是一条被雨水犁过的土坡，
				# 而不是一块光滑的棕色挤出体
				var erode := sin(u * 53.0 + j * 2.1 + side * 1.3) * 0.16 \
						+ sin(u * 17.0 + j * 0.9 + side) * 0.26
				p += outward * erode * clampf(y / 2.0, 0.0, 1.0)
				row.append(p)
			side_rows.append(row)
		for i in steps + 1:
			var nrow: Array = []
			for j in pcount:
				var i0 := maxi(i - 1, 0)
				var i1 := mini(i + 1, steps)
				var j0 := maxi(j - 1, 0)
				var j1 := mini(j + 1, pcount - 1)
				var du: Vector3 = side_rows[i1][j] - side_rows[i0][j]
				var dv: Vector3 = side_rows[i][j1] - side_rows[i][j0]
				var n := du.cross(dv).normalized()
				if n.y < 0.0:
					n = -n
				nrow.append(n)
			side_normals.append(nrow)
		rows.append(side_rows)
		normals.append(side_normals)

		# 坡顶拒马：每 3 段放一组，坡线因此
		# 防线"的读法
		# 高度必须跟着坡面的起伏走：坡肩的 y 会被 _cliff_swell 缩放
		# 固定
		# 5.2 m 会让一半拒马悬在坡顶上方
		for k in 26:
			if k % 3 != 1:
				continue
			var u := (float(k) + 0.5) / 26.0
			var base := _cliff_point(side, u, 0.0, 0.0)
			var rim_out := -_cliff_inward(side)
			var rs := rng.randf_range(0.55, 0.80)
			var tr := Transform3D.IDENTITY
			tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			tr = tr.scaled(Vector3.ONE * rs)
			tr.origin = base + rim_out * 5.4 \
					+ Vector3(0, _cliff_surface_y(side, u, 5.4) - 0.12 * rs, 0)
			rim.append(tr)

		# 坡面散石与枯树：连续坡面解决了黑缝，但一条光滑的土墙同样不可信
		# 石头压在坡面上（不悬空），枯树只放在坡肩，远看才是一条有人活动痕迹的边界
		# 
		# 两个约束
		# * 只铺**内坡**（out <= 5.0）。原先铺
		# 9.8 m，外坡上的石头从场地里看
		#     正好高出坡顶剪影，背后又没有坡面可依，于是整条坡顶上方是一
		# "悬空漂浮的砖块带"（tools/shots/BOUNDARY_north.png）
		# * 高度
		# _cliff_surface_y() 算，而不是查名义断面：坡面顶点被
		#     _cliff_swell 同时平移
		# out、缩放了 y，差量最大约 1.1 m
		for k in 30:
			var u := (float(k) + rng.randf()) / 30.0
			# 越靠近坡脚石头越密：重力把碎屑留在下面，坡肩只留零星几块
			# 均匀铺满会让整条坡变
			# 一条等间距的碎石带"，反而看出是程序撒的
			var out := lerpf(0.9, 4.6, pow(rng.randf(), 1.55))
			var base := _cliff_point(side, u, 0.0, 0.0)
			var outward2 := -_cliff_inward(side)
			var y := _cliff_surface_y(side, u, out)
			# 0.85~1.6：prop_rubble 单个石块的直径只
			# 0.16~0.5 m
			# 缩到 0.5 以下就只剩几颗黑点，反而比不撒更像渲染错误
			var rs2 := rng.randf_range(0.85, 1.6)
			var rtr := Transform3D.IDENTITY
			rtr = rtr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			rtr = rtr.scaled(Vector3.ONE * rs2)
			# 压进坡面：石头是嵌在土里的，不是摆在上面
			rtr.origin = base + outward2 * out + Vector3(0, y - 0.10 - 0.06 * rs2, 0)
			rocks.append(rtr)
			if k % 7 == 3:
				var ttr := Transform3D.IDENTITY
				ttr = ttr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
				ttr = ttr.scaled(Vector3.ONE * rng.randf_range(0.7, 1.05))
				var tout := minf(out + 0.8, 5.0)
				ttr.origin = base + outward2 * tout \
						+ Vector3(0, _cliff_surface_y(side, u, tout) - 0.10, 0)
				trees.append(ttr)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base_index := 0
	for side in 4:
		var side_rows: Array = rows[side]
		var side_normals: Array = normals[side]
		for i in steps + 1:
			for j in pcount:
				var p: Vector3 = side_rows[i][j]
				# 明度扰动只负责打
				# 一整片同色土坡"，色调交
				# _cliff_tint
				var hsh := fposmod(sin(p.x * 12.9898 + p.z * 78.233) * 43758.5453, 1.0)
				var sh := 0.80 + 0.26 * hsh
				# 坡脚压暗、坡肩微亮：即使没有 AO，坡体也有上下层
				sh *= 0.72 + 0.28 * clampf((p.y + 0.6) / 5.8, 0.0, 1.0)
				st.set_color(Color(sh, sh * 0.985, sh * 0.94))
				st.set_normal(side_normals[i][j])
				st.add_vertex(p)
		for i in steps:
			for j in pcount - 1:
				var a := base_index + i * pcount + j
				var b := a + pcount
				# Godot 的正面是顺时针绕序。这里必须让内坡朝向场地
				# 否则看到的是背面：双面材质会把法线翻过来，整条坡瞬间变黑
				st.add_index(a)
				st.add_index(a + 1)
				st.add_index(b)
				st.add_index(b)
				st.add_index(a + 1)
				st.add_index(b + 1)
		base_index += (steps + 1) * pcount

	var mesh := st.commit()
	_cliff_mat = _cliff_material()
	_cliff = MeshInstance3D.new()
	_cliff.name = "BoundaryRidge"
	_cliff.mesh = mesh
	_cliff.material_override = _cliff_mat
	_cliff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_cliff)
	_cliff_rim(rim)
	_cliff_scatter(rocks, "prop_rubble", "BoundaryRocks")
	_cliff_scatter(trees, "prop_deadtree", "BoundaryTrees")
	_cliff_tint()

## 边界的四条边共用一套参数：u 沿边、out 向外、y 为高
func _cliff_point(side: int, u: float, out: float, y: float) -> Vector3:
	var inner := (GRID_W - 2) * CELL * 0.5
	var span := inner + out
	var a := -span + u * span * 2.0
	match side:
		0:
			return Vector3(a, y, -span)
		1:
			return Vector3(-a, y, span)
		2:
			return Vector3(-span, y, -a)
		_:
			return Vector3(span, y, a)


## 每条
## 指向场地内侧"的水平方
func _cliff_inward(side: int) -> Vector3:
	match side:
		0:
			return Vector3.BACK      # 北边外侧。-Z
		1:
			return Vector3.FORWARD
		2:
			return Vector3.RIGHT
		_:
			return Vector3.LEFT


## 边界坡线的低频起伏。整条坡
## 2~3 个缓包，高低差约 ±17%
## 坡面顶点与散落物必须用同一个函数，否则石头会浮在坡面上
static func _cliff_swell(side: int, u: float) -> float:
	return sin(u * TAU * 1.7 + side * 1.9) * 0.55 \
			+ sin(u * TAU * 4.3 + side * 0.7) * 0.22


## 坡面
## (side, u, out) 处的实际高度
## 
## `_build_boundary_cliff` 生成顶点时，坡肩以上的点会按 `_cliff_swell` 缩放高度
## 并把 out 一起平移；散落的石
## 枯树如果直接
## CLIFF_PROFILE 的名义值，
## 就会浮在坡面之上（tools/shots/BOUNDARY_north.png 里那
## 悬空砖块
## ）
## 这里按同一套变形后的断面做线性插值，散落物才能真的压在土里
static func _cliff_surface_y(side: int, u: float, out: float) -> float:
	var wob := _cliff_swell(side, u)
	var prev_o := 0.0
	var prev_y := 0.0
	for i in CLIFF_PROFILE.size():
		var p: Vector2 = CLIFF_PROFILE[i]
		var o := p.x
		var y := p.y
		if y > 0.0:
			o += wob * 0.60
			y *= 1.0 + wob * 0.22
		if i == 0:
			prev_o = o
			prev_y = y
			continue
		if out >= prev_o and out <= o:
			var f := (out - prev_o) / maxf(o - prev_o, 0.001)
			return lerpf(prev_y, y, f)
		prev_o = o
		prev_y = y
	return prev_y


func _cliff_rim(list: Array[Transform3D]) -> void:
	if list.is_empty():
		return
	var mesh := Assets.mesh_of("prop_hedgehog")
	if mesh == null:
		mesh = Assets.mesh_of("prop_wire")
	if mesh == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "BoundaryRim"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


static func _cliff_material() -> ShaderMaterial:
	if _cliff_shader == null:
		_cliff_shader = Shader.new()
		_cliff_shader.code = _CLIFF_SHADER
	var m := ShaderMaterial.new()
	m.shader = _cliff_shader
	return m


static var _cliff_shader: Shader

## 边界土坡的材质
## 
## 只有顶点色的连续坡面会读成一
## 棕色的墙"
## 9 个分段乘 9 个断面点
## 顶多给出几米一档的明暗，近看仍然是光滑挤出体。这里把土壤 / 碎石 /
## 三层按世界坐标混起来，再用解析高度场补一层法线，坡面才有颗粒与受光变化
const _CLIFF_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 soil_col : source_color = vec3(0.20, 0.17, 0.13);
uniform vec3 rock_col : source_color = vec3(0.30, 0.29, 0.26);
uniform vec3 grass_col : source_color = vec3(0.12, 0.17, 0.09);

varying vec3 wpos;
varying vec3 wnrm;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(13.0, 7.0);
		a *= 0.5;
	}
	return v;
}
float height_at(vec2 p) {
	return fbm(p * 0.50) * 0.62 + fbm(p * 2.10) * 0.26 + vnoise(p * 7.5) * 0.12;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	float macro = fbm(wpos.xz * 0.055 + 3.0);
	float mid = fbm(wpos.xz * 0.42 + 11.0);
	float fine = vnoise(wpos.xz * 3.2 + 5.0);

	vec3 col = soil_col * (0.82 + 0.30 * macro) * (0.90 + 0.20 * mid);
	col *= 0.88 + 0.24 * fine;

	// 沉积层理：随高度起伏的水平条带。没有它，近看就是一整块光滑的土色挤出体
	// （BOUNDARY_north.png 里那
	// 棕色
	// ）
	float band = fbm(vec2((wpos.x + wpos.z) * 0.42, wpos.y * 1.9 + mid * 0.8));
	float strata = smoothstep(0.40, 0.72, band);
	col = mix(col, rock_col * (0.70 + 0.36 * fine), strata * 0.34);

	// 竖向冲刷沟：雨水沿坡面往下拉出的暗条，只在立面出现，坡顶不受影响
	float vert = 1.0 - smoothstep(0.35, 0.85, wnrm.y);
	float gully = smoothstep(0.56, 0.86,
			fbm(vec2((wpos.x + wpos.z) * 1.9, wpos.y * 0.16)));
	col *= 1.0 - gully * 0.26 * vert;

	// 陡坡露石：坡肩与坡腰的碎石比坡顶多，坡脚被土埋住
	float steep = 1.0 - smoothstep(0.32, 0.82, wnrm.y);
	float rocky = smoothstep(0.48, 0.76, mid) * steep;
	col = mix(col, rock_col * (0.80 + 0.38 * fine), rocky * 0.62);

	// 坡脚湿而暗，坡肩干而亮，远看才不是一整条同色的带
	col *= mix(0.58, 1.04, smoothstep(-0.4, 2.6, wpos.y));

	// 草只长在缓坡的上半段
	float grass = smoothstep(0.56, 0.80, fbm(wpos.xz * 0.85 + 19.0))
			* smoothstep(1.4, 4.4, wpos.y) * smoothstep(0.15, 0.65, wnrm.y);
	col = mix(col, grass_col, grass * 0.40);

	// 解析法线：坡面上
	// 1~3 m 尺度的起伏，受光不再是一条平滑渐变
	// SurfaceTool 生成的坡面没
	// UV/tangent，NORMAL_MAP 不会生效
	// 所以直接扰动世界法线再变换到视图空间
	float e = 0.28;
	float h0 = height_at(wpos.xz);
	float hx = height_at(wpos.xz + vec2(e, 0.0));
	float hz = height_at(wpos.xz + vec2(0.0, e));
	vec2 grad = vec2(hx - h0, hz - h0) / e;
	vec3 nw = normalize(wnrm + vec3(-grad.x, 0.0, -grad.y) * 0.34);
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);

	ALBEDO = col * COLOR.rgb;
	ROUGHNESS = 0.98;
	METALLIC = 0.0;
	SPECULAR = 0.12;
}
"""


func _cliff_scatter(list: Array[Transform3D], key: String, nname: String) -> void:
	if list.is_empty():
		return
	var mesh := Assets.mesh_of(key)
	if mesh == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nname
	mmi.multimesh = mm
	# 石头要投影：坡面上的散石如果只有背光面、没有落在坡面上的接触阴影，
	# 远看就是一条悬空的黑点带。一
	# MultiMesh 只有一个阴
	# pass，代价可接受
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mmi)


func _cliff_tint() -> void:
	if _cliff_mat == null:
		return
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	# 土色压暗再掺一点雾色：坡面比地面暗一档，才不会和地面抢注意力
	var soil: Color = (t["soil_high"] as Color).darkened(0.22).lerp(
			t["fog"] as Color, 0.12)
	_cliff_mat.set_shader_parameter("soil_col", soil)
	_cliff_mat.set_shader_parameter("rock_col",
			soil.lerp(Color(0.40, 0.39, 0.36), 0.55))
	_cliff_mat.set_shader_parameter("grass_col",
			(t["soil_low"] as Color).lerp(Color(0.10, 0.16, 0.07), 0.65))


func _build_far_ridge() -> void:
	_ridge_mat_near = StandardMaterial3D.new()
	_ridge_mat_near.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ridge_mat_near.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ridge_mat_near.albedo_color = Color(0.20, 0.22, 0.20)
	_ridge_mat_near.disable_receive_shadows = true
	_ridge_mat_far = StandardMaterial3D.new()
	_ridge_mat_far.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ridge_mat_far.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ridge_mat_far.albedo_color = Color(0.30, 0.32, 0.34)
	_ridge_mat_far.disable_receive_shadows = true

	_ridge_near = _make_ridge_ring(84.0, 5.0, 15.0, 91, _ridge_mat_near)
	_ridge_near.name = "FarRidgeNear"
	_ridge_near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ridge_near)
	_ridge_far = _make_ridge_ring(150.0, 18.0, 42.0, 77, _ridge_mat_far)
	_ridge_far.name = "FarRidgeFar"
	_ridge_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ridge_far)


func _make_ridge_ring(radius: float, min_h: float, max_h: float, seed: int,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var segs := 112
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# 山口：三处缺口，位置与宽度由 seed 固定。
	#
	# 一整圈等宽起伏的山脊，视线扫过去只能读出一个东西——"这是一个圆环"。
	# 真实的远景地平线是有方向的：河谷切开一道口子，被炮火炸塌一个垭口，
	# 山脊在某处退到低地后面。缺口不必大，只要有几处高度掉到近地，
	# 视线就能穿过去看到后一圈山（或天空），边界感立刻消失。
	var gaps: Array = []
	for g in 3:
		gaps.append(Vector2(rng.randf_range(0.0, TAU), rng.randf_range(0.12, 0.26)))
	var hs: Array[float] = []
	for i in segs:
		var a := TAU * i / segs
		var base := 0.5 + 0.5 * sin(a * 3.0 + 0.7) * sin(a * 5.0 + 2.1)
		# 两个尺度的随机峰：低频决定整段山脉的走向，高频给单个山头的高度。
		# 原来的 peak 只有 0.55 一档，整圈高度过于均匀，像一道剪影纸带。
		var peak := rng.randf() * 0.62 + rng.randf() * 0.25
		var slow := 0.5 + 0.5 * sin(a * 2.0 + 1.3)
		var h := lerpf(min_h, max_h,
				clampf(base * 0.42 + peak * 0.62 + slow * 0.18, 0.0, 1.0))
		var cut := 0.0
		for gp in gaps:
			var d := absf(wrapf(a - float(gp.x), -PI, PI))
			var w := float(gp.y)
			cut = maxf(cut, smoothstep(w, w * 0.30, d))
		# 缺口里山脊降到近地高度：不推到半径外，否则地面平面（半宽 98 m）
		# 与山脊之间会露出一条真实的天缝
		hs.append(lerpf(h, min_h * 0.16, cut))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var c0 := Vector3(cos(a0), 0.0, sin(a0))
		var c1 := Vector3(cos(a1), 0.0, sin(a1))
		var h0: float = hs[i]
		var h1: float = hs[(i + 1) % segs]
		var b0 := c0 * radius + Vector3(0, -6.0, 0)
		var t0 := c0 * radius + Vector3(0, h0, 0)
		var t1 := c1 * radius + Vector3(0, h1, 0)
		var b1 := c1 * radius + Vector3(0, -6.0, 0)
		var start := verts.size()
		verts.append_array([b0, t0, t1, b1])
		var inward := -c0
		norms.append_array([inward, inward, inward, inward])
		indices.append_array([start, start + 1, start + 2, start, start + 2, start + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	return mi


## 地面材质：世界空间的三平面程序化混合，而不是一张平铺噪声贴
## 
## 原来的做法是 512 噪声 × uv1_scale 14 + 一detail4 次重复在 4 m 一格的
## 尺度上肉眼可数，而且 roughness 恒为 1、没有法线，受光下就是一块哑光纸
## 现在按世界坐标混/ 碎石 / 三套颜色，再用大尺度明度14 次重## 彻底打散；法线由同一套高度场解析求出，地面的碎石与车辙边缘终于有受光变化##
## 三平面投影对水平地面不是必须的（只有 XZ 一个面），但它让同一shader
## 以后可以直接套到斜坡与土堆上，不必为地形起伏再写一套材
static func _soil_material(idx: int) -> Material:
	if _soil_cache.has(idx):
		return _soil_cache[idx]
	var t: Dictionary = TERRAINS[clampi(idx, 0, TERRAINS.size() - 1)]
	if _soil_shader == null:
		_soil_shader = Shader.new()
		_soil_shader.code = _SOIL_SHADER
	var m := ShaderMaterial.new()
	m.shader = _soil_shader
	var low: Color = t["soil_low"]
	var high: Color = t["soil_high"]
	m.set_shader_parameter("soil_low", low)
	m.set_shader_parameter("soil_high", high)
	m.set_shader_parameter("gravel_col", high.lerp(Color(0.52, 0.50, 0.46), 0.55))
	m.set_shader_parameter("grass_col", low.lerp(Color(0.15, 0.24, 0.10), 0.72))
	var nm := String(t["name"])
	var grass := 0.18
	match nm:
		"丛林小径":
			grass = 0.62
		"河谷渡口":
			grass = 0.40
		"夜战市区":
			grass = 0.06
		"工业港区":
			grass = 0.04
		"雪原哨所", "熔岩弹坑":
			grass = 0.0
		"沙漠风暴":
			grass = 0.02
	m.set_shader_parameter("grass_amount", grass)
	m.set_shader_parameter("large_scale", 1.0)
	_soil_cache[idx] = m
	return m


static var _soil_shader: Shader

const _SOIL_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 soil_low : source_color = vec3(0.2);
uniform vec3 soil_high : source_color = vec3(0.4);
uniform vec3 gravel_col : source_color = vec3(0.5);
uniform vec3 grass_col : source_color = vec3(0.18, 0.24, 0.12);
uniform float grass_amount = 0.18;
uniform float large_scale = 1.0;

varying vec3 wpos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.0, 9.0);
		a *= 0.5;
	}
	return v;
}

float height_at(vec2 p) {
	return fbm(p * 0.42) * 0.62 + fbm(p * 1.85) * 0.28 + vnoise(p * 7.0) * 0.10;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 低频层：60~120 m 尺度。
	//
	// 在这之前，地面上的所有信息都落在同一个频率带里（0.055 的 fbm 周期已经
	// 只有 18 m），整张图读起来是"均匀噪声"——每一处都差不多脏、差不多干。
	// 这一层给地面一个大结构：这片是干土、那片是返潮的洼地，草与碎石才有落点。
	// 乘出来的明度均值基本不变（干处 +10%、湿处 -14%），
	// 所以不会动 tools/vis_probe.gd 的 sceneLum 判据。
	float basin = fbm(wpos.xz * 0.0115 + 31.0);
	float wet = smoothstep(0.40, 0.74, basin);
	// 再低一档的"区域"：只做轻微的色相偏移，让相邻两张图不像同一块地
	float region = fbm(wpos.xz * 0.0062 + 71.0);

	// 土底色：大尺度变化，覆盖几十米，直接打散贴图重复
	// 混色区间收到 0.55 的振幅：原来 1.25 的振幅让土色在两种明度之间整片翻转，
	// 俯视时地面上会出现一块块边界分明的浅深褐斑，读起来像迷彩布而不是土
	float macro = fbm(wpos.xz * 0.055);
	vec3 dirt = mix(soil_low, soil_high, clamp(macro * 0.55 + 0.28, 0.0, 1.0));
	// 返潮的土偏冷偏绿，干燥的土偏暖：湿度不只是明度，也是色相
	dirt = mix(dirt, dirt * vec3(0.86, 0.94, 0.82), wet * 0.55);
	dirt = mix(dirt, dirt * vec3(1.05, 1.00, 0.93), (1.0 - wet) * region * 0.6);

	// 碎石：中频噪声成片出现。占比从 0.55 收到 0.30，且阈值更高，
	// 于是它是"一层撒在土上的碎石"，而不是第二种底色
	float gstone = smoothstep(0.58, 0.82, fbm(wpos.xz * 1.9 + 4.7));
	vec3 col = mix(dirt, gravel_col, gstone * 0.30);

	// 草：低频斑块 + 高频边缘，且只在有植被的地形上出。
	// 湿处更容易长草——草斑跟着湿度走，而不是独立撒点。
	float gpatch = smoothstep(0.56, 0.74, fbm(wpos.xz * 0.9 + 11.3));
	col = mix(col, grass_col, clamp(gpatch * (0.55 + 0.75 * wet) * grass_amount * 1.1,
			0.0, 0.70));

	// 大尺度明度：12 张图共用同一套噪声，但每张图的底色不
	// 振幅 0.18：只负责让远处地面有呼吸感，不参
	// 这是不是同一块地"的判
	col *= 0.90 + 0.18 * fbm(wpos.xz * 0.16 + 2.0);
	// 干湿分离：湿处压暗（水吸光），干处略提亮，均值近似不变
	col *= mix(1.10, 0.86, wet);

	// 近处颗粒
	// m 尺度的潮斑与砂砾。没有这一层，10 m 内的地面
	// 只剩一张低频渐变，坦克开过去像在色块上滑行
	// 振幅
	// 0.20 收到 0.14：原来的高频项在斜视角下是一层随镜头闪烁
	// 沙砾噪点（截图里整片地面像撒了糖霜），压低之后仍然是"
	// ，但不再抢细节
	float fine = fbm(wpos.xz * 2.6 + 17.0);
	col *= 0.92 + 0.14 * fine;
	// 碎石粒：只留很浅的一层
	// 1/m 的频率在 1~2 m 处已经接近像素频率，
	// 再叠 0.22 的权重就会变成一片白点，而不
	// 地上有碎
	float grit = smoothstep(0.78, 0.95, vnoise(wpos.xz * 7.0));
	col = mix(col, gravel_col * 1.05, grit * 0.14);

	// 由高度场解析出法线：地面不再是完美平面，碎石与坑洼有受光变化
	// 
	// 远处必须把法线抹平。程序化法线没有 mipmap，斜视角下每像素采到的是
	// 不同相位的噪声——远景地面会"沸腾"（镜头一动就满地闪烁），
	// SSAO 又会把这些高频起伏读成一摊摊黑斑。detail
	// 14~48 m 之间
	//1 收到 0，近处保留碎石起伏，远处交回平坦地面
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float detail = 1.0 - smoothstep(14.0, 48.0, dist);
	float e = 0.18;
	float h0 = height_at(wpos.xz);
	float hx = height_at(wpos.xz + vec2(e, 0.0));
	float hz = height_at(wpos.xz + vec2(0.0, e));
	vec2 grad = vec2(hx - h0, hz - h0) / e;
	float bump = mix(0.05, 0.22, detail);
	NORMAL_MAP = vec3(0.5 + grad.x * bump, 0.5 + grad.y * bump, 1.0);
	NORMAL_MAP_DEPTH = mix(0.10, 1.15, detail);

	ALBEDO = col;
	// 湿泥的反光明显强于干土：粗糙度随湿度下降，SPECULAR 略抬，
	// 于是"这片是湿的"在斜射阳光下也读得出来，而不只是颜色深一点
	ROUGHNESS = mix(0.96, 0.78, wet * 0.7) - gstone * 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.18 + wet * 0.14;
}
"""


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


## 水面：法线扰+ 深度边缘渐变 + 屏幕空间折射## 玩法规则不变——碰撞体仍是"挡车不挡，这里只换视
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

// 水位与法线都必须按**世界坐标**取样：水面是一格一块的独立网格，
// 如果 vertex() 用模型坐标算波高，相邻两块在共享边上的位移就对不上，
// 每 4 m 会翘起一道台阶；fragment() 里的 VERTEX 又是视空间坐标，
// 混进世界坐标只会得到随镜头漂移的花纹。两条都曾让水面读成"蓝格子"。
varying vec3 wpos;

void vertex() {
	float t = TIME * wave_speed;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += wave(wpos.xz, t) * wave_height;
}

void fragment() {
	float t = TIME * wave_speed;
	vec2 p = wpos.xz;
	// 以波形的梯度当法线扰动，省掉一张法线贴
	float e = 0.35;
	float hx = wave(p + vec2(e, 0.0), t) - wave(p - vec2(e, 0.0), t);
	float hz = wave(p + vec2(0.0, e), t) - wave(p - vec2(0.0, e), t);
	NORMAL_MAP = normalize(vec3(-hx * 0.5 + 0.5, -hz * 0.5 + 0.5, 1.0));
	NORMAL_MAP_DEPTH = 1.6;

	// 用深度缓冲算水下厚度：岸边浅、中间深，于是有自然的边缘渐
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

## 散布物分三类，差别在看着能不能开过去"必须和实际一致：
##
##   HEAVY  沙袋 / 拒马 / 残骸 / 管材 / 弹药/ 油桶——看着实心##          只摆BARRICADE 格里，每格塞几件填满，背后有真实碰撞
## TALL   路灯 / 枯树——立起来的高杆，视觉上绝不可能开过去##          所以同样只摆在 BARRICADE 格里，当工事里立着的那根杆
## FLAT   碎石 / 铁丝网——压过去才合理的东西，随便撒在空地上，不带碰
## 
## 过去路灯与枯树走的是 FLAT 这条路：一5 米的水泥灯杆撒在空地上却没有碰撞体，
## 开过去直接穿过去——这就是"穿越障碍里最刺眼的一
const PROP_HEAVY: Array[String] = [
	"prop_sandbags", "prop_hedgehog", "prop_wreck", "prop_pipe",
	"prop_ammocrate", "prop_barrel",
]
const PROP_TALL: Array[String] = ["prop_lamp", "prop_deadtree"]
const PROP_FLAT: Array[String] = ["prop_rubble", "prop_wire"]

## 路障格的三种"故事：同一片街区里的工事不再随机堆料，
## 而是一处被击毁的车队、一个哨卡、一个维修点。相邻路障格会分到同一组，
## 三四个格子连起来就读得出"这里发生过什，而不是均匀撒点
const PROP_THEMES := [
	["prop_wreck", "prop_barrel", "prop_pipe", "prop_ammocrate"],       # 被击毁的车队
	["prop_sandbags", "prop_hedgehog", "prop_wire", "prop_ammocrate"],  # 哨卡
	["prop_ammocrate", "prop_barrel", "prop_pipe", "prop_sandbags"],    # 维修
]

## 各散布物的水平足迹半径（米）。只有它决定能不能塞进一格：
## 残骸本体就有 3x4 米，照原样再放大 1.3 倍会整整越过格子边界## 伸进旁边那个没有碰撞体的空格里去——于看着是障碍物，开过去毫无反应"## 格半宽是 2.0 米，所以摆放时一律按 (2.0 - 偏移 - 0.1) / 足迹 去压缩尺
const PROP_FOOT := {
	"prop_sandbags": 1.7, "prop_hedgehog": 1.2, "prop_wreck": 2.6, "prop_pipe": 1.6,
	"prop_ammocrate": 0.7, "prop_barrel": 0.4, "prop_lamp": 1.0, "prop_deadtree": 0.9,
}


## 在空格里散布道具与碎石。每种道具一MultiMeshInstance3D，于是无论摆了多少个## 每种也只是一draw call。出生走廊、玩家活动区与基地通道一律避开，不影响玩法
func _scatter_props(stage: int) -> void:
	if _props_root != null:
		_props_root.queue_free()
	_props_root = Node3D.new()
	_props_root.name = "Props"
	add_child(_props_root)

	var rng := RandomNumberGenerator.new()
	rng.seed = 918273 + stage * 104729 + terrain * 7919

	var density: float = TERRAINS[terrain]["props"]
	var slots: Dictionary = {}       # 模型-> Array[Transform3D]
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
		# 重型道具（沙袋、拒马、残骸、管材）开阴影：它们有体积
		# 贴在地上不投影就会像贴纸；碎石、铁丝网仍是轻量平面道具，继续关
		# 这两类本来就只出现在路障格，实例数有限，阴影 pass 可以承受
		mmi.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			if (key in PROP_HEAVY or key in PROP_TALL or key == "prop_rubble")
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		_props_root.add_child(mmi)

	# 夜战：给路灯真的挂一盏灯。prop_lamp 原来只是个不发光的水泥杆
	# 夜里站在路灯下和站在空地上没有区别；一圈暖色光池是"夜间"
	# "暗蓝色白最直接的分界。数量封顶，避免几十盏点光把帧率吃掉
	if terrain_name() == "夜战市区" and slots.has("prop_lamp"):
		_add_lamp_lights(slots["prop_lamp"])

	_build_junk(rng)
	_build_dust()


## 墙根生活痕迹"：轮胎堆、木板堆、倒伏电线
## 
## 这三种都不带碰撞、都很矮（坦克压过去合理），所以只贴着墙根摆，
## 不占用可通行区域。它们解决的道具只有十种、且都像贴纸"的问题：
## 一个维修点会同时出现油桶、木箱、轮胎和木板，而不再只有同几件模型
func _build_junk(rng: RandomNumberGenerator) -> void:
	var tires: Array[Transform3D] = []
	var planks: Array[Transform3D] = []
	var poles: Array[Transform3D] = []
	var guns: Array[Transform3D] = []
	var crates: Array[Transform3D] = []
	var cans: Array[Transform3D] = []
	var wheels: Array[Transform3D] = []
	var shells: Array[Transform3D] = []
	var camo: Array[Transform3D] = []
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

	for y in range(2, GRID_H - 2):
		for x in range(2, GRID_W - 2):
			if cell(x, y) != EMPTY or not _scatterable(x, y):
				continue
			if _road_cells.has(Vector2i(x, y)):
				continue
			# 只贴墙根：找一格相邻的实体
			var walls: Array[Vector2i] = []
			for d in dirs:
				var t := cell(x + d.x, y + d.y)
				if t == BRICK or t == STEEL:
					walls.append(d)
			if walls.is_empty() or rng.randf() > 0.16:
				continue
			var d: Vector2i = walls[rng.randi() % walls.size()]
			var dir := Vector3(d.x, 0.0, d.y)
			var side := Vector3(-dir.z, 0.0, dir.x)
			var center := cell_center(x, y)
			var pos := center + dir * rng.randf_range(1.15, 1.55) \
					+ side * rng.randf_range(-0.95, 0.95)
			var tr := Transform3D.IDENTITY
			tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			tr = tr.scaled(Vector3.ONE * rng.randf_range(0.9, 1.15))
			tr.origin = pos
			# 大部分是生活杂物，少量是一处被放弃的反坦克炮位
			# 它比轮胎堆更
			# 这里打过
			# 的叙事重量，但数量必须少，否则满街都是炮
			# 墙根
			# 生活痕迹"按概率分到九类。前四类是旧的一批，
			# 后五类补的是"维修
			# / 哨卡"里常见、但原来完全没有的物件：
			# 弹药箱堆、油
			# 水桶、备用负重轮、弹壳堆、卷起的伪装网
			# 它们都很矮（不超
			# 0.8 m），坦克压过去合理，所以不带碰
			var roll := rng.randf()
			if roll < 0.060:
				guns.append(tr)
			elif roll < 0.240:
				tires.append(tr)
			elif roll < 0.400:
				planks.append(tr)
			elif roll < 0.540:
				poles.append(tr)
			elif roll < 0.700:
				crates.append(tr)
			elif roll < 0.810:
				cans.append(tr)
			elif roll < 0.890:
				wheels.append(tr)
			elif roll < 0.950:
				shells.append(tr)
			else:
				camo.append(tr)

	_junk_mm(guns, _abandoned_gun_mesh(), Color(0.150, 0.140, 0.125), 0.86, 0.35, "JunkGuns")
	_junk_mm(tires, _tire_stack_mesh(), Color(0.055, 0.055, 0.06), 0.92, 0.0, "JunkTires")
	_junk_mm(planks, _plank_pile_mesh(), Color(0.27, 0.20, 0.12), 0.95, 0.0, "JunkPlanks")
	_junk_mm(poles, _fallen_pole_mesh(), Color(0.235, 0.205, 0.155), 0.94, 0.0, "JunkPoles")
	_junk_mm(crates, _crate_stack_mesh(), Color(0.185, 0.140, 0.092), 0.93, 0.0, "JunkCrates")
	_junk_mm(cans, _jerrycan_cluster_mesh(), Color(0.165, 0.180, 0.115), 0.86, 0.10, "JunkCans")
	_junk_mm(wheels, _spare_wheel_pair_mesh(), Color(0.065, 0.064, 0.062), 0.92, 0.05, "JunkWheels")
	_junk_mm(shells, _shell_pile_mesh(), Color(0.400, 0.300, 0.115), 0.48, 0.65, "JunkShells")
	_junk_mm(camo, _camo_roll_mesh(), Color(0.175, 0.190, 0.120), 0.97, 0.0, "JunkCamo")


## 被放弃的反坦克炮：炮盾、炮管、两只轮子、一条大
## 
## 尺寸压到 3.2 m 以内，贴着墙根摆；没有碰撞，坦克碾过去是合理的
func _abandoned_gun_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ph := StandardMaterial3D.new()

	var shield := BoxMesh.new()
	shield.size = Vector3(1.45, 1.05, 0.085)
	shield.material = ph
	st.append_from(shield, 0, Transform3D(Basis.IDENTITY, Vector3(0, 0.95, -0.25)))

	var barrel := CylinderMesh.new()
	barrel.top_radius = 0.052
	barrel.bottom_radius = 0.075
	barrel.height = 2.15
	barrel.radial_segments = 10
	barrel.material = ph
	# 炮管
	# -Z 伸出去：圆柱默认
	# Y，绕 X
	# 90°
	st.append_from(barrel, 0, Transform3D(
			Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 1.18, -1.15)))

	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.40
	wheel.bottom_radius = 0.40
	wheel.height = 0.12
	wheel.radial_segments = 12
	wheel.material = ph
	for sx in [-0.82, 0.82]:
		st.append_from(wheel, 0, Transform3D(
				Basis(Vector3.BACK, PI * 0.5), Vector3(sx, 0.40, 0.10)))

	var trail := BoxMesh.new()
	trail.size = Vector3(0.11, 0.09, 1.45)
	trail.material = ph
	for sx in [-0.26, 0.26]:
		var tr := Transform3D(Basis(Vector3.UP, sx * 0.14), Vector3(sx, 0.25, 0.95))
		st.append_from(trail, 0, tr)

	st.generate_normals()
	return st.commit() as ArrayMesh


func _junk_mm(list: Array[Transform3D], mesh: Mesh, col: Color, rough: float,
		metal: float, nname: String) -> void:
	if list.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = rough
	mat.metallic = metal
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nname
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_props_root.add_child(mmi)


## 轮胎堆：三只轮胎错开叠起来，远看是黑色的一摞，近看有圆的轮
func _tire_stack_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tire := TorusMesh.new()
	tire.inner_radius = 0.21
	tire.outer_radius = 0.43
	tire.rings = 12
	tire.ring_segments = 6
	# SurfaceTool 会把源网格的材质一起带过来；图元不挂材质时 append_from 会刷
	# "Parameter material is null"。这里给一个占位材质，最终外观仍MultiMesh
	# material_override 决定
	tire.material = StandardMaterial3D.new()
	for k in 3:
		var tr := Transform3D.IDENTITY.rotated(Vector3.UP, float(k) * 0.55)
		tr.origin = Vector3(0.0, 0.115 + k * 0.245, 0.0)
		st.append_from(tire, 0, tr)
	st.generate_normals()
	return st.commit() as ArrayMesh


## 木板堆：四块长度不一的板子叠放，带一点自然错
func _plank_pile_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 4:
		var plank := BoxMesh.new()
		plank.size = Vector3(1.75 - k * 0.07, 0.055, 0.24)
		plank.material = StandardMaterial3D.new()
		var tr := Transform3D.IDENTITY.rotated(Vector3.UP, -0.22 + float(k) * 0.11)
		tr.origin = Vector3(0.0, 0.035 + k * 0.058, float(k) * 0.03)
		st.append_from(plank, 0, tr)
	st.generate_normals()
	return st.commit() as ArrayMesh


## 倒伏的电线杆：一根躺在地上的圆杆 + 一端的横担，最这里以前通电"
func _fallen_pole_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.075
	pole.bottom_radius = 0.095
	pole.height = 2.9
	pole.radial_segments = 10
	pole.material = StandardMaterial3D.new()
	var lay := Transform3D.IDENTITY.rotated(Vector3.RIGHT, PI * 0.5)
	lay.origin = Vector3(0.0, 0.095, 0.0)
	st.append_from(pole, 0, lay)
	var arm := BoxMesh.new()
	arm.size = Vector3(1.05, 0.075, 0.085)
	arm.material = StandardMaterial3D.new()
	var at := Transform3D.IDENTITY
	at.origin = Vector3(0.0, 0.13, 1.05)
	st.append_from(arm, 0, at)
	for sx in [-1.0, 1.0]:
		var ins := CylinderMesh.new()
		ins.top_radius = 0.045
		ins.bottom_radius = 0.055
		ins.height = 0.12
		ins.radial_segments = 6
		ins.material = StandardMaterial3D.new()
		var itr := Transform3D.IDENTITY
		itr.origin = Vector3(sx * 0.36, 0.20, 1.05)
		st.append_from(ins, 0, itr)
	st.generate_normals()
	return st.commit() as ArrayMesh


## 弹药箱堆：两只并排、一只压在上面。尺寸压
## 1.4 m 以内
## 贴墙根摆时不会探进旁边的通行
func _crate_stack_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ph := StandardMaterial3D.new()
	var specs := [
		[Vector3(0.76, 0.54, 0.64), Vector3(-0.38, 0.27, 0.0), 0.04],
		[Vector3(0.76, 0.54, 0.64), Vector3(0.38, 0.27, 0.03), -0.06],
		[Vector3(0.68, 0.46, 0.58), Vector3(0.02, 0.77, 0.01), 0.17],
	]
	for spec in specs:
		var size: Vector3 = spec[0]
		var pos: Vector3 = spec[1]
		var yaw: float = spec[2]
		var box := BoxMesh.new()
		box.size = size
		box.material = ph
		var tr := Transform3D(Basis(Vector3.UP, yaw), pos)
		st.append_from(box, 0, tr)
		# 箱盖压条：两道深色横条，远看能读
		# 木箱"而不是一块土黄色方块
		for sx in [-1.0, 1.0]:
			var strip := BoxMesh.new()
			strip.size = Vector3(0.80, 0.045, 0.04)
			strip.material = ph
			var off: Vector3 = pos + Vector3(0.0, 0.12 * sx, -0.325)
			st.append_from(strip, 0, Transform3D(Basis(Vector3.UP, yaw), off))
	st.generate_normals()
	return st.commit() as ArrayMesh


## 油桶/水桶堆：三只立着、一只倒着，带提手与桶盖
## 原来只有一只孤零零
## prop_barrel，墙根缺
## 这里有人在补
## 的成组读
func _jerrycan_cluster_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ph := StandardMaterial3D.new()
	for i in 3:
		var can := BoxMesh.new()
		can.size = Vector3(0.24, 0.38, 0.17)
		can.material = ph
		var pos := Vector3(-0.28 + i * 0.28, 0.19, 0.0)
		st.append_from(can, 0, Transform3D(Basis(Vector3.UP, 0.08 * i), pos))
		var cap := CylinderMesh.new()
		cap.top_radius = 0.035
		cap.bottom_radius = 0.035
		cap.height = 0.05
		cap.radial_segments = 8
		cap.material = ph
		st.append_from(cap, 0, Transform3D(Basis.IDENTITY, pos + Vector3(0.06, 0.205, 0.0)))
		var handle := BoxMesh.new()
		handle.size = Vector3(0.12, 0.03, 0.05)
		handle.material = ph
		st.append_from(handle, 0, Transform3D(Basis.IDENTITY, pos + Vector3(0, 0.19, 0.0)))
	var lying := BoxMesh.new()
	lying.size = Vector3(0.24, 0.38, 0.17)
	lying.material = ph
	var ltr := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.02, 0.12, 0.46))
	st.append_from(lying, 0, ltr)
	st.generate_normals()
	return st.commit() as ArrayMesh


## 备用负重轮：两只立着靠在墙根，中间露出轮毂
## 行走部分在车上被侧裙挡住，墙根这两只反而成了最直观
## 坦克修过"的证
func _spare_wheel_pair_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ph := StandardMaterial3D.new()
	for sx in [-0.30, 0.30]:
		var tire := TorusMesh.new()
		tire.inner_radius = 0.17
		tire.outer_radius = 0.40
		tire.rings = 12
		tire.ring_segments = 7
		tire.material = ph
		var tr := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(sx, 0.41, 0.0))
		tr = tr.rotated(Vector3.FORWARD, sx * 0.22)
		st.append_from(tire, 0, tr)
		var hub := CylinderMesh.new()
		hub.top_radius = 0.14
		hub.bottom_radius = 0.14
		hub.height = 0.16
		hub.radial_segments = 12
		hub.material = ph
		st.append_from(hub, 0, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(sx, 0.41, 0.0)))
	st.generate_normals()
	return st.commit() as ArrayMesh


## 弹壳堆：十几枚黄铜弹壳散在墙根，有躺有叠
## 很小的道具，但它
## 这里刚打过一
## 最廉价也最准确的痕
func _shell_pile_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ph := StandardMaterial3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4471
	for i in 13:
		var shell := CylinderMesh.new()
		shell.top_radius = 0.042
		shell.bottom_radius = 0.048
		shell.height = rng.randf_range(0.22, 0.30)
		shell.radial_segments = 8
		shell.material = ph
		var a := rng.randf_range(0.0, TAU)
		var r := sqrt(rng.randf()) * 0.58
		var pos := Vector3(cos(a) * r, 0.048, sin(a) * r)
		var b := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
				* Basis(Vector3.RIGHT, PI * 0.5 + rng.randf_range(-0.10, 0.10))
		st.append_from(shell, 0, Transform3D(b, pos))
	st.generate_normals()
	return st.commit() as ArrayMesh


## 卷起的伪装网：两卷长短不一的网
## + 两道捆带
## 网卷是软塌的圆柱，和木箱、油桶的硬边形成对比，墙根的道具才不会全是方
func _camo_roll_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ph := StandardMaterial3D.new()
	var rolls := [
		[0.19, 1.55, Vector3(0.0, 0.19, 0.0), 0.0],
		[0.15, 1.05, Vector3(0.10, 0.49, 0.18), 0.14],
	]
	for spec in rolls:
		var radius: float = spec[0]
		var length: float = spec[1]
		var pos: Vector3 = spec[2]
		var yaw: float = spec[3]
		var roll := CylinderMesh.new()
		roll.top_radius = radius
		roll.bottom_radius = radius
		roll.height = length
		roll.radial_segments = 10
		roll.rings = 2
		roll.material = ph
		var b := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, PI * 0.5)
		st.append_from(roll, 0, Transform3D(b, pos))
	for z in [-0.42, 0.42]:
		var strap := TorusMesh.new()
		strap.inner_radius = 0.175
		strap.outer_radius = 0.205
		strap.rings = 10
		strap.ring_segments = 5
		strap.material = ph
		var tr := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 0.19, z))
		st.append_from(strap, 0, tr)
	st.generate_normals()
	return st.commit() as ArrayMesh


## 把一个路障格塞满：主件居+ 两三件配件围在边上，偶尔再立一根高
## 
## 格子整格都有碰撞体，所以视觉上必须填得够满，玩家才不会觉得"明明有缝却过不去"## 反过来，任何一件都不许探出格子边界，否则它会伸进旁边没有碰撞体的空格，
## 变成一看得见、撞不到"的假障碍——那正是穿越障碍物的观感来源
func _fill_barricade(rng: RandomNumberGenerator, slots: Dictionary, x: int, y: int) -> void:
	var center := cell_center(x, y)
	# 4x4 格为一个街区取主题：相邻路障格大概率落在同一组，
	# 于是"残骸 + 油桶 + 管材"会挨在一起，而不是每格各讲各的故
	var theme_id := _cell_hash(Vector2i(x / 4, y / 4), 77) % PROP_THEMES.size()
	var theme: Array = PROP_THEMES[theme_id]
	var main: String = theme[_cell_hash(Vector2i(x, y), 23) % 2]
	slots[main].append(_prop_xform(rng, main, center, Vector3.ZERO, 1.3))

	for i in rng.randi_range(2, 3):
		var key: String = theme[rng.randi_range(2, theme.size() - 1)]
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(0.7, 1.15)
		var off := Vector3(cos(a) * d, 0.0, sin(a) * d)
		slots[key].append(_prop_xform(rng, key, center, off, 1.05))

	# 高杆只出现在实心格里，所立着的东西一定撞得到"这条规则不会被破
	# 哨卡主题更常立路灯，维修点更常立枯树
	var tall_chance := 0.25
	if theme_id == 1:
		tall_chance = 0.55
	elif theme_id == 2:
		tall_chance = 0.15
	if rng.randf() < tall_chance:
		# 白天地形不立路灯。
		#
		# 灯罩是 0.14 粗糙度的深色玻璃，白天在直射光与天空反射下就是一颗
		# 过曝的白球——5 m 高的杆子上顶着一个比墙顶还亮的点，视线全被它拽过去。
		# 而一条白天的战场街道本来也不该亮着灯。夜战市区另有 `_add_street_lamps`
		# 成排立灯并挂真实光源，所以这里只在夜图上保留路灯，其余换枯树。
		#
		# 注意 rng 调用次数与原来完全一致：换的是模型键，不是抽签序列，
		# 于是十二张图的布局、可读性数值都不会被这次改动带偏。
		var tall: String = PROP_TALL[0] if theme_id == 1 \
				else PROP_TALL[rng.randi() % PROP_TALL.size()]
		if tall == "prop_lamp" and terrain_name() != "夜战市区":
			tall = "prop_deadtree"
		var off2 := Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.8, 0.8))
		slots[tall].append(_prop_xform(rng, tall, center, off2, 1.0))


## 夜战街灯与窗口灯##
## 之前的夜图本质上把白天调：路灯只作为路障格里 15~55% 概率## 高杆出现，玩家出生点与主街上经常一根都没有，整张图就是一层均匀的蓝## 这里按街道补两样只在夜战市区生成的东西：
##   - 沿街灯杆：贴墙、亮灯、带真实碰撞与暖色光池，封顶 12 盏；
##   - 临街窗口：一MultiMesh 画完的暖/冷两色自发光窗，一个店面一眼就能读出来## 白天地形两个函数都在第一行返回，零开销
func _build_night_street() -> void:
	if terrain_name() != "夜战市区" or _props_root == null:
		return
	_add_street_lamps()
	_add_night_windows()


func _add_street_lamps() -> void:
	var lamp_mesh: Mesh = Assets.mesh_of("prop_lamp")
	if lamp_mesh == null:
		return
	# 候选：空格、不在路面上、至少贴着一面砖/钢墙。优先临街（旁边有路面）
	# 或夹在两堵墙之间——这两种位置才是真实街角"
	var cands: Array[Vector2i] = []
	for y in range(2, GRID_H - 2):
		for x in range(1, GRID_W - 1):
			var c := Vector2i(x, y)
			if cell(x, y) != EMPTY or _road_cells.has(c):
				continue
			# 与道具散布用同一套避让：出生走廊、基地通道与玩家活动区不放灯杆
			# 否则 0.3 m 的碰撞体可能正好立在坦克出生点前
			if not _scatterable(x, y):
				continue
			var walls := 0
			var on_street := false
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var t := cell(x + d.x, y + d.y)
				if t == BRICK or t == STEEL:
					walls += 1
				if _road_cells.has(Vector2i(x + d.x, y + d.y)):
					on_street = true
			if walls >= 1 and (on_street or walls >= 2):
				cands.append(c)
	if cands.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 515151 + terrain * 313
	# 按离玩家出生点的距离排序：出生点附近的主街先立灯，玩家一开局就看得到
	# 脚下的暖色光池；否则 12 盏灯会被均匀撒到 96 m 见方的地图边缘，
	# 出生点周围仍然是一片蓝
	var spawn_cell := to_cell(player_spawn())
	cands.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a - spawn_cell).length_squared() \
				< Vector2(b - spawn_cell).length_squared())
	var used: Array[Vector2i] = []
	var placed := 0
	for c in cands:
		if placed >= 12:
			break
		# 抽稀：同一条街每隔 3 格以上才再立一
		var clear := true
		for u in used:
			if absi(u.x - c.x) + absi(u.y - c.y) < 3:
				clear = false
				break
		if not clear:
			continue
		used.append(c)
		placed += 1
		_place_street_lamp(c, lamp_mesh, rng)
	print("NIGHT streetlamps placed=%d candidates=%d" % [placed, cands.size()])


func _place_street_lamp(c: Vector2i, mesh: Mesh, rng: RandomNumberGenerator) -> void:
	var center := cell_center(c.x, c.y)
	# 找面朝街道的方向：优先挑旁边是路面的那面墙，灯臂才会伸到街上
	var wall_dir := Vector2i.ZERO
	var fallback := Vector2i.ZERO
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var t := cell(c.x + d.x, c.y + d.y)
		if t != BRICK and t != STEEL:
			continue
		if fallback == Vector2i.ZERO:
			fallback = d
		var road_side := Vector2i(c.x - d.x, c.y - d.y)
		if _road_cells.has(road_side):
			wall_dir = d
			break
	if wall_dir == Vector2i.ZERO:
		wall_dir = fallback if fallback != Vector2i.ZERO else Vector2i(0, 1)

	var pos: Vector3 = center + Vector3(wall_dir.x, 0, wall_dir.y) * 1.12
	var arm := Vector3(-wall_dir.x, 0, -wall_dir.y)
	# 灯臂在模型里指向 Godot -Z，转arm 方向即可
	var yaw := atan2(-arm.x, -arm.z) + rng.randf_range(-0.06, 0.06)
	var basis := Basis(Vector3.UP, yaw)
	var tr := Transform3D(basis, pos)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = tr
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_props_root.add_child(mi)

	# 灯杆要真的挡车：没有碰撞体的高杆看着是障碍物，开过去毫无反应"的典
	# 半径0.30 m（杆0.11 + 底座 0.30），高度 4.8 m，放在世界层
	var body := StaticBody3D.new()
	body.position = pos + Vector3(0, 2.4, 0)
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.30
	cyl.height = 4.8
	cs.shape = cyl
	body.add_child(cs)
	_props_root.add_child(body)

	# 灯头位置：模型局(0, 4.84, -0.90)
	var head: Vector3 = tr * Vector3(0, 4.78, -0.90)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.38)
	light.light_energy = 2.2
	light.omni_range = 12.0
	light.omni_attenuation = 1.0
	light.position = head
	light.shadow_enabled = false
	_props_root.add_child(light)

	var bulb := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.13
	s.height = 0.26
	s.radial_segments = 8
	s.rings = 4
	bulb.mesh = s
	bulb.material_override = _lamp_bulb_material()
	bulb.position = head
	bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_props_root.add_child(bulb)


static var _bulb_mat_cache: StandardMaterial3D

static func _lamp_bulb_material() -> StandardMaterial3D:
	if _bulb_mat_cache != null:
		return _bulb_mat_cache
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.80, 0.48)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.72, 0.35)
	m.emission_energy_multiplier = 2.4
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bulb_mat_cache = m
	return m


## 临街窗口：只贴在钢墙朝空格的那一面，暖色为主、冷色点缀## 用两套材质（冷）各一MultiMesh，总共两个 draw call## 比逐窗MeshInstance3D 便宜两个数量
func _add_night_windows() -> void:
	var warm: Array[Transform3D] = []
	var cool: Array[Transform3D] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 99173 + terrain * 613
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for y in range(1, GRID_H - 1):
		for x in range(1, GRID_W - 1):
			var t := cell(x, y)
			if t != BRICK and t != STEEL:
				continue
			var h := BRICK_H if t == BRICK else STEEL_H
			var c := cell_center(x, y)
			for d in dirs:
				if cell(x + d.x, y + d.y) != EMPTY:
					continue
				# 只给临街立面开窗，概率压到 14%：窗太多会变马赛克楼"
				if rng.randf() > 0.14:
					continue
				var rows := [1.42, 2.62] if h > 3.4 else [1.34, 2.18]
				for wy in rows:
					if wy > h - 0.55:
						continue
					var tr := Transform3D.IDENTITY
					match d:
						Vector2i(1, 0):
							tr.basis = Basis(Vector3.UP, PI * 0.5)
						Vector2i(-1, 0):
							tr.basis = Basis(Vector3.UP, -PI * 0.5)
						Vector2i(0, 1):
							tr.basis = Basis(Vector3.UP, PI)
						_:
							tr.basis = Basis.IDENTITY
					tr.origin = c + Vector3(d.x, 0, d.y) * (CELL * 0.5 + 0.05) \
							+ Vector3(0, wy, 0)
					if rng.randf() < 0.74:
						warm.append(tr)
					else:
						cool.append(tr)
	_make_window_mm(warm, Color(1.0, 0.74, 0.40), "WindowsWarm")
	_make_window_mm(cool, Color(0.58, 0.76, 1.0), "WindowsCool")
	print("NIGHT windows warm=%d cool=%d" % [warm.size(), cool.size()])


func _make_window_mm(list: Array[Transform3D], col: Color, nname: String) -> void:
	if list.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(0.92, 0.56)
	mm.mesh = quad
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mi := MultiMeshInstance3D.new()
	mi.name = nname
	mi.multimesh = mm
	var m := StandardMaterial3D.new()
	m.albedo_color = col.darkened(0.78)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.8
	m.roughness = 0.5
	m.disable_receive_shadows = true
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_props_root.add_child(mi)


## 夜战路灯：在部分灯杆顶部挂一盏暖色点+ 一个自发光灯泡## 上限 8 盏——街道灯已经提供了主要光池，这里只补路障格里的零散高
func _add_lamp_lights(lamps: Array) -> void:
	var n := mini(lamps.size(), 8)
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = Color(1.0, 0.78, 0.42)
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.72, 0.35)
	bulb_mat.emission_energy_multiplier = 2.2
	bulb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in n:
		var tr: Transform3D = lamps[i]
		var pos: Vector3 = tr.origin
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.74, 0.40)
		light.light_energy = 1.5
		light.omni_range = 11.0
		light.omni_attenuation = 1.2
		light.position = pos + Vector3(0, 4.4, 0)
		light.shadow_enabled = false
		_props_root.add_child(light)

		var bulb := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.14
		s.height = 0.28
		s.radial_segments = 8
		s.rings = 4
		bulb.mesh = s
		bulb.material_override = bulb_mat
		bulb.position = pos + Vector3(0, 4.45, 0)
		bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_props_root.add_child(bulb)


## 按足迹把尺寸压到格内。cap 是期望的最大放大倍数，实际取它与"塞得进去"的较小
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


## 水岸：沿每一格水面的临岸边缘贴一条会呼吸的泡沫带，并在岸上压一条湿
## 
## 水面 shader 本身做了深度渐变与折射，但岸边是硬切的——没有泡沫线## 水就像一蓝玻璃板"嵌在地里。这里按格判断哪几条边临岸，
## MultiMesh + INSTANCE_CUSTOM 把四条边的开合状态传shader## 于是整片水网只有两次 draw call：水面泡沫与岸上湿泥
func _build_shoreline() -> void:
	if _shore_root != null:
		_shore_root.queue_free()
	_shore_root = Node3D.new()
	_shore_root.name = "Shore"
	add_child(_shore_root)

	var foam_cells: Array = []
	var wet_cells: Array = []
	for y in GRID_H:
		for x in GRID_W:
			var t := cell(x, y)
			var mask := 0
			if t == WATER:
				if cell(x + 1, y) != WATER:
					mask |= 1
				if cell(x - 1, y) != WATER:
					mask |= 2
				if cell(x, y + 1) != WATER:
					mask |= 4
				if cell(x, y - 1) != WATER:
					mask |= 8
				if mask != 0:
					foam_cells.append([Vector2i(x, y), mask])
			elif t == EMPTY:
				# 岸这一侧：哪条边的邻居是水"决定湿泥压在哪一
				if cell(x + 1, y) == WATER:
					mask |= 1
				if cell(x - 1, y) == WATER:
					mask |= 2
				if cell(x, y + 1) == WATER:
					mask |= 4
				if cell(x, y - 1) == WATER:
					mask |= 8
				if mask != 0:
					wet_cells.append([Vector2i(x, y), mask])

	_make_shore_mm(foam_cells, WATER_H + 0.045, _foam_material(), "Foam")
	_make_shore_mm(wet_cells, 0.026, _wet_material(), "WetBank")


func _make_shore_mm(cells: Array, y: float, mat: Material, nname: String) -> void:
	if cells.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := PlaneMesh.new()
	quad.size = Vector2(CELL, CELL)
	mm.mesh = quad
	mm.instance_count = cells.size()
	for i in cells.size():
		var c: Vector2i = cells[i][0]
		var mask: int = cells[i][1]
		var tr := Transform3D.IDENTITY
		tr.origin = cell_center(c.x, c.y) + Vector3(0, y, 0)
		mm.set_instance_transform(i, tr)
		# 把四位边掩码压进 INSTANCE_CUSTOM.r；shader 里乘16 还原
		mm.set_instance_custom_data(i, Color(float(mask) / 16.0, 0.0, 0.0, 1.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nname
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shore_root.add_child(mmi)


func _foam_material() -> ShaderMaterial:
	if _foam_shader == null:
		_foam_shader = Shader.new()
		_foam_shader.code = _FOAM_SHADER
	var m := ShaderMaterial.new()
	m.shader = _foam_shader
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	# 泡沫不是纯白：取地平色提亮，阴天的水岸才不会出现一荧光
	m.set_shader_parameter("foam_col", (t["sky_hor"] as Color).lerp(Color(1, 1, 1), 0.55))
	return m


func _wet_material() -> ShaderMaterial:
	if _wet_shader == null:
		_wet_shader = Shader.new()
		_wet_shader.code = _WET_SHADER
	var m := ShaderMaterial.new()
	m.shader = _wet_shader
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	m.set_shader_parameter("wet_col", (t["soil_low"] as Color).darkened(0.45))
	return m


const _FOAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform vec4 foam_col : source_color = vec4(0.72, 0.80, 0.78, 1.0);
uniform float strength = 0.68;

varying vec2 fuv;
varying float edge_mask;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = p * 2.07 + vec2(11.0, 5.0);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	fuv = UV;
	// 1=+X 2=-X 4=+Z 8=-Z @ 1/16
	edge_mask = INSTANCE_CUSTOM.r * 16.0;
}

void fragment() {
	// 到最近的"临岸的归一化距离。两边临水时两条边都有泡
	float d = 10.0;
	if (mod(edge_mask, 2.0) >= 1.0) { d = min(d, 1.0 - fuv.x); }
	if (mod(floor(edge_mask / 2.0), 2.0) >= 1.0) { d = min(d, fuv.x); }
	if (mod(floor(edge_mask / 4.0), 2.0) >= 1.0) { d = min(d, 1.0 - fuv.y); }
	if (mod(floor(edge_mask / 8.0), 2.0) >= 1.0) { d = min(d, fuv.y); }

	// 泡沫线不是等宽的：噪声让宽度4~12 cm 间起伏，
	// 再叠一层缓慢推进的正弦，边缘才冲上滩再退回去"
	float wob = fbm2(fuv * 9.0 + vec2(TIME * 0.21, TIME * 0.15));
	float width = 0.075 + 0.060 * wob;
	float line = 1.0 - smoothstep(0.0, width, d);
	float breathe = 0.55 + 0.45 * sin(TIME * 1.15 + fuv.x * 7.0 + fuv.y * 5.0);
	float a = line * strength * (0.35 + 0.65 * breathe) * (0.62 + 0.38 * wob);
	ALBEDO = foam_col.rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

const _WET_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 wet_col : source_color = vec4(0.11, 0.10, 0.08, 1.0);
uniform float wet_width = 0.34;
uniform float wet_alpha = 0.78;

varying vec2 fuv;
varying float edge_mask;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	fuv = UV;
	edge_mask = INSTANCE_CUSTOM.r * 16.0;
}

void fragment() {
	float d = 10.0;
	if (mod(edge_mask, 2.0) >= 1.0) { d = min(d, 1.0 - fuv.x); }
	if (mod(floor(edge_mask / 2.0), 2.0) >= 1.0) { d = min(d, fuv.x); }
	if (mod(floor(edge_mask / 4.0), 2.0) >= 1.0) { d = min(d, 1.0 - fuv.y); }
	if (mod(floor(edge_mask / 8.0), 2.0) >= 1.0) { d = min(d, fuv.y); }

	float wob = vnoise(fuv * 6.0 + TIME * 0.04);
	// 湿泥从水线往岸上退，边缘用噪声打碎，不留一条笔直的色带
	float a = (1.0 - smoothstep(wet_width * 0.45, wet_width + 0.10 * wob, d)) * wet_alpha;
	// 最靠水1/3 取一点藻绿，泥岸才不只是"压暗的地
	float algae = 1.0 - smoothstep(0.0, wet_width * 0.55, d);
	vec3 col = mix(wet_col.rgb, vec3(0.085, 0.105, 0.060), algae * 0.55);
	ALBEDO = col * (0.88 + 0.24 * wob);
	ALPHA = clamp(a, 0.0, 1.0);
	ROUGHNESS = 0.20;
	SPECULAR = 0.55;
}
"""


## 连续墙的接缝壁柱##
## 墙体按格生成（破坏、寻路、碰撞都必须按格，这是对的），但视觉上每 4 m 一## 网格边界会让 12 m 的墙读成"三块积木"。这里在同类墙格之间压一根竖向壁柱：
## 壁柱跨过拼缝、略凸出墙面，连续墙于是有一条连续的结构线，而不是三块各自收边的方块## 它只是视觉层——碰撞、血量、寻路都没有
func _schedule_joints() -> void:
	_joints_dirty = true
	if _joints_pending:
		return
	_joints_pending = true
	if is_inside_tree():
		call_deferred("_refresh_joints")
	else:
		_refresh_joints()


func _refresh_joints() -> void:
	_joints_pending = false
	if not _joints_dirty:
		return
	_joints_dirty = false
	if _joints_root != null:
		remove_child(_joints_root)
		_joints_root.queue_free()
	_joints_root = Node3D.new()
	_joints_root.name = "WallJoints"
	add_child(_joints_root)

	var brick: Array[Transform3D] = []
	var steel: Array[Transform3D] = []
	for y in GRID_H:
		for x in GRID_W:
			var t := cell(x, y)
			if t != BRICK and t != STEEL:
				continue
			# 最外圈没有墙块模型，可见替身是连续土坡；再给它生成壁柱
			# 坡脚前就会站出一排灰柱子，正好挡住坡面
			if x == 0 or y == 0 or x == GRID_W - 1 or y == GRID_H - 1:
				continue
			var h := BRICK_H if t == BRICK else STEEL_H
			var c := cell_center(x, y)
			var list: Array[Transform3D] = brick if t == BRICK else steel
			# 只在**两种墙相接**处立一根壁柱。
			#
			# 段内的接缝已经被连续瓦片消掉了，再每 4 m 补一根凸出的柱子，
			# 反而把一面 12 m 的墙重新切成三块——那正是要修的东西。
			# 砖墙与钢墙相接的位置是真实的结构缝：两种材料不能砌在一起，
			# 需要一根柱子收头，这里保留它。
			var right := cell(x + 1, y)
			if (right == BRICK or right == STEEL) and right != t:
				var hx := maxf(h, STEEL_H if right == STEEL else BRICK_H)
				list.append(_joint_xform(
						Vector3(c.x + CELL * 0.5, hx * 0.5, c.z), hx, true))
			var down := cell(x, y + 1)
			if (down == BRICK or down == STEEL) and down != t:
				var hz := maxf(h, STEEL_H if down == STEEL else BRICK_H)
				list.append(_joint_xform(
						Vector3(c.x, hz * 0.5, c.z + CELL * 0.5), hz, false))

	if not brick.is_empty():
		_make_joint_mm(brick, Color(0.255, 0.205, 0.165), 0.95, false, "JointsBrick")
	if not steel.is_empty():
		_make_joint_mm(steel, Color(0.315, 0.335, 0.355), 0.42, true, "JointsSteel")


func _joint_xform(pos: Vector3, h: float, on_x: bool) -> Transform3D:
	var tr := Transform3D.IDENTITY
	# 壁柱必须比墙体更宽，否则会整根埋在墙里看不见
	# 墙块±3% 的横向尺寸抖动（4.0 格内最大约 4.09 m），所以取 4.18 m
	# 每侧凸出5 cm，正好是一条能读出"这里是结构线"的浅壁柱
	var thin := 0.26
	var wide := CELL * 1.045
	var hh := h * 0.995
	tr.basis = Basis.from_scale(
			Vector3(thin, hh, wide) if on_x else Vector3(wide, hh, thin))
	tr.origin = pos
	return tr


func _make_joint_mm(list: Array[Transform3D], col: Color, rough: float,
		metal: bool, nname: String) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mm.mesh = box
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = rough
	mat.metallic = 0.55 if metal else 0.0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nname
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_joints_root.add_child(mmi)


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


## 植被：墙根与空地上的草簇 + 稀疏灌
## 
## 原来整张图只有路障格25% 概率出现一棵枯树，地面是纯噪声
## 没有植被，地形看起来没人住过"。草簇用交叉双面+ alpha 剪切## 一MultiMesh 画完；灌木是三个低模球合并成的团，另一draw call## 风摆写在顶点着色器里，不增加任CPU 开销
func _build_vegetation() -> void:
	if _veg_root != null:
		_veg_root.queue_free()
	_veg_root = Node3D.new()
	_veg_root.name = "Vegetation"
	add_child(_veg_root)

	var factor := _grass_factor()
	if factor <= 0.01:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = 77123 + terrain * 1931

	var grass_xf: Array[Transform3D] = []
	for y in range(2, GRID_H - 2):
		for x in range(1, GRID_W - 1):
			if cell(x, y) != EMPTY or not _scatterable(x, y):
				continue
			if _road_cells.has(Vector2i(x, y)):
				continue
			if rng.randf() > 0.62 * factor:
				continue
			var center := cell_center(x, y)
			for i in rng.randi_range(4, 8):
				var tr := Transform3D.IDENTITY
				tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
				var s := rng.randf_range(0.55, 1.05)
				tr = tr.scaled(Vector3(s, s * rng.randf_range(0.75, 1.15), s))
				tr.origin = center + Vector3(
					rng.randf_range(-1.85, 1.85), 0.0, rng.randf_range(-1.85, 1.85))
				grass_xf.append(tr)

	if grass_xf.size() > 0:
		var grass := MultiMesh.new()
		grass.transform_format = MultiMesh.TRANSFORM_3D
		grass.mesh = _grass_card_mesh()
		grass.instance_count = grass_xf.size()
		for i in grass_xf.size():
			grass.set_instance_transform(i, grass_xf[i])
		var gm := MultiMeshInstance3D.new()
		gm.name = "Grass"
		gm.multimesh = grass
		gm.material_override = _grass_material()
		gm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gm.visibility_range_end = 95.0
		_veg_root.add_child(gm)

	# 芦苇：只长在临岸一格，沿水线成簇。水岸原来只有一条硬边，
	# 泡沫解决"水有没有，芦苇解岸是不是活的"——它们是同一件事的两
	var reed_xf: Array[Transform3D] = []
	for y in range(1, GRID_H - 1):
		for x in range(1, GRID_W - 1):
			if cell(x, y) != EMPTY or not _scatterable(x, y):
				continue
			var toward := Vector3i.ZERO
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if cell(x + d.x, y + d.y) == WATER:
					toward += Vector3i(d.x, 0, d.y)
			if toward == Vector3i.ZERO:
				continue
			var dir := Vector3(toward.x, 0.0, toward.z).normalized()
			var side := Vector3(-dir.z, 0.0, dir.x)
			var center := cell_center(x, y)
			for i in rng.randi_range(5, 11):
				var tr := Transform3D.IDENTITY
				var s := rng.randf_range(0.9, 1.35)
				# 草叶网格0.48 m；芦苇要高出水面一截，所以只Y
				tr = tr.scaled(Vector3(s, s * rng.randf_range(1.55, 2.35), s))
				tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
				tr.origin = center + dir * rng.randf_range(1.05, 1.86) \
						+ side * rng.randf_range(-1.45, 1.45)
				reed_xf.append(tr)

	if reed_xf.size() > 0:
		var reeds := MultiMesh.new()
		reeds.transform_format = MultiMesh.TRANSFORM_3D
		reeds.mesh = _grass_card_mesh()
		reeds.instance_count = reed_xf.size()
		for i in reed_xf.size():
			reeds.set_instance_transform(i, reed_xf[i])
		var rm := MultiMeshInstance3D.new()
		rm.name = "Reeds"
		rm.multimesh = reeds
		rm.material_override = _reed_material()
		rm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rm.visibility_range_end = 85.0
		_veg_root.add_child(rm)

	# 灌木：只贴着墙根长，密度低。它们没有碰撞——这是纯装饰层，
	# 不能让人误以这一丛能当掩
	var shrub_xf: Array[Transform3D] = []
	for y in range(2, GRID_H - 2):
		for x in range(2, GRID_W - 2):
			if cell(x, y) != EMPTY or not _scatterable(x, y):
				continue
			if _road_cells.has(Vector2i(x, y)):
				continue
			var wall := false
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var c := cell(x + d.x, y + d.y)
				if c == BRICK or c == STEEL:
					wall = true
					break
			if not wall or rng.randf() > 0.34 * factor:
				continue
			var tr := Transform3D.IDENTITY
			tr = tr.rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			var s := rng.randf_range(0.55, 1.15)
			tr = tr.scaled(Vector3(s, s * rng.randf_range(0.7, 1.1), s))
			tr.origin = cell_center(x, y) + Vector3(
				rng.randf_range(-1.4, 1.4), 0.0, rng.randf_range(-1.4, 1.4))
			shrub_xf.append(tr)

	if shrub_xf.size() > 0:
		var shrub := MultiMesh.new()
		shrub.transform_format = MultiMesh.TRANSFORM_3D
		shrub.mesh = _shrub_mesh()
		shrub.instance_count = shrub_xf.size()
		for i in shrub_xf.size():
			shrub.set_instance_transform(i, shrub_xf[i])
		var sm := MultiMeshInstance3D.new()
		sm.name = "Shrubs"
		sm.multimesh = shrub
		sm.material_override = _shrub_material()
		sm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_veg_root.add_child(sm)


func _grass_factor() -> float:
	match terrain_name():
		"丛林小径":
			return 1.0
		"河谷渡口":
			return 0.72
		"废墟城区", "开阔荒漠":
			return 0.42
		"要塞回廊":
			return 0.30
		"迷宫街区":
			return 0.26
		"铁路枢纽":
			return 0.18
		"夜战市区":
			return 0.12
		"雪原哨所", "沙漠风暴":
			return 0.08
		"工业港区", "熔岩弹坑":
			return 0.03
		_:
			return 0.35


## 交叉双面片：两片 90° 相交的四边形，任何角度看都有草叶，而不是一张纸
func _grass_card_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var quads := [
		[Vector3(-0.30, 0, 0), Vector3(0.30, 0, 0)],
		[Vector3(0, 0, -0.30), Vector3(0, 0, 0.30)],
	]
	for q in quads:
		var a: Vector3 = q[0]
		var b: Vector3 = q[1]
		var base := verts.size()
		verts.append(a)
		verts.append(b)
		verts.append(b + Vector3(0, 0.32, 0))
		verts.append(a + Vector3(0, 0.32, 0))
		uvs.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		for _i in 4:
			norms.append(Vector3.UP)
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


func _grass_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(0.22, 0.30, 0.12);
uniform float wind = 1.0;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float sway = sin(TIME * 1.7 + wp.x * 0.45 + wp.z * 0.33) * 0.06 * wind * UV.y;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.55;
}

void fragment() {
	vec4 c = texture(tex, UV);
	ALBEDO = tint * c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.42;
	ROUGHNESS = 0.92;
	SPECULAR = 0.08;
	// 极弱的自发光环境反弹"：草叶在墙根、车底这类全遮挡处不再压成黑
	// 0.055 只是把纯黑抬成深绿，夜里也不会变成发光草
	EMISSION = tint * 0.035;
	// 草片是两张交叉的四边形，顶点法线统一朝上（像地面一样受光）
	// cull_disabled 下背面会让引擎翻转法线，背光的那张片因此渲染成纯黑，
	// 整簇草看起来绿片旁边贴了一块黑。把法线重新钉成世界上方向，
	// 两张片就都按地面朝向受光
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	// 草叶背光：给一点透射色，逆光时不会变成黑
	BACKLIGHT = vec3(0.16, 0.20, 0.08);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tex", _grass_tex())
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	var low: Color = t["soil_low"]
	var high: Color = t["soil_high"]
	# 用地面亮度的上限去混草色：草比土亮一点、绿一点就
	# 原来直接soil_low（画面的最暗色）去乘，草的背光面在阴影里就是一块黑
	m.set_shader_parameter("tint", high.lerp(Color(0.15, 0.20, 0.09), 0.34))
	return m


## 芦苇：同一套草叶网格与风摆，换成更黄、更高的水岸
## 单独一个材质而不是给草调色，是因为芦苇要一直长到水线里## 与空地上的草簇在颜色上必须有区分，否则岸边看起来只是"草长得高"
func _reed_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(0.24, 0.27, 0.11);
uniform float wind = 1.45;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float sway = sin(TIME * 1.25 + wp.x * 0.38 + wp.z * 0.29) * 0.07 * wind * UV.y;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.45;
}

void fragment() {
	vec4 c = texture(tex, UV);
	ALBEDO = tint * c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.90;
	SPECULAR = 0.10;
	// 同草地：背面不翻法线，否则每一簇芦苇都有一半是黑的
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	BACKLIGHT = vec3(0.13, 0.15, 0.05);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tex", _grass_tex())
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	m.set_shader_parameter("tint", (t["soil_high"] as Color).lerp(Color(0.24, 0.24, 0.11), 0.45))
	return m


static func _grass_tex() -> Texture2D:
	if _grass_tex_cache != null:
		return _grass_tex_cache
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	# 透明像素也填上草色（alpha=0）。填成纯黑的话，mipmap 会把 1~2 px 宽的
	# 草叶与黑底平均，远处每一簇都变成"上面绿、下面黑"的脏
	img.fill(Color(0.52, 0.58, 0.38, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in 34:
		var x0 := rng.randf_range(3.0, float(n) - 3.0)
		var h := rng.randf_range(20.0, float(n) - 2.0)
		var bend := rng.randf_range(-7.0, 7.0)
		var w := rng.randi_range(1, 3)
		var shade := rng.randf_range(0.72, 1.0)
		for y in int(h):
			var t := float(y) / maxf(h, 1.0)
			var x := x0 + bend * t * t
			var col := Color(shade, shade * 1.02, shade * 0.82, 0.55 + 0.45 * t)
			for dx in range(-w, w + 1):
				var ix := int(round(x)) + dx
				var iy := n - 1 - y
				if ix >= 0 and ix < n and iy >= 0 and iy < n:
					img.set_pixel(ix, iy, col)
	var tex := ImageTexture.create_from_image(img)
	_grass_tex_cache = tex
	return tex


## 灌木：三个低模球错位合并，远看是一团有体积的叶簇，而不是一颗球
func _shrub_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sphere := SphereMesh.new()
	sphere.radius = 0.42
	sphere.height = 0.78
	sphere.radial_segments = 6
	sphere.rings = 3
	var offsets := [
		Vector3(0.0, 0.40, 0.0),
		Vector3(0.34, 0.28, 0.12),
		Vector3(-0.26, 0.26, -0.22),
	]
	for o in offsets:
		var tr := Transform3D(Basis.IDENTITY.scaled(Vector3(1.05, 0.92, 1.05)), o)
		st.append_from(sphere, 0, tr)
	st.generate_normals()
	return st.commit() as ArrayMesh


func _shrub_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	m.albedo_color = (t["soil_low"] as Color).lerp(Color(0.13, 0.21, 0.08), 0.60)
	m.roughness = 0.94
	m.metallic = 0.0
	return m


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


# ---------------- 贴花：战场痕----------------

## 爆炸烧灼痕。半径按爆炸规模缩放，超出上限时回收最旧的一
func add_scorch(pos: Vector3, size := 1.0) -> void:
	_push_decal(pos, randf_range(0.0, TAU), Vector3(4.0 * size, 2.0, 4.0 * size),
		"scorch", 0.86, _scorches, MAX_SCORCH)


## HE 弹坑：比烧灼痕更小更
func add_crater(pos: Vector3, size := 1.0) -> void:
	_push_decal(pos, randf_range(0.0, TAU), Vector3(2.6 * size, 1.6, 2.6 * size),
		"crater", 0.95, _scorches, MAX_SCORCH)


## 履带印：左、右两条平行的链节带，而不是一3.2×1.5 的糊
func add_track(pos: Vector3, yaw: float) -> void:
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	for side in [-1.0, 1.0]:
		_push_decal(pos + right * (0.72 * side), yaw,
			Vector3(0.66, 1.0, 2.5), "track", 0.62, _tracks, MAX_TRACK)


func _push_decal(pos: Vector3, yaw: float, size: Vector3, kind: String,
		opacity: float, pool: Array, cap: int) -> void:
	if _decal_root == null or Settings.quality == Settings.Quality.LOW:
		return
	var d := Decal.new()
	d.texture_albedo = _decal_tex(kind)
	var nrm := _decal_normal(kind)
	if nrm != null:
		d.texture_normal = nrm
		d.normal_fade = 0.55
	d.size = size
	d.modulate = Color(1, 1, 1, opacity)
	d.albedo_mix = 0.95
	d.upper_fade = 1.4 if kind != "track" else 0.6
	d.lower_fade = 0.25
	d.position = Vector3(pos.x, 0.02, pos.z)
	d.rotation.y = yaw
	d.cull_mask = 0xFFFFF
	_decal_root.add_child(d)
	pool.append(d)
	while pool.size() > cap:
		var old = pool.pop_front()
		if is_instance_valid(old):
			old.queue_free()


## 三种痕迹各有一张程序化贴图。原来烧灼、弹坑、履带印共用同一张软圆，
## 区别只有颜色和尺寸，所以地面上的痕迹看起来都是"棕色圆斑"##
## scorch：不规则外缘 + 内部斑驳的炭黑；
## crater：中心凹陷、四周一圈翻起的土沿## track：一条链节带（两侧有履带板缺口），左右两条由 add_track 摆出
static func _decal_tex(kind: String) -> Texture2D:
	if _decal_cache.has(kind):
		return _decal_cache[kind]
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var noise := FastNoiseLite.new()
	noise.seed = 17
	noise.frequency = 0.045
	noise.fractal_octaves = 3
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			img.set_pixel(x, y, _decal_albedo(kind, u, v, noise))
	var tex := ImageTexture.create_from_image(img)
	_decal_cache[kind] = tex
	return tex


static func _decal_normal(kind: String) -> Texture2D:
	if kind == "track":
		return null
	if _decal_normal_cache.has(kind):
		return _decal_normal_cache[kind]
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 17
	noise.frequency = 0.045
	noise.fractal_octaves = 3
	var e := 1.6
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var h := _decal_height(kind, u, v, noise)
			var hx := _decal_height(kind, u + e / float(n), v, noise)
			var hz := _decal_height(kind, u, v + e / float(n), noise)
			var nrm := Vector3(-(hx - h) * 5.0, -(hz - h) * 5.0, 1.0).normalized()
			img.set_pixel(x, y, Color(nrm.x * 0.5 + 0.5, nrm.y * 0.5 + 0.5,
				nrm.z * 0.5 + 0.5, 1.0))
	var tex := ImageTexture.create_from_image(img)
	_decal_normal_cache[kind] = tex
	return tex


static func _decal_albedo(kind: String, u: float, v: float,
		noise: FastNoiseLite) -> Color:
	var r := sqrt(u * u + v * v)
	var n := noise.get_noise_2d(u * 23.0, v * 23.0)
	match kind:
		"track":
			var band := 1.0 - smoothstep(0.26, 0.34, abs(u))
			var link := absf(fposmod(v * 7.0 + 0.5, 1.0) - 0.5) * 2.0
			var tread := smoothstep(0.15, 0.85, link)
			var ends := smoothstep(0.0, 0.06, v + 1.0) * smoothstep(0.0, 0.06, 1.0 - v)
			var a := band * ends * (0.30 + 0.42 * tread)
			var col := Color(0.13, 0.12, 0.10).lerp(Color(0.055, 0.05, 0.045), tread)
			return Color(col.r, col.g, col.b, a)
		"crater":
			var core := 1.0 - smoothstep(0.0, 0.44, r)
			var rim := exp(-pow((r - 0.66) / 0.20, 2.0))
			var edge := 0.92 + n * 0.10
			var a := 1.0 - smoothstep(edge - 0.05, edge + 0.16, r)
			var col := Color(0.07, 0.058, 0.048)
			col = col.lerp(Color(0.30, 0.245, 0.185), clampf(rim * 0.9, 0.0, 1.0))
			col = col.lerp(Color(0.025, 0.022, 0.02), core * 0.85)
			return Color(col.r, col.g, col.b, a)
		_:
			var edge_s := 0.86 + n * 0.26
			var a_s := 1.0 - smoothstep(edge_s - 0.04, edge_s + 0.20, r)
			var mottle := 0.5 + 0.5 * noise.get_noise_2d(u * 7.0 + 11.0, v * 7.0 - 4.0)
			var c := Color(0.035, 0.032, 0.030).lerp(
				Color(0.17, 0.15, 0.12), mottle * 0.55)
			return Color(c.r, c.g, c.b, a_s * 0.92)


static func _decal_height(kind: String, u: float, v: float,
		noise: FastNoiseLite) -> float:
	var r := sqrt(u * u + v * v)
	var n := noise.get_noise_2d(u * 23.0, v * 23.0)
	if kind == "crater":
		var core := 1.0 - smoothstep(0.0, 0.44, r)
		var rim := exp(-pow((r - 0.66) / 0.20, 2.0))
		return -core * 0.9 + rim * 0.65 + n * 0.06
	var edge_s := 0.86 + n * 0.26
	var a_s := 1.0 - smoothstep(edge_s - 0.04, edge_s + 0.20, r)
	return -a_s * 0.18 + n * 0.05


func _build_base_node() -> void:
	_base_node = Node3D.new()
	_base_node.position = base_position()
	add_child(_base_node)

	if not _build_base_model():
		_build_base_primitive()

	# 基地光柱，远处也能一眼看
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


## 碉堡模型：射击口-Z（敌人来向），与 gen_base.py 的坐标约定一致，无需额外旋转
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


## 基地血量反馈：旗面与信号灯（M_Accent）从青蓝烧到警告
## 两条路径表达的是同一条视觉语言，只是着色对象不
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
		"sandbag": _mat(Color(0.40, 0.34, 0.23), 0.92, 0.0),
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
## 所以低画质能退回改造前的轻量环境，高画质才SSAO/SSIL/SDFGI/体积
static var _sky_shader: Shader

## 天空：渐+ 太阳/月亮+ 云层 + 星空##
## 只用天空着色器能拿到的东西（视线方向、主光方颜色、时间），不引入任何贴图##   - 地平线附近加一层雾霭带，把"地面平面切到天空"的硬边吃掉；
##   - 主光方向画一个带柔边的日盘（夜里就是月盘，尺寸由 uniform 控制）；
##   - 高频 fbm 云层，靠近主光的一侧被染成暖色##   - 深色天空（sky_top 亮度低）自动叠一层星场，夜里才有"星空"而不暗蓝色白
const _SKY_SHADER := """
shader_type sky;

uniform vec3 sky_top_color : source_color = vec3(0.09, 0.13, 0.25);
uniform vec3 sky_horizon_color : source_color = vec3(0.46, 0.36, 0.30);
uniform vec3 ground_bottom_color : source_color = vec3(0.08, 0.08, 0.075);
uniform vec3 ground_horizon_color : source_color = vec3(0.32, 0.27, 0.23);

uniform float sun_size = 0.016;
uniform float sun_disk_energy = 1.4;
uniform float cloud_amount = 0.35;
uniform float cloud_speed = 0.006;
uniform float star_amount = 0.0;
uniform float haze = 0.42;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.07 + vec2(13.0, 7.0);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float h = dir.y;
	vec3 col;

	if (h >= 0.0) {
		float t = pow(clamp(h, 0.0, 1.0), 0.52);
		col = mix(sky_horizon_color, sky_top_color, t);
	} else {
		float t = pow(clamp(-h, 0.0, 1.0), 0.55);
		col = mix(ground_horizon_color, ground_bottom_color, t);
	}

	// 地平线雾霭：越接h=0 越厚，把地面与天空接起来
	float band = pow(1.0 - clamp(abs(h) * 3.2, 0.0, 1.0), 2.0);
	col = mix(col, sky_horizon_color * 1.08, band * haze);

	// 月盘与周围光晕。夜里主光就是月亮，尺寸与亮度由 terrain
	if (LIGHT0_ENABLED) {
		vec3 l = normalize(LIGHT0_DIRECTION);
		float d = clamp(dot(dir, l), 0.0, 1.0);
		float disk = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.35, d);
		float glow = pow(d, 10.0) * 0.22 + pow(d, 3.0) * 0.05;
		col += LIGHT0_COLOR * LIGHT0_ENERGY * (glow + disk * sun_disk_energy);
	}

	// 云层：只有上半球有，且越靠近地平线越密（透视压缩
	if (cloud_amount > 0.001 && h > 0.005) {
		vec2 cuv = dir.xz / max(h + 0.10, 0.10);
		cuv *= 0.72;
		cuv += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.37);
		float c = fbm(cuv * 1.55 + vec2(4.0, 1.7));
		float cover = smoothstep(0.48, 0.74, c);
		cover *= smoothstep(0.006, 0.16, h);
		float lit = pow(clamp(dot(dir, normalize(LIGHT0_DIRECTION + vec3(0.001))), 0.0, 1.0), 4.0);
		vec3 cloud_col = mix(sky_horizon_color * 1.10, vec3(0.92, 0.90, 0.86), 0.42);
		if (LIGHT0_ENABLED) {
			cloud_col = mix(cloud_col, LIGHT0_COLOR * 1.15, lit * 0.55);
		}
		col = mix(col, cloud_col, cover * cloud_amount);
	}

	// 星场：按视线方向做三维网格哈希，每颗星有独立闪烁相位
	if (star_amount > 0.001 && h > 0.02) {
		vec3 p = dir * 190.0;
		vec3 cell = floor(p);
		float s = hash31(cell);
		float star = step(0.9973, s);
		float tw = 0.55 + 0.45 * sin(TIME * 1.7 + s * 91.0);
		float fade = smoothstep(0.02, 0.28, h);
		col += vec3(0.82, 0.88, 1.0) * star * tw * star_amount * fade * 1.6;
	}

	COLOR = col;
}
"""


func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	# 自定义天空：渐变 + 太阳/月亮+ 云层 + 星空。原来的 ProceduralSkyMaterial
	# 只有一个渐变球，没有太阳盘也没有星空，夜战图就只是"把白天调
	if _sky_shader == null:
		_sky_shader = Shader.new()
		_sky_shader.code = _SKY_SHADER
	var pm := ShaderMaterial.new()
	pm.shader = _sky_shader
	sky.sky_material = pm
	env.sky = sky
	_sky_mat = pm

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.75
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# ACES Filmic 更能压住爆炸与炮口焰的高光，不会一开火就糊成白块
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	# white=6 会把整个中间调压进曲线的低段：爆炸不再过曝，但墙、地面和
	# 一起变暗部"，夜回廊的敌车因此跌破可读性下限。收3.0 之后
	# 中间调抬回一档，高光仍由 glow ACES 肩部兜住
	env.tonemap_white = 3.0

	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.1
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	# 分级 glow：低频层给大范围光晕，高频层保留炮口焰的锐度
	env.set_glow_level(1, 0.6)
	env.set_glow_level(3, 0.9)
	env.set_glow_level(5, 0.5)

	env.ssao_radius = 1.9
	env.ssao_intensity = 3.0
	env.ssao_power = 2.0
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
	env.adjustment_contrast = 1.12
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
	# normal_bias 1.4 收到 1.05.4 会把墙根与车底的接触阴影整体推离物体
	# 远看像物件浮在地面上.05 仍高于默认值，足以压住斜射太阳下的阴影痤疮
	_sun.shadow_bias = 0.035
	_sun.shadow_normal_bias = 1.05
	add_child(_sun)

	# 冷色天空填充光：把阴影面从死黑提回来，车体侧面的轮廓才读得出
	# 一盏不投影的平行光，开销可以忽略，所以它不随画质档位关闭
	# 低画质玩家同样需要看得见敌人
	_fill = DirectionalLight3D.new()
	_fill.rotation_degrees = Vector3(-62.0, 140.0, 0.0)
	_fill.light_energy = 0.3
	_fill.light_color = Color(0.55, 0.68, 0.95)
	_fill.shadow_enabled = false
	add_child(_fill)

	_apply_terrain_env()


## 把当前地形的色调写进天空、太阳、雾与地面材
## 只改颜色与强度，不碰任何几何或玩法参数，所以换地形不会影响判定## 具体开哪些后处理仍_apply_quality 的档位决
func _apply_terrain_env() -> void:
	var t: Dictionary = TERRAINS[terrain]
	var sky_lum: float = (
			float((t["sky_top"] as Color).get_luminance()) * 0.2
			+ float((t["sky_hor"] as Color).get_luminance()) * 0.5
			+ float((t["gnd_hor"] as Color).get_luminance()) * 0.3)
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("sky_top_color", t["sky_top"])
		_sky_mat.set_shader_parameter("sky_horizon_color", t["sky_hor"])
		_sky_mat.set_shader_parameter("ground_bottom_color", t["gnd_bot"])
		_sky_mat.set_shader_parameter("ground_horizon_color", t["gnd_hor"])
		# 夜空才有星。阈值取 0.14：白天图最高的地平亮度都在 0.4 以上
		# 夜战图的天空亮度只有 0.1 左右，这条线不会误伤黄昏
		_sky_mat.set_shader_parameter("star_amount", clampf((0.14 - sky_lum) * 9.0, 0.0, 1.0))
		_sky_mat.set_shader_parameter("cloud_amount", _cloud_cover())
		# 夜里的主光是月亮：盘面更大、更暗；白天是硬而小的太阳盘
		var night := sky_lum < 0.14
		_sky_mat.set_shader_parameter("sun_size", 0.030 if night else 0.014)
		_sky_mat.set_shader_parameter("sun_disk_energy", 0.85 if night else 1.5)
	if _env != null:
		# 环境光整体收 14%：原0.88~1.30 的天空光把暗部抬到与受光面接近，
		# 墙根、车底与炮塔侧面全被压平成同一档亮度，画面因此没有体积
		# 压缩之后仍留足量天空成分（敌车可读性由涂装RIM/EMISSION 兜底
		# 验收tools/vis_probe.gd enemyLum
		_env.ambient_light_energy = float(t["ambient"]) * 0.80
		# 天空当环境光源时，ambient_light_energy 乘的是天空颜色而不是光量，
		# 所以夜图这种天空接近黑的地形，系数填多少都等于没填
		# 这里按天空亮度缺多少就掺多少显式环境色，给环境光一个与色调无关的底
		var fill_share := clampf(1.0 - sky_lum / AMBIENT_SKY_REF, 0.0, AMBIENT_FILL_MAX)
		_env.ambient_light_sky_contribution = 1.0 - fill_share
		# 补的天上散下来的，所以取补光色往白里提一点，而不是直接用白光
		_env.ambient_light_color = (t["fill"] as Color).lerp(Color(1, 1, 1), 0.35)
		_env.fog_light_color = t["fog"]
		_env.fog_density = t["fog_density"]
		_env.volumetric_fog_albedo = (t["fog"] as Color).lightened(0.15)
		_env.volumetric_fog_density = clampf(float(t["fog_density"]) * 3.4, 0.006, 0.03)
		_apply_grading()
		_apply_exposure()
	if _sun != null:
		_sun.light_color = t["sun"]
		_sun.light_energy = t["sun_energy"]
		# 太阳高度角封44°。正午顶光只会照亮墙顶与车顶，把立面压成暗块
		# 整张图因此失去体积；压到 44° 以下，墙的立面、车身侧面才吃得到光
		var sun_rot: Vector3 = t["sun_rot"]
		sun_rot.x = maxf(sun_rot.x, -44.0)
		_sun.rotation_degrees = sun_rot
	if _fill != null:
		_fill.light_color = t["fill"]
		# 补光强度与阳*实际光量**反向（强× 颜色亮度，不是强度本身）
		# 偏暖偏冷的太阳颜色亮度能差三成，只看 sun_energy 会把橙色低阳的图
		# 误判阳光很足"，于是该补的光没补上，暗图上的坦克只剩一团黑
		var sun_power := float(t["sun_energy"]) * float((t["sun"] as Color).get_luminance())
		_fill.light_energy = lerpf(0.62, 0.30, clampf(sun_power / 1.3, 0.0, 1.0))
	if _ground_mi != null:
		_ground_mi.material_override = _soil_material(terrain)
	_berm_tint()
	_cliff_tint()


## 云量按地形给：沙暴与雪原最厚，夜战最薄（要留出星空）
func _cloud_cover() -> float:
	match terrain_name():
		"沙漠风暴":
			return 0.62
		"雪原哨所":
			return 0.58
		"工业港区":
			return 0.44
		"丛林小径":
			return 0.36
		"熔岩弹坑":
			return 0.30
		"夜战市区":
			return 0.16
		_:
			return 0.34


## 每张地形一套分级。以前十二张图共1.08 / 1.06 一组值，
## 于是"夜战"沙漠"只是换了天空颜色，整体反差与饱和度完全一
## 这里只调三个最稳的旋钮：饱和度、对比度、亮
## 夜战降饱和提对比（冷、硬），丛林提饱和（湿绿），雪原降饱和（避免蓝得发假
func _apply_grading() -> void:
	if _env == null:
		return
	var sat := 1.06
	var con := 1.12
	var bri := 1.0
	match terrain_name():
		"夜战市区":
			sat = 0.90
			con = 1.14
			bri = 0.98
		"熔岩弹坑":
			sat = 1.16
			con = 1.14
		"沙漠风暴":
			sat = 0.94
			con = 1.05
		"丛林小径":
			sat = 1.12
			con = 1.06
		"雪原哨所":
			sat = 0.86
			con = 1.03
		"工业港区":
			sat = 0.92
			con = 1.10
		"废墟城区":
			sat = 1.02
			con = 1.10
	_env.adjustment_saturation = sat
	_env.adjustment_contrast = con
	_env.adjustment_brightness = bri


## 曝光 = 玩家的亮度设× 该地形的曝光补偿##
## 补偿是必要的：ACES 曲线在低光端压得很狠，夜战与熔岩这类图把太阳和地面色
## 一起压暗之后，画面落在曲线最平的那一段，再怎么调环境光也只是把黑抬成深
## 曝光补偿作用在色调映射之前，等于"给这张图换一档快，整体提亮而不改相对对比，
## 所以暗图仍然比亮图暗，只是不再暗到看不见车
func _apply_exposure() -> void:
	if _env == null:
		return
	var t: Dictionary = TERRAINS[clampi(terrain, 0, TERRAINS.size() - 1)]
	_env.tonemap_exposure = Settings.brightness * float(t.get("exposure", 1.0))


## 画质档位：低档只留雾与阴影，中档SSAO + 体积雾，高档再开 SSIL SDFGI
func _apply_quality(level: int) -> void:
	if _env == null:
		return
	var mid := level >= Settings.Quality.MEDIUM
	var high := level >= Settings.Quality.HIGH

	_env.ssao_enabled = mid
	_env.ssil_enabled = high
	# SDFGI
	# 96 m 见方的平坦战场上只会帮倒忙：它的级联是规则的正方形格子
	# 铺在整片地面上就是一张随镜头移动的棋盘，近处尤其明显（实
	# tools/shots/vis 的港
	# 夜战图，地面被切
	# 1 m 左右的方块）
	# 这张图的 GI 需求本来就低——天
	# + 一盏平行光 + 雾，关掉之后
	# 墙根与车底的接触阴影
	# SSAO 负责，画面反而更干净，也省下 1~2 ms
	_env.sdfgi_enabled = false
	_env.fog_enabled = true
	_env.volumetric_fog_enabled = mid
	_env.glow_enabled = mid
	_env.adjustment_enabled = mid
	# 曝光不归画质管：它是可读性的总开关，低画质下同样要生
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
