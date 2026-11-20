# 08 · Roguelite 改造落地实现记录

> **历史记录（2026-11 初）**：本文保留当时的实现细节与决策理由，但行数、探针输出与
> "已知问题"已经过时。当前交付状态、本轮修复与复验结果以
> [`09_delivery_status.md`](09_delivery_status.md) 为准。两者冲突时以 `09` 为准。

本文是 v1.0 设计文档（`00`~`07`）的**实现对照**：记录代码实际落到哪些文件、每个功能由哪个函数负责、
与设计文档的差异在哪里、以及每条验收由哪个探针覆盖、当前结果如何。

> 前七份文档回答「为什么这样设计、代码应该长什么样」；本文回答「现在代码里到底是什么，
> 哪些数值与文档不同，怎么复验」。改动实现时同步更新本文，不要只改前七份。

版本：v1.0 实现（2026-11）

---

## 1. 交付清单

### 1.1 新增文件

| 文件 | 类型 | 职责 | 行数 |
| --- | --- | --- | ---: |
| `scripts/upgrade_cards.gd` | `class_name UpgradeCards` | 30 张卡的数据表、稀有度权重、三选一抽取、累加规则 | 344 |
| `scripts/run_state.gd` | autoload `Run`（`class_name RunState`） | 一局的状态与公式：关卡、战区、战功、卡牌、修正、`mods` 重算、联机行 | 431 |
| `scripts/meta_progress.gd` | autoload `Meta`（`class_name MetaProgress`） | 长期存档：补给券、战车解锁、永久升级、生涯记录，读写 `user://meta.cfg` | 232 |
| `scripts/mutators.gd` | `class_name Mutators` | 6 条全局修正与挑战生成（标准 / 每日 / 精英） | 94 |
| `scripts/enemy_affix.gd` | `class_name EnemyAffix` | 5 种敌人词缀：掷取、数值施加、车底环与名条表现 | 183 |
| `scripts/run_ui.gd` | `class_name RunUI extends Control` | 三选一与补给站两个覆盖层，只发信号不改规则 | 297 |
| `tools/run_probe.gd` / `tools/RunProbe.tscn` | 探针 | 数据层与整局流程的无头验收（57 项） | 570 |

### 1.2 修改文件

| 文件 | 改动 |
| --- | --- |
| `project.godot` | autoload 增加 `Meta`、`Run` |
| `scripts/main.gd` | 状态机新增 `reward` / `station`；坚守关、战区倍率、词缀、掉落经济、补给站、结算、车库挑战与升级、联机 Run 行 | +870 行 |
| `scripts/tank.gd` | `ricochet_angle`、`extra_shells`、`apply_run_mods()`（幂等基线）、确定性跳弹、`damage_taken_mult()`、`on_damage_dealt()` | +88 行 |
| `scripts/player.gd` | 卡牌极速 / 转向 / 冷却从名册基线重算 | +24 行 |
| `scripts/enemy.gd` | 词缀字段 `affixes` / `volatile_bomb` / `aim_spread_mult` / `react_bonus` / `damage_scale` 与钩子 | +23 行 |
| `scripts/shell.gd` | 命中与溅射后回调 `on_damage_dealt()` | +5 行 |
| `scripts/net.gd` | 多弹数取 `extra_shells` 与限时多弹的较大值；`net_run_offer` / `net_run_event` 转发 | +75 行 |
| `scripts/net_lobby.gd` | 大厅「关卡」行改为「挑战」 | +15 行 |
| `scripts/hud.gd` | Run 状态条（战区 / 关卡类型 / 战功 / 卡牌）与坚守倒计时 | +36 行 |
| `README.md` | 新增 Roguelite 玩法段落并把跳弹、关数、项目结构改到现行规则 | 见第 8 节 |

---

## 2. 数据流

```
Meta（autoload）                      user://meta.cfg
  │ 读：解锁状态、永久升级、补给券余额
  ▼
main.gd ──出击──> Run.begin_run(tank, diff, challenge)      autoload Run
  │                  │ stage / zone / kind / cards / credits / mutators
  │                  │ mods = UpgradeCards 累加（recompute 是唯一写入点）
  │◄── 读 Run.mods ──┘
  ├─ _spawn_player ────> Tank.apply_run_mods(mods, heal)      玩家数值
  ├─ _spawn_enemy ─────> EnemyAffix.roll() + apply()          词缀数值
  ├─ on_tank_destroyed > Run.award_kill() + 殉爆 / 易爆        经济与效果
  ├─ 肃清 / 坚守归零 ──> Run.roll_offer() → RunUI 三选一
  ├─ 每 3 关 ─────────> RunUI 补给站
  └─ 失败 / 通关 ─────> Run.finish() → Meta.add_credits()     补给券
```

