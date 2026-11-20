# 09 · 交付状态与验证台账

本文记录 **截至 2026-11-19** 的实际交付状态：每份设计文档（`00`~`07`）的条目落在哪个函数、
用什么验证、结果如何，以及仍在跟踪的缺口。`08_roguelite_implementation.md` 是本月早些时候的实现记录，
其中的行数、探针结果与"已知问题"已经过时；两者冲突时以本文为准。

验证环境：Godot 4.7.2 stable（`D:\DevSoftware\godot\godot.exe`），全部命令无头运行。

---

## 1. 结论

| 项 | 状态 |
| --- | --- |
| `00`~`07` 设计条目 | 全部落地，逐条对照见第 3 节 |
| 数据层（卡表 / 公式 / 词缀 / 修正 / 元进度 / 存档） | 58 项探针全过 |
| 整局流程（9 关循环 → 三选一 → 补给站 → 通关 / 失败结算） | 58 项探针全过 |
| 既有回归（冒烟 / 点击 / 穿墙 / 残骸 / 暂停） | 全过 |
| 联机（双进程：Run 行、offer、只读界面、选卡、补给站、撤退） | 房主 31 / 客户端 32 项全 PASS |
| 本次修复的阻塞缺陷 | 见第 4 节第 1 条 |
| 本轮补齐的文档差距 | 敌方跳弹阈值按车型分化，见第 4 节 4.4 |

---

## 2. 本轮改动

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `scripts/main.gd` `_start_stage()` | 房主/单机开局时把 `Run.stage` 同步成 `stage` | 见第 4 节第 1 条 |
| `tools/run_flow_probe.gd` | `reward.hud` 改为断言"第 2 关 坚守" | 旧断言在关卡推进正确时必然失败 |
| `tools/RunFlowProbe.tscn` / `tools/run_flow_probe.gd` | 新增整局流程探针 | `06` 文档要求覆盖"开局→三选一→补给站→下一关" |
| `scripts/enemy.gd` | 新增 `ENEMY_RICOCHET` 表，`configure()` 末尾按 `etype` 赋值 `ricochet_angle` | 见第 4 节 4.4 |
| `tools/run_probe.gd` | 新增 `ricochet.enemy_types`（探针由 57 项增至 58 项） | 同上 |
| `docs/design/04`、`07`、`10`、`README.md` | 补齐敌方阈值表，删除"敌我统一 45°"的旧说明 | 同上 |
| `docs/design/09_delivery_status.md` | 新增本文 | 交付台账 |

`08` 文档记录的所有功能代码在此之前已落地并通过 `RunProbe`；本月初**从未跑过整局流程探针**，
因此 `Run.stage` 不同步这个阻塞缺陷一直隐藏着（数据层探针手工写 `Run.stage`，看不到它）。

---

## 3. 设计条目对照

### 3.1 局结构（`01_run_structure.md`）

| 条目 | 实现 | 验证 |
| --- | --- | --- |
| 9 关 = 3 战区 × 3 关 | `RunState.TOTAL_STAGES`、`main.MAX_STAGE = 9` | `RunProbe stages.kinds / stages.zones` |
| 类型固定 歼灭 → 坚守 → 决战 | `RunState.stage_kind()` | `RunProbe stages.kinds`、`FlowProbe boss.kind` |
| 关卡号同步 | `_start_stage()` 写 `Run.stage` | `FlowProbe reward.advanced / hold.kind / boss.kind / station.advance` |
| 坚守：倒计时 + 持续补波 + 归零撤退 | `main.hold_left`、`_build_hold_wave()`、`_hold_complete()`、`HUD._hold_l` | `FlowProbe hold.timer`、`hold.clear` |
| 坚守时长 `45 + stage×3`，blitz ×0.8 | `RunState.hold_seconds()` | `RunProbe stages.hold`（51.0 / 40.8） |
| 决战：Boss 压轴，第 3 关 ×1.15 HP/×0.9 装填，第 9 关 ×1.35 HP | `main._apply_run_enemy_scale()` | `FlowProbe boss.kind`、`RunProbe affix.boss_min` |
| 战区 HP/伤害倍率 | `RunState.zone_hp_mult()` / `zone_damage_mult()` | 代码审查（探针不单独断言，公式在 `RunProbe stages` 覆盖） |
| 投放比例按关卡解锁 | `main._roll_enemy_type()` | `FlowProbe` 全流程无异常 |
| 敌人总数 `min(26, 9+stage×2)×horde` | `RunState.enemy_budget()` | `RunProbe stages.horde` |
| 三档难度只改手感与乘数 | `Player.apply_difficulty()`（既有） | 既有 `SmokeRun` |
| 联机：房主权威 + 客户端跟随 | `main.net_collect_snapshot()` 的 `run` 行、`net_begin_stage` | `RunProbe net.run_row`；双进程见第 5 节 |

