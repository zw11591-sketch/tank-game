# 07 · 实现规格与验收对照

本文是 [`00_overview.md`](00_overview.md)～[`06_tech_and_acceptance.md`](06_tech_and_acceptance.md)
的**落地版**：前六份文档回答"为什么这样设计"，本文回答"代码里到底长什么样、每个数从哪里来、
哪条验收由哪个探针覆盖"。改动代码前先读本文的"数据契约"和"不变量"，改完后同步更新本文的
"验收矩阵"。

版本：v1.0（2026-11）

---

## 1. 模块与文件

| 文件 | 类型 | 职责 | 不变量 |
| --- | --- | --- | --- |
| `scripts/upgrade_cards.gd` | 静态类 `UpgradeCards` | 30 张卡的数据、稀有度权重、抽卡、累加 | 纯函数，不碰场景树与全局 RNG |
| `scripts/run_state.gd` | autoload `Run` | 单局状态与全部公式 | 不引用节点；可整体序列化成 `net_row()` |
| `scripts/meta_progress.gd` | autoload `Meta` | 补给券、解锁、永久升级、生涯记录 | 读写 `user://meta.cfg`，坏档回落默认值 |
| `scripts/mutators.gd` | 静态类 `Mutators` | 6 条 Run 级修正与挑战生成 | 只改敌人与计时，不改玩家数值 |
| `scripts/enemy_affix.gd` | 静态类 `EnemyAffix` | 5 种词缀的掷取、数值、表现 | 数值在 `Enemy.configure()` 之后乘，互不覆盖 |
| `scripts/run_ui.gd` | `Control` 覆盖层 | 三选一与补给站的显示与输入 | 只发信号，不改 Rule 状态 |
| `scripts/main.gd` | 协调器 | 状态机、投放、结算、联机转发 | 新增逻辑只做"调用与状态切换" |

修改点：

| 文件 | 改动点 |
| --- | --- |
| `scripts/tank.gd` | `ricochet_angle` / `extra_shells` / `apply_run_mods()` / 确定性跳弹 / `on_damage_dealt()` |
| `scripts/player.gd` | 极速、转向、冷却从名册基线重算 |
| `scripts/enemy.gd` | `affixes` / `volatile_bomb` / `aim_spread_mult` / `react_bonus` / `damage_scale` |
| `scripts/shell.gd` | 命中与溅射后回调 `on_damage_dealt()` |
| `scripts/net.gd` | 多弹数读 `extra_shells`；`net_run_offer` / `net_run_event` 转发 |
| `scripts/hud.gd` | Run 状态条与坚守倒计时 |
| `project.godot` | autoload `Meta`、`Run` |

---

## 2. 数据契约

### 2.1 `RunState` 字段

| 字段 | 类型 | 写入方 | 说明 |
| --- | --- | --- | --- |
| `active` | bool | 房主 `begin_run` / `finish` | 客户端跟随 `net_row` |
| `won` | bool | `finish` | 结算用 |
| `stage` | int 1–9 | 房主推进 | 客户端跟随 |
| `zone` | 派生 | `zone_index()` | `(stage-1)/3` |
| `kind` | 派生 | `stage_kind()` | `[CLEAR, HOLD, BOSS]` 循环 |
| `credits` | int | 房主 | 客户端只读跟随 |
| `cards` / `counts` | Array / Dict | 房主 | `counts[id]` = 已叠层数 |
| `mods` | Dict | `recompute()` | 唯一写入点 |
| `flags` | Dict | `recompute()` | `kill_explode` |
| `offer` | Array[String] | 房主抽卡 | 客户端也保存，用于断线兜底 |
| `rerolls` | int | 房主 | 只做统计与同步 |
| `mutators` | Array[String] | `begin_run` | 挑战修正 |
| `rng` | RNG | `begin_run` | 卡池 / 词缀 / 补给站共用 |
| `mods_version` | int | `recompute()` | 客户端避免 25 Hz 重算 |
| `final_credits` / `final_payout` | int | `finish()` | 结算页显示 |

`mods` 的键与默认值：

```
乘性（默认 1.0）：damage reload hp armor speed turn turret he splash credits combo_window
加性（默认 0.0）：ricochet lifesteal cdr spawn_shield shells stage_heal lives
标记：kill_explode
```

