# 06 · 技术设计与验收

---

## 1. 文件划分

新增文件（全部放在 `scripts/`，与现有 `class_name` 约定一致）：

| 文件 | class_name | 职责 | 约行数 |
| --- | --- | --- | ---: |
| `scripts/upgrade_cards.gd` | `UpgradeCards` | 卡牌静态表、稀有度、抽卡算法（纯函数） | 260 |
| `scripts/run_state.gd` | `RunState` | 单局状态：关卡、卡牌、战功、修正、`mods` 重算 | 330 |
| `scripts/meta_progress.gd` | `MetaProgress` | 长期存档：补给券、解锁、永久升级（autoload `Meta`） | 200 |
| `scripts/mutators.gd` | `Mutators` | Run 级修正表与取值 | 110 |
| `scripts/enemy_affix.gd` | `EnemyAffix` | 敌人词缀表与施加逻辑 | 170 |
| `scripts/run_ui.gd` | `RunUI` | 三选一、补给站两个覆盖层 | 560 |

修改文件：

| 文件 | 改动 |
| --- | --- |
| `scripts/main.gd` | Run 生命周期、关卡类型、奖励、补给站、结算、挑战、车库行、联机行 |
| `scripts/tank.gd` | `ricochet_angle`、`extra_shells`、`card_mult` 应用、确定性跳弹、`on_damage_dealt` |
| `scripts/player.gd` | 卡牌速度/转向/冷却应用；`_base_*` 重算入口 |
| `scripts/enemy.gd` | 词缀字段与数值钩子 |
| `scripts/shell.gd` | 伤害回调（吸血）、多弹数改用 `extra_shells` |
| `scripts/net.gd` | Run 事件 RPC、多弹数改读 `extra_shells` |
| `scripts/hud.gd` | 战区/关卡类型/战功/卡牌/坚守倒计时 |
| `scripts/project.godot` | 注册 `Meta` autoload |
| `README.md` | 新玩法段落与验收探针 |

**为什么不继续往 main.gd / arena.gd 里写**：两者当前已分别是 2690 / 4844 行。
本次所有新逻辑都进独立文件，`main.gd` 只做"调用与状态切换"。

---

## 2. 类职责与数据流

```
Meta (autoload)        永久存档
   │ 读：解锁、升级、补给券
   ▼
main.gd  ──开始一局──>  RunState.begin(tank, diff, challenge)
   │                        │ 持有：stage / zone / kind / cards / credits / rerolls / diffs
   │                        │ 计算：mods（UpgradeCards 累加）
   │◄── 读取 mods ──────────┘
   │
   ├─ _spawn_player ──> Tank.apply_run_mods(mods)        数值
   ├─ _start_stage ──> Mutators / 关卡类型 / 战区倍率     投放
   ├─ _spawn_enemy ──> EnemyAffix.roll() + apply()        词缀
   ├─ on_tank_destroyed ──> RunState.add_kills_credits() 经济
   ├─ 肃清 ──> RunState.offer() ──> RunUI.show_cards()
   ├─ 每 3 关 ──> RunUI.show_station()
   └─ 胜负 ──> RunState.finish() ──> Meta.add_credits()
```

原则：

- **数据层（UpgradeCards / Mutators / EnemyAffix）是纯静态表**，不依赖场景树，探针可直接调用。
- **RunState 不引用节点**，只保存与计算；这样联机快照可以直接序列化它。
- **RunUI 不修改战斗状态**，只发信号给 `main`；避免界面与规则互相耦合。

---

## 3. 关键实现约定

### 3.1 数值修正的单一入口

`Tank.apply_run_mods(mods: Dictionary)` 是唯一入口：

- 必须在 `Player._apply_roster()` 与 `apply_difficulty()` **之后**调用，否则卡牌会被名册覆写；
- 内部先记录"基线"再乘，重复调用结果幂等（可随时对存活车辆重算）；
- 敌方 Tank 不调用它（词缀走 `EnemyAffix`）。

### 3.2 确定性跳弹

`Tank.take_hit()` 里的 `randf() < 0.30` 删除，改为：

```gdscript
if kind == Shell.Kind.AP and ang > ricochet_angle:
    ... 返回 "ricochet"
```

`is_ricochet_angle()` 同步改为 `ang > ricochet_angle and ang < 55.0`。
玩家的 `ricochet_angle` 默认 45°，敌车在 `Enemy.configure()` 里按 `Enemy.ENEMY_RICOCHET`
赋值（侦察 52 / 中型 46 / 重型 38 / 火炮 50 / Boss 40），客户端复制品走同一个 `configure()`，
准星提示（`HUD` 读 `is_ricochet_angle`）与结算共用同一辆车上的同一个值。
规格文档（`04_combat_rules.md`）第 1 节是唯一依据，修改顺序必须同步更新文档。

### 3.3 随机数

- Run 级随机（卡池、词缀、补给站）使用 `RunState.rng`（`RandomNumberGenerator`），
  种子取自房主的时间戳与房间种子；**不使用全局 `randf()`**，避免探针与联机不可复现。