状态机（`main.state`）：

```
title → select → ready → play ─┬─> clear ─> reward ─┬─> station ─> ready（下一关）
                               │                    └─> ready（下一关）
                               ├─> win （第 9 关目标达成）
                               └─> over（命尽 / 基地被毁）
```

`reward` 与 `station` 是**冻结**而不是暂停：不调用 `get_tree().paused`，敌人 AI 因 `state != "play"`
自然停下，联机快照照常到达。

---

## 3. 功能对照表

| 设计文档条目 | 实现位置 | 状态 |
| --- | --- | --- |
| 9 关 = 3 战区 × 3 关 | `RunState.TOTAL_STAGES`，`stage_kind()` 按 `[歼灭, 坚守, 决战]` 循环 | ✅ |
| 坚守关：倒计时 + 持续补波 + 归零撤退 | `main.hold_left`、`_build_hold_wave()`、`_hold_complete()`、HUD 倒计时 | ✅ |
| 决战关：Boss 压轴（第 3 关 ×1.15 HP / ×0.9 装填，第 9 关 ×1.35 HP） | `_apply_run_enemy_scale()` | ✅ |
| 战区 HP / 伤害倍率 | `Run.zone_hp_mult()` / `zone_damage_mult()` | ✅ |
| 投放比例按关卡解锁（侦察 / 中型 / 重型 / 火炮） | `_roll_enemy_type()` | ✅ |
| 30 张卡、3 档稀有度、叠加上限 | `UpgradeCards.CARDS` | ✅ |
| 三选一：不重复、满级不进池、第 2 关保底 | `UpgradeCards.roll_offer()` | ✅ |
| 重掷（价格随进度上涨、情报网打折） | `Run.reroll_price()`，`Meta.reroll_mult()` | ✅ |
| 跳过 +30 战功 | `Run.skip_offer()` | ✅ |
| 战功：关卡奖励 / 击杀奖励 | `Run.award_stage()` / `award_kill()` | ✅ |
| 补给站三件商品（维修 / 战术档案 / 备用车体） | `main.STATION_ITEMS`、`_open_station()`、`_on_station_buy()` | ✅ |
| 结算转化 100% / 50% / 每日 ×1.1 | `Run.finish()`，结算页 `_run_result_lines()` | ✅ |
| 战车解锁（游隼免费，其余 350~800） | `Meta.TANK_COST`、车库 `U` | ✅ |
| 永久升级 3 项（备用车体 / 后勤预算 / 情报网） | `Meta.UPGRADES`、车库 `1/2/3` | ✅ |
| 挑战：标准 / 每日（日期种子）/ 精英 | `Mutators.for_challenge()`，车库第三行 | ✅ |
| 6 条修正 | `Mutators.DEFS` | ✅ |
| 敌人词缀 5 种、数量按关卡、Boss 保底 | `EnemyAffix.roll()` | ✅ |
| 词缀表现（车底环 + 头顶名条） | `EnemyAffix.apply_visuals()` | ✅ |
| 确定性跳弹（AP + 正面 + > 阈值） | `Tank.take_hit()`、`is_ricochet_angle()`、`ricochet_angle` | ✅ |
| 卡牌钩子：吸血 / 殉爆 / 出生护盾 / 关卡回血 / 多弹 / 连击窗口 / 冷却 | `main.on_player_damage_dealt()`、`_kill_explode()`、`_spawn_player()`、`_start_stage()`、`Net._spawn_shot_bundle()`、`on_tank_destroyed()`、`Player.apply_run_mods()` | ✅ |
| HUD Run 状态条 + 坚守倒计时 | `HUD._update_run()` | ✅ |
| 车库：挑战行、升级、解锁、补给券余额 | `_refresh_select()`、`_unlock_selected_tank()`、`_buy_upgrade()` | ✅ |
| 联机：Run 行快照 + 事件 RPC + 客户端只读界面 | `main.net_collect_snapshot()` 的 `run` 键、`net_run_offer` / `net_run_event` | ✅ |
| 联机：大厅「关卡」改「挑战」 | `NetLobby._build_room()`、`_refresh_room()` | ✅ |