### 3.2 卡牌（`02_cards.md`）

| 条目 | 实现 | 验证 |
| --- | --- | --- |
| 30 张卡、3 档稀有度、上限 | `UpgradeCards.CARDS` | `RunProbe cards.*`（8 项） |
| 三选一：不重复 / 满级不进池 / 第 2 关保底 / 池空返回空 | `UpgradeCards.roll_offer()` | `RunProbe offers.*`（5 项） |
| 重掷价格 `40 + 20×floor(卡数/3)`、情报网折扣 | `RunState.reroll_price()` | `RunProbe economy.reroll_price0/3` |
| 跳过 +30（不乘系数） | `RunState.skip_offer()` | `RunProbe economy.skip` |
| `reload` 连乘钳到 0.35 | `RunState.recompute()` | 代码审查 |
| 每张卡都有代价，名 2–4 字 | 卡表 | `RunProbe cards.names` |
| 界面：←→ 选择、Enter 确认、R 重掷、Esc 跳过、鼠标 | `RunUI`、`main._unhandled_input` 的 `reward` 分支 | `FlowProbe clear.reward / reward.card` |

### 3.3 经济与元进度（`03_economy_and_meta.md`）

| 条目 | 实现 | 验证 |
| --- | --- | --- |
| 关卡奖励 `30 + stage×8` | `RunState.award_stage()` | `RunProbe economy.stage_reward`（38 / 70） |
| 击杀奖励 `[2,3,5,6,15]` | `RunState.award_kill()` | `RunProbe economy.kill_reward` |
| 战功系数（勋章 / 回收 / blitz） | `RunState.credit_mult()` | `RunProbe economy.credit_mult` |
| 补给站三件商品、价格固定、备用车体可反复买（每人 5 命） | `main.STATION_ITEMS`、`_on_station_buy()`、`_min_player_lives()` | `FlowProbe station.*` |
| 补给站只在第 3/6 关后出现 | `main._after_reward()` + `RunState.is_zone_end()` | `FlowProbe station.open` |
| 转化 100% / 50% / 每日 ×1.1 | `RunState.finish()` | `RunProbe meta.payout`（50/100/110） |
| 战车解锁价 350/650/700/800，游隼免费 | `MetaProgress.TANK_COST` | `RunProbe meta.unlock` |
| 3 项永久升级与价格 | `MetaProgress.UPGRADES` | `RunProbe meta.upgrade / start_bonus / bonuses` |
| `meta.cfg` 格式、坏档回落 | `MetaProgress.load_cfg()` / `_sanitize()` / `save_cfg()` | `RunProbe meta.save / meta.sanitize` |
| 结算页 Run 段落 | `main._run_result_lines()` | 代码审查 + `FlowProbe` 结算路径 |

### 3.4 战斗规则（`04_combat_rules.md`）

| 条目 | 实现 | 验证 |
| --- | --- | --- |
| 确定性跳弹：AP + 正面 + 角 > 阈值 | `Tank.take_hit()`、`Tank.ricochet_angle` | `RunProbe ricochet.*`（6 项） |
| 敌方阈值按车型 38°~52° | `Enemy.ENEMY_RICOCHET`（configure 时赋值） | `RunProbe ricochet.enemy_types` |
| 准星提示与结算共用阈值 | `Tank.is_ricochet_angle()` | `RunProbe ricochet.hint_matches` |
| 卡牌降阈值，钳到 24° | `Tank.apply_run_mods()` | `RunProbe ricochet.card_threshold` |
| 结算顺序：护盾 → 分区 → 跳弹 → 附加装甲 → 卡牌 armor → 敌方系数 | `Tank.take_hit()` | `RunProbe affix.damage_taken` |
| 吸血 | `Tank.on_damage_dealt()` → `main.on_player_damage_dealt()` | 代码审查（`RunProbe mods.*` 覆盖数值） |
| 殉爆 / 易爆 | `main._kill_explode()` / `_volatile_burst()` | 代码审查 |
| 出生护盾 / 关卡回血 / 多弹 / 连击窗口 / 冷却 | `_spawn_player()`、`_start_stage()`、`Net._spawn_shot_bundle()`、`on_tank_destroyed()`、`Player.apply_run_mods()` | `RunProbe mods.idempotent`、`ClickProbe`（多弹不回归） |
| 5 种词缀、数量按关卡、Boss 保底、唯一、上限 3、精英 +1 | `EnemyAffix.roll()` / `apply()` | `RunProbe affix.*`（7 项） |
| 词缀表现（车底环 + 名条） | `EnemyAffix.apply_visuals()` | 代码审查；联机见 `net_spawn_enemy` |
| 6 条 Run 修正 | `Mutators.DEFS` | `RunProbe mutators.*`（4 项） |