**不变量**

1. 只有 `RunState.recompute()` 能写 `mods`；任何卡牌效果都必须进 `UpgradeCards.accumulate()`。
2. `reload` 连乘后钳到 `>= 0.35`，防止"点击必出弹"退化成机枪。
3. `ricochet` 的最终值由车辆钳到 `[24°, 基线]`，卡牌只提供"往下拉多少度"。
4. `apply_run_mods()` 幂等：基线存在 `Tank._base_tank` / `Player._roster_*`，重复调用不叠加。
5. `apply_run_mods(..., heal=true)` 只在落车时用；对局中途重算按血量比例回填。

### 2.2 卡牌表

每张卡：

```gdscript
"id": {
    "name": String,      # 2–4 字
    "rarity": int,       # 0 常规 / 1 稀有 / 2 史诗
    "max": int,          # 1..3
    "desc": String,      # 一句话，数值用阿拉伯数字
    "mods": Dictionary,  # 键必须在 MUL_KEYS / ADD_KEYS 内
    "flags": Array,      # 可选，键必须在 FLAG_KEYS 内
}
```

抽卡算法（`UpgradeCards.roll_offer`）：

```
候选 = { id | counts[id] < max }
循环至多 3 次：
    在候选中按 rarity_weight(rarity, stage, diff) 加权抽 1 张
    抽中即从候选移除，保证本批不重复
若 stage >= 2 且三张均为常规且候选仍有稀有/史诗：
    第三张替换为加权抽到的稀有/史诗
```

`rarity_weight`：`[60, 30, 10]`，史诗在每深入一个战区 +2，困难难度再 +5。
卡池耗尽时返回实际数量（可能为 0），调用方负责跳过界面。

### 2.3 `net_row()` / `apply_row()`

```gdscript
{
    "active": bool,
    "stage": int,
    "kind": int,           # 由 stage 派生，客户端不直接采信
    "credits": int,
    "cards": Array[String],
    "offer": Array[String],
    "rerolls": int,
    "mutators": Array[String],
    "diff": int,
    "challenge": int,
}
```

`apply_row()` 先做一次轻量签名比较（`active|stage|credits|rerolls|cards|offer|mutators|diff|challenge`），
内容没变直接返回。这是为了避免 25 Hz 快照每帧触发 `recompute()`，进而按比例回填血量。

**权威边界**

| 内容 | 权威 |
| --- | --- |
| 抽卡 / 重掷 / 选卡 / 购买 / 战功 / 结算 | 房主 |
| 玩家位置与朝向 | 客户端（房主校验） |
| 伤害 / 击毁 / 拆墙 / 掉落 / 命数 | 房主 |
| 特效 / 音效 / 界面 | 各自本地 |

### 2.4 `meta.cfg`

```ini
[meta]
credits=1250
runs=12
wins=3
best_stage=9
challenge_clears=1

[tanks]
rows={"lynx": true}

[upgrades]
rows={"lives": 1, "reroll": 2}
```

- 价格表是代码常量（`MetaProgress.TANK_COST` / `UPGRADES`），不写进存档。
- 读取时 `_sanitize()` 丢弃未知战车 / 未知升级键，等级钳到 `max`。
- `credits` 等标量一律 `maxi(0, ...)`，坏档不会出现负数余额。

### 2.5 词缀

```gdscript
"armored"  # 受伤 ×0.72，HP ×1.25，速度 ×0.90
"frenzied" # 装填 ×0.65，HP ×0.80
"volatile" # 死亡爆炸：6 m，40 + 8% 最大结构，只伤玩家
"shielded" # 出生 5 s 护盾
"marksman" # 散布 ×0.60，反应延迟 −0.15 s
```

`EnemyAffix.apply()` 只改乘数与标记；`EnemyAffix.apply_visuals()` 只挂表现（名条）。
两者分开，因为客户端要表现但不要重算经济。

### 2.6 修正

```gdscript
"iron_rain" # enemy_reload ×0.88
"horde"     # enemy_count  ×1.25
"hardened"  # enemy_dr     ×0.88
"elite"     # affix_bonus  +1
"veteran"   # enemy_damage ×1.12
"blitz"     # hold_time ×0.80，credit ×1.20
```