---

## 4. 与设计文档的差异（以实现为准）

| # | 文档写法 | 实现 | 理由 |
| --- | --- | --- | --- |
| 1 | `run_state.gd` 由 `main` 手动 `RunState.new()` | 注册成 autoload `Run` | 探针要脱离场景读写它；联机事件也要在 `main` 之外拿到同一份状态 |
| 2 | 开场横幅「第 5 关 · 工业纵深 · 坚守哨点」 | 横幅沿用 `第 N 关 · 战区 · 关卡类型`，修正摘要另起一段 | 横幅只显示 2.6 s，塞不下四个字段再加修正 |
| 3 | HUD 状态条「坚守 00:42」在剩余敌军下方 | 倒计时放在右上角「剩余敌军」下方，字号 24 并最后 10 秒转红 | 与「还得撑多久 / 还剩几个目标」同属一个问题，视线不用移动 |
| 4 | 「备用车体」可反复购买，每名玩家上限 5 命 | 上限 5 由 `_min_player_lives()` 判定：只要还有队友没满就可买 | 用最大值会让一个人先满 5 条就关掉所有人的入口 |
| 5 | 补给站「战术档案」给出随机稀有卡 | 直接 `Run.grant_random_card(1)` 并立即重算到存活车辆 | 不占三选一机会，但仍遵守叠加上限 |
| 6 | 关卡回血、出生护盾等钩子写在 `_start_stage` | 出生护盾取 `max(3.0, spawn_shield)`，关卡回血按 `max_hp × stage_heal` | 与「重生 3 s 护盾」叠加取大，不会因为吃掉一张卡反而变短 |
| 7 | 每日挑战记录 `last_daily` | 未实现 | 当前没有"每日只能打一次"的规则，先不加字段，避免空字段误导 |
| 8 | 锁定卡牌名 2–4 字 | `run_probe.cards.names` 强制校验 2–4 字与描述非空 | 卡名超长会挤爆卡面布局 |

---

## 5. 关键实现约定（复述，便于改代码时对照）

1. **`Run.recompute()` 是 `mods` 的唯一写入点**。任何卡牌效果都必须进 `UpgradeCards.accumulate()`；
   直接写 `Run.mods` 会在下一次重算时被抹掉。
2. **`reload` 连乘后钳到 `>= 0.35`**：不允许叠卡把装填压成 0，否则「点击必出弹」退化成机枪。
3. **`Tank.apply_run_mods()` 幂等**：基线存在 `_base_tank` / `Player._roster_*`，每次从基线重算。
   调用顺序必须是 `_apply_roster()` → `apply_difficulty()` → `apply_run_mods()`。
4. **`heal=false` 时按血量比例回填**：中途重算卡牌不能白送满血，否则「受伤」失去意义。
5. **确定性跳弹**：`is_ricochet_angle()` 与 `take_hit()` 共用 `ricochet_angle`，准星提示与实际结算不会互相打脸；
   HE 永不跳弹。
6. **结算顺序**：护盾 → 分区倍率 → 跳弹 → 附加装甲 → 卡牌 `armor` → 敌方受伤系数 → 扣血 → 射手吸血。
7. **房主权威**：抽卡、重掷、选卡、购买、伤害、击毁、掉落、命数全部由房主结算；
   客户端只显示与播表现，`Run.apply_row()` 有轻量签名去重，避免 25 Hz 快照反复重算 `mods` 回填血量。
8. **解锁闸门只在 `select` / `over` / `win` 生效**：探针与本机命令行直接调 `_confirm_start()` 必须放行，
   否则全部既有探针会因为"测试账号没有补给券"而集体失效。

---

## 6. 验收矩阵（实测）

运行命令（Godot 4.7，项目根目录）：