### 3.5 界面与联机（`05_ui_and_net.md`）

| 条目 | 实现 | 验证 |
| --- | --- | --- |
| 状态机 `clear → reward → (station) → ready` | `main._on_clear_timeout()`、`_after_reward()`、`_advance_stage()` | `FlowProbe` 全流程 |
| `reward` / `station` 是冻结不是暂停 | 不触碰 `get_tree().paused`；敌人 `state != "play"` 自停 | `FlowProbe` 冻结期间无推进 |
| 卡牌界面布局与输入 | `RunUI.show_cards()` + `main` 输入路由 | `FlowProbe clear.reward` |
| 补给站界面三态：购买 / 已购 / 战功不足 / 已达上限 | `RunUI` 的 `sold / enabled / maxed` | `FlowProbe station.card / station.spend` |
| 战斗 HUD 状态条 + 坚守倒计时 | `HUD._run_l`、`HUD._hold_l` | `FlowProbe reward.hud`、`hold.timer` |
| 结算页 Run 段落 | `_run_result_lines()` | 代码审查 |
| 车库：挑战行、U 解锁、1/2/3 升级、补给券余额 | `_refresh_select()`、`_unlock_selected_tank()`、`_buy_upgrade()` | 代码审查；闸门只在 `select/over/win` 生效（`_confirm_start`） |
| 联机：`run` 行快照、`net_run_offer` / `net_run_event`、客户端只读界面 | `main.net_*` + `Net.broadcast_run_*` | `RunProbe net.run_row`；双进程见第 5 节 |
| 大厅"关卡"行改"挑战" | `NetLobby` | 代码审查 |

### 3.6 技术与验收（`06_tech_and_acceptance.md`）

| 条目 | 状态 |
| --- | --- |
| 新逻辑独立文件（6 个脚本） | 已落地 |
| `Tank.apply_run_mods()` 唯一入口、幂等、在名册与难度之后调用 | 已落地（`_spawn_player` 顺序为 `_ready` → `apply_difficulty` → `apply_run_mods`） |
| Run 级随机不使用全局 `randf()` | 已落地（`Run.rng`；`_roll_enemy_type` 走 `Run.rng`） |
| `Meta` / `Run` autoload | `project.godot` 已注册 |
| 无头自检 `--quit-after 240` | 退出码 0（第 5 节） |
| `RunProbe` 全项 | 58/58 OK |
| 回归探针 `SmokeRun / ClickProbe / CombatProbe / WreckProbe / PauseProbe` | 全过 |
| 手动验收清单 1–6 | 由 `FlowProbe` 自动覆盖 1–4；5–6 见第 5 节 |

---

## 4. 已知缺陷与修复记录

### 4.1 已修复：`Run.stage` 从不推进（阻塞）

- **现象**：整局永远停在第 1 关。第 1 关肃清、选卡之后 `main.stage` 变成 2，但 `Run.stage` 仍是 1，
  于是第 2 关的类型被判成歼灭、战区永远是 1、`is_zone_end()` 永不成立（补给站永不出现），
  结算页也永远显示"第 1 关"。卡池保底与敌人预算同样按第 1 关算。
- **根因**：`main.stage` 与 `Run.stage` 是两个独立的计数器，`Run.stage` 只在 `Run.begin_run()` 时写过一次。
- **修复**：`main._start_stage()` 在房主/单机开局时写 `Run.stage = stage`；客户端继续从 `run` 行应用。
- **验证**：`RunFlowProbe` 的 58 项检查（改动前 9 项 FAIL，改动后全过）。

### 4.2 已修复：`RunProbe` 之外的探针不覆盖整局流程

`RunProbe` 的所有状态断言都手工给 `Run.stage` 赋值，因此看不到 4.1 这种"两个计数器不同步"的问题。
新增 `RunFlowProbe` 走真实状态机（`_confirm_start` → 肃清 → 三选一 → 坚守 → Boss → 补给站 → 第 4~9 关 → 通关结算 → 失败结算）。

### 4.3 已修复：`FlowProbe` 自身的旧断言

`reward.hud` 原本断言"第 1 关"，在关卡推进修正正确后必然失败；改为断言"第 2 关 坚守"。

### 4.4 本轮补齐：敌方跳弹阈值按车型分化