---

## 3. 状态机

```
title
 └─(出击)→ ready ─(2.6s)→ play ─(目标达成)→ clear ─(3.4s)→ reward
                                                          ├─(非战区末尾)→ advance → ready
                                                          └─(战区末尾)→ station → advance → ready
play ─(全员命尽 / 基地被毁)→ over
play ─(第 9 关达成)→ win
```

- `reward` / `station` 是**冻结**，不是暂停：不调用 `get_tree().paused`，否则联机快照会断。
- 冻结期间敌人 AI 因 `state != "play"` 停止；玩家 `controllable == false`，只做惯性衰减。
- 单元测试与探针通过 `_confirm_start()` 进入 `ready`；解锁闸门只在 `state == "select"` 时生效，
  否则 20 多个既有探针会因为没有补给券而集体失效。

---

## 4. 公式表

| 量 | 公式 | 位置 |
| --- | --- | --- |
| 关卡数 | 9 = 3 战区 × 3 关 | `RunState.TOTAL_STAGES` |
| 关卡类型 | `[歼灭, 坚守, 决战][(stage-1) % 3]` | `stage_kind()` |
| 坚守时长 | `(45 + stage×3) × hold_time` | `hold_seconds()` |
| 敌人总数 | `min(26, 9 + stage×2) × enemy_count` | `enemy_budget()` |
| 战区 HP | `[1.0, 1.15, 1.30]` | `zone_hp_mult()` |
| 战区伤害 | `[1.0, 1.08, 1.16]` | `zone_damage_mult()` |
| 关卡奖励 | `(30 + stage×8) × credits` | `award_stage()` |
| 击杀奖励 | `[2, 3, 5, 6, 15][etype] × credits` | `award_kill()` |
| 重掷价格 | `(40 + 20×floor(cards/3)) × reroll_mult` | `reroll_price()` |
| 跳过补偿 | `+30`（不乘任何系数） | `skip_offer()` |
| 命中伤害 | `round(基础 × 分区 × 附加装甲 × armor × 敌方受伤系数)` | `Tank.take_hit()` |
| 吸血 | `round(实伤 × lifesteal)`，至少 1 | `main.on_player_damage_dealt()` |
| 殉爆 | `60 + 0.35×max_hp`，6 m，只伤敌车 | `main._kill_explode()` |
| 易爆 | `40 + 0.08×max_hp`，6 m，只伤玩家 | `main._volatile_burst()` |
| 结算转化 | 胜利 100%，失败 50%，每日再 ×1.1 | `RunState.finish()` |
| 开局命数 | `3 + Meta.start_lives() + mods.lives` | `starting_lives()` |

---

## 5. 战斗规则

### 5.1 确定性跳弹

```
AP 弹 + 命中正面（入射角 < 55°）+ 入射角 > ricochet_angle
     → 零伤害，反馈 "跳弹"
```

- `ricochet_angle` 默认 45°；卡牌 `ricochet` 只向下拉，最终钳到 24°。
- 敌车在 `Enemy.configure()` 里按车型赋值：侦察 52° / 中型 46° / 重型 38° /
  火炮 50° / Boss 40°（表 `Enemy.ENEMY_RICOCHET`）；客户端复制品走同一个 `configure()`。
- `is_ricochet_angle()` 与 `take_hit()` 共用同一判据，准星提示不会撒谎。
- HE 永不跳弹。

### 5.2 结算顺序

```
1 护盾 → 2 分区 → 3 跳弹 → 4 附加装甲 → 5 卡牌 armor → 6 敌方受伤系数
→ 7 扣血 / 反馈 / 击毁 → 8 射手吸血
```

`armor` 卡牌必须乘在分区倍率之后、跳弹判定之后。顺序写在 `Tank.take_hit()` 注释里。

### 5.3 钩子