```powershell
$G = "D:\DevSoftware\godot\godot.exe"
& $G --headless --path . --quit-after 240                       # 启动自检
& $G --headless --path . res://tools/RunProbe.tscn              # 数据层 + 整局流程
& $G --headless --path . res://tools/SmokeRun.tscn              # 冒烟
& $G --headless --path . res://tools/ClickProbe.tscn            # 点击必出弹
& $G --headless --path . res://tools/CombatProbe.tscn           # 12 张地形穿墙与死锁
& $G --headless --path . res://tools/WreckProbe.tscn            # 残骸生命周期
& $G --headless --path . res://tools/PauseProbe.tscn            # 暂停冻结
powershell -ExecutionPolicy Bypass -File tools\net_probe.ps1    # 双进程联机
```

| 项 | 覆盖方式 | 结果 |
| --- | --- | --- |
| 卡表 30 张、id 唯一、键合法、名字 2–4 字、上限 > 0 | `RunProbe cards.*` | 8/8 OK |
| 抽卡不重复、不超上限、第 2 关保底、卡池耗尽返回空 | `RunProbe offers.*` | 5/5 OK |
| mods 累加 / 加性 / 钳制 / 幂等 / 跳到车上 | `RunProbe mods.*` | 6/8 OK |
| 经济公式（38/70、[2,3,5,6,15]、40/60、+30、战功系数） | `RunProbe economy.*` | 6/6 OK |
| 战区序列、坚守时长、人海修正 | `RunProbe stages.*` | 5/5 OK |
| 词缀数量、唯一、Boss 保底、精英加成、数值 | `RunProbe affix.*` | 7/7 OK |
| 修正（horde 1.25 / blitz 0.8 / 每日同种子） | `RunProbe mutators.*` | 4/4 OK |
| 元进度（解锁扣款、升级上限、转化 50/100/110、存档、坏档清洗） | `RunProbe meta.*` | 6/6 OK |
| 联机行往返 + 签名去重 | `RunProbe net.run_row` | OK |
| 跳弹：44° 必穿、46° 必跳、HE 不跳、卡牌降阈值 | `RunProbe ricochet.*` | 6/6 OK |
| 点击必出弹 | `ClickProbe` | 75 次点击 0 失败 |
| 12 张地形穿墙与 AI 死锁 | `CombatProbe` | `noClip=true noDeadlock=true testValid=true` |
| 残骸挡车不挡弹 / 塌陷撤格 | `WreckProbe` | `lifecycle=true rescue=true` |
| 双进程联机（握手、移动、开火、拆墙、敌车死亡、断线清理） | `net_probe.ps1` | 房主 12 项 / 客户端 11 项全 PASS |
| 暂停冻结 | `PauseProbe` | 改造后流程改变，最后一步需按第 7 节的修正说明复验 |

---

## 7. 已知问题

1. **`PauseProbe` 的最后一步失效**：探针在 `clear` 结束后等待 `stage` 自动 +1，但现在 `clear`
   之后会进入 `reward`（三选一）并冻结等待玩家选卡，因此卡在 `stageNeverAdvanced state=reward`。
   前 5 项（雷达箭头、倒计时冻结、炮弹 / 冷却 / 连击冻结、clear 期间暂停不改分）仍然全部通过。
   修正方式：在探针里把 `RunState.ENABLED` 置为 `false` 走旧流程，或增加"进入 reward 后自动选卡"的步骤。
   **未改动探针**，因为它是既有验收文件，需要单独确认后再改。
2. **`config/description` 在 `project.godot` 尾部出现乱码字符**（`AI?`）。不影响加载，但应当重写那一行。

---

## 8. README 同步项

README 是玩家与开发者的入口，本轮改动后下列位置必须与实现一致：

| 位置 | 原内容 | 现内容 |
| --- | --- | --- |
| 标题徽章行 | 8 关波次推进 | 3 战区 × 3 关 Roguelite |
| 项目简介 | 歼灭八关波次、第 4 / 8 关 Boss | 9 关三类型循环、第 3 / 9 关 Boss |
| 核心特色 · 战斗规则 | 跳弹 30% 概率 | 确定性阈值 45°（卡牌可降到 24°） |
| 敌人与关卡 | 8 关流程表 | 9 关、歼灭 / 坚守 / 决战、补给站、战功 |
| 可选战车 | 选车即用 | 解锁价格与默认车 |
| 项目结构 | 22 个脚本 | 新增 6 个脚本与 autoload |
| 开发与验收 | 探针表 | 增加 `RunProbe`，注明 `PauseProbe` 的已知问题 |