`04` §1.2 与 `10` §6.1 写的是"敌人按类型 38°~52°"，此前实现里敌我统一 45°。
本轮在 `enemy.gd` 增加 `ENEMY_RICOCHET` 常量表并在 `configure()` 末尾赋值：
侦察 52° / 中型 46° / 重型 38° / 火炮 50° / Boss 40°。阈值越低正面越硬，
重型与 Boss 的正面甩炮现在会被弹开；客户端复制品走同一个 `configure()`，两端一致。
`RunProbe` 增加 `ricochet.enemy_types`（范围、单调性、39° 入射在重型必跳 / 侦察必穿）。

### 4.5 跟踪中：文档与实现的文字差异

| # | 位置 | 差异 | 处理 |
| --- | --- | --- | --- |
| 1 | `03` §1 | 文档称战功"随 Run 结束清空"，实现保留 `Run.credits` 供结算页显示 | 结算页要显示"战功 → 补给券"；`begin_run()` 会重置 |
| 2 | `03` §4.3 | `last_daily` 未写入 | 当前没有"每日只能打一次"的规则，不写空字段（同 `08` §4 第 7 条） |
| 3 | `08` 全文行数 / 已知问题 | 已过时（`PauseProbe` 已被适配通过） | 以本文为准 |
| 4 | 词缀"神射"文档写"反应 −0.15 s" | 实现为 `react_bonus = 0.15`（同上） | 一致，只是表述不同 |
| 5 | 探针并发运行 | 同时启动两个 Godot 实例会共用 `.godot` 脚本缓存：一个实例正在刷新缓存时，另一个可能读到半成品，表现为 `net.gd` 编译失败、`testValid=false` | 探针必须串行跑（`RunProbe` / `CombatProbe` 各占一个进程时尤其明显）；单独复跑全部通过，登记为使用约束而非缺陷 |

---

## 5. 复验命令

```powershell
$G = "D:\DevSoftware\godot\godot.exe"
& $G --headless --path . --quit-after 240              # 退出码 0
& $G --headless --path . res://tools/RunProbe.tscn     # PROBE RUN OK (58)
& $G --headless --path . res://tools/RunFlowProbe.tscn # FLOW VERDICT OK (58)
& $G --headless --path . res://tools/SmokeRun.tscn
& $G --headless --path . res://tools/ClickProbe.tscn   # fail=0 / 75
& $G --headless --path . res://tools/CombatProbe.tscn  # noClip && noDeadlock && testValid
& $G --headless --path . res://tools/WreckProbe.tscn   # lifecycle=true rescue=true
& $G --headless --path . res://tools/PauseProbe.tscn   # pauseOk=true
```

联机（双进程，需本机可 bind 端口）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\net_probe.ps1 -Godot "D:\DevSoftware\godot\godot.exe"
```

探针覆盖：握手、名册、双车生成、客户端位移、开火往返、拆墙、敌车死亡、断线清理，
以及 Run 行同步（关卡 / 难度 / 挑战 / 修正）、三选一同组 offer、客户端只读卡片界面、
房主选卡后两端 `mods` 一致、补给站购买同步、坚守撤退。实测房主 31 项、客户端 32 项全 PASS。

### 5.1 本轮复验记录（2026-11-19）

| 命令 | 结果 |
| --- | --- |
| `RunProbe.tscn` | `PROBE RUN OK (58)`，含新增 `ricochet.enemy_types`，无脚本错误 |
| `RunFlowProbe.tscn` | `FLOW VERDICT OK (58)` |
| `SmokeRun.tscn` | `state=play enemies=0`，退出码 0 |
| `ClickProbe.tscn` | `VERDICT fail=0 / 75 OK` |
| `CombatProbe.tscn` | `noClip=true noDeadlock=true testValid=true` |
| `WreckProbe.tscn` | `lifecycle=true rescue=true` |
| `PauseProbe.tscn` | `pauseOk=true` |
| `net_probe.ps1`（双进程） | `PROBE ALL PASS`，房主 31 / 客户端 32 项 |
| `--quit-after 240` | 退出码 0 |

`CombatProbe` 在一次"后台串跑全套 + 同时另开 `RunProbe`"时出现 `net.gd` 编译失败导致
`testValid=false`：两个 Godot 实例共用 `.godot` 脚本缓存会互相干扰。串行复跑全部通过，
因此复验时**同一时间只跑一个 Godot 进程**（见 `§4.5` 第 5 条）。

---

## 6. 后续工作建议

1. **`main.gd` 拆分**：已 2690 行；下次重构优先把"关卡流程 / 联机转发 / 菜单"三段拆出去。
2. **卡牌与词缀的可读性打磨**：目前只有车底环 + 名条，可考虑受击时闪一下对应颜色。
3. **敌方阈值的手感复验**：38°（重型）与 40°（Boss）让正面甩炮必然跳弹，
   需要用实际对局确认"逼玩家绕侧面"没有变成"正面完全打不动"。平衡基线见 `04` §6。