| 钩子 | 触发点 | 行为 |
| --- | --- | --- |
| 吸血 | `Tank.on_damage_dealt()` | 命中与溅射各回调一次，房主结算 |
| 殉爆 | `main.on_tank_destroyed()` | 只认**玩家**为射手，避免敌人互爆炸清场 |
| 出生护盾 | `main._spawn_player()` | `max(3.0, spawn_shield)` |
| 关卡回血 | `main._start_stage()` | 存活玩家回复 `max_hp × stage_heal` |
| 多弹 | `Net._spawn_shot_bundle()` | `extra_shells` 与限时 `multi_t` 取较大值 |
| 连击窗口 | `main.on_tank_destroyed()` | `COMBO_WINDOW × combo_window` |
| 冷却 | `Player.apply_run_mods()` | 名册基线 × `(1 − cdr)` |

---

## 6. 联机流程

```
房主                                        客户端
begin_run()                                 (等待)
_start_stage → broadcast_stage_start(run) →  net_begin_stage → apply_row → 落车
肃清 → roll_offer → broadcast_run_offer →   net_run_offer → 只读三选一
选卡 → broadcast_run_event("card") →        apply_pick + 重算 mods
战区末尾 → broadcast_run_event("station_open"/"station_buy")
下一关 → broadcast_run_event("advance") + broadcast_stage_start
结束 → broadcast_match_end →                本地 Run.finish() 结算自己的 meta.cfg
```

兜底：

- 快照每 25 Hz 带 `run` 行。可靠的界面事件若丢失，客户端从 `run.offer` 恢复"三选一还开着"。
- `apply_row()` 有签名去重，内容不变时不重算 mods。
- 坚守撤退由 `net_run_event("withdraw")` 通知客户端移除敌人，不走死亡流程（不计击杀）。

---

## 7. 验收矩阵

| 检查 | 探针 / 方法 | 判据 |
| --- | --- | --- |
| 卡表 30 张、id 唯一、键合法、上限 > 0 | `RunProbe cards.*` | 全 OK |
| 整局流程：9 关类型循环、三选一、补给站、通关 / 失败结算 | `RunFlowProbe` | 58/58 OK |
| 抽卡不重复、不超上限、第 2 关保底 | `RunProbe offers.*` | `short=dup=all_common=leaked=0` |
| mods 累加与钳制 | `RunProbe mods.*` | 与手算误差 < 1e-6 |
| 经济公式 | `RunProbe economy.*` | 38/70、[2,3,5,6,15]、40/60、+30 |
| 境界序列与坚守时长 | `RunProbe stages.*` | 0,1,2 ×3；51.0 / 40.8 |
| 词缀数量与数值 | `RunProbe affix.*` | 第 1 关 0；第 9 关 ≥1；Boss ≥2；唯一 |
| 修正 | `RunProbe mutators.*` | horde 1.25 / blitz 0.8；每日同种子同结果 |
| 元进度 | `RunProbe meta.*` | 解锁扣款、升级上限、转化 50/100/110 |
| 存档 | `RunProbe meta.save / sanitize` | 重载一致；坏键被丢弃 |
| 联机行 | `RunProbe net.run_row` | 往返一致；重复应用不重算 |
| 跳弹 | `RunProbe ricochet.*` | 44° 必穿、46° 必跳、50 次不变；敌方按车型 38°~52° |
| 出弹 | `ClickProbe` | 每次点击必出弹，按住 1 s 3–7 发 |
| 穿墙 / 卡死 | `CombatProbe` | `noClip && noDeadlock && testValid` |
| 冒烟 | `SmokeRun` | 开局→开火→击毁 |
| 残骸路径 | `WreckProbe` | 不封死通路 |
| 联机握手 | `NetProbe`（双进程） | 全 PASS |

---

## 8. 已知差异与处理

| 项 | 处理 |
| --- | --- |
| 卡牌名超过 4 字（旧文档） | 以代码为准，文档同步 |
| 补给站"战术档案无视上限" | 改为"不占三选一机会"，仍遵守叠加上限 |
| 联机命数写死 3 | 房主开局按 `Run.starting_lives()` 写入名册 |
| 客户端命数 / 挑战不同步 | `net_row` 增加 `diff` / `challenge` |
| 客户端敌人无词缀表现 | `net_spawn_enemy` 应用词缀数值与名条 |
| 双人时"备用车体"可被房主反复买 | 每名玩家独立上限 5，按名册最小命数判定 |