- 联机时只有房主抽卡与掷词缀，客户端接收结果。

### 3.4 冻结而非暂停

`reward` / `station` 状态下：

- **不用** `get_tree().paused`（联机时会让客户端收不到快照）；
- 敌人 AI 在 `state != "play"` 时已经停下（`Enemy.tick` 现有逻辑）；
- 玩家 `Player.tick` 因 `controllable` 为 false 只做惯性衰减；
- `main._physics_process` 的互推只在 `play/ready/clear` 运行，天然停止。

### 3.5 存档兼容

- `meta.cfg` 首次运行不存在 → 使用默认值并在首次结算时创建；
- `settings.cfg` 里 `selected_tank` 指向未解锁战车（例如开发者手动改过）→
  车库仍显示，出击时退回 `falcon` 并提示；
- `stats.cfg` 不变，已有的生涯数据继续显示。

---

## 4. 验收

### 4.1 无头自检

```bash
godot --headless --path . --quit-after 240
```

退出码 0。任何 `Parse Error`、`Invalid access`、autoload 缺失都视为失败。

### 4.2 新探针 `tools/RunProbe.tscn` / `tools/run_probe.gd`

无头运行，逐项打印 `PROBE <name> OK/FAIL <数据>`，全部 OK 时打印 `PROBE RUN OK` 并 `quit(0)`，否则 `quit(1)`：

| 检查项 | 判据 |
| --- | --- |
| 卡表完整性 | 30 张、id 唯一、每个 mods 键都在文档列出的键集内、上限 > 0 |
| 抽卡 | 抽 200 次三选一：无重复、无超出上限、全部常规时第三张被替换 |
| mods 累加 | 手工叠加已知卡，乘性/加性结果与手算一致（容差 1e-6） |
| 叠加上限 | 叠满的卡不再出现在候选中 |
| 经济 | 关卡奖励、击杀奖励、重掷价格、跳过补偿与文档公式一致 |
| 境界 | 9 关的类型序列为 歼灭/坚守/决战 ×3 |
| 跳弹 | 构造 44°/46° 两个入射角，结果分别为"击穿/跳弹"，重复 50 次结果不变 |
| 敌方跳弹 | 五种车型阈值落在 38°~52° 且重型 < 中型 < 侦察（39° 入射：重型跳、侦察穿） |
| 词缀 | 第 1 关无词缀；第 9 关 ≥1；同一敌人不重复；数值效果与表一致 |
| 修正 | `horde` 使敌人数 ×1.25，`blitz` 使坚守时间 ×0.8 |
| 元进度 | 结算转化率（100%/50%）、解锁扣款、升级等级上限 |
| 存档 | `Meta` 保存→重载后数据一致；损坏字典回落为空表不崩溃 |

### 4.3 回归探针

以下现有探针必须仍然通过（跳弹改动会影响它们）：

| 探针 | 关注点 |
| --- | --- |
| `tools/combat_probe` | 穿墙、AI 死锁 |
| `tools/wreck_probe` | 残骸路径 |
| `tools/click_probe` | 点击必出弹（多弹数改为 `extra_shells` 后不得回归） |
| `tools/smoke_test` | 开局→开火→击毁 |
| `tools/net_probe` | 双进程联机（新增 Run 行后握手仍需通过） |

### 4.4 手动验收清单

1. 新开一局：第 1 关为歼灭，第 2 关为坚守（右侧出现倒计时），第 3 关为决战（Boss）。
2. 每关结束出现三选一，选中后左上角战功与卡牌数立即变化。
3. 第 3 关后出现补给站，购买后余额减少、效果生效。
4. 失败后结算显示"战功 → 补给券 50%"与卡牌列表；补给券余额增加。
5. 车库用补给券解锁山猫，随后可直接选出击。
6. 局域网双人：客户端能看到房主选的卡，三选一界面显示"等待房主选择"。

---

## 5. 风险与回退

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 卡牌加成与名册/难度覆盖顺序错误 | 玩家变强但数值不变 | `apply_run_mods` 幂等 + 探针校验 |
| `reward` 状态与联机快照冲突 | 客户端被拉回 `play` | 快照里的 `state` 只接受 `ready/play/clear`（现状），Run 界面状态单独走 RPC |
| 跳弹确定性后难度上升 | 前期挫败 | 玩家阈值 45°（原等效 32°+30%），敌车按车型 38°~52°；用 `CombatProbe` 与 `RunProbe ricochet.*` 回归 |
| `main.gd` 继续膨胀 | 可维护性 | 新增逻辑独立文件；下一次重构再拆 UI 与波次 |
| 新探针在无头下缺渲染 | 误报失败 | 探针只读数据层，不截图 |

回退方式：所有新功能通过 `RunState` 开关（`ENABLED`）与 `Mutators` 空表即可回到旧行为；
跳弹改动是唯一"不可开关"的规则变化，如需回退必须在文档 04 里记录版本。