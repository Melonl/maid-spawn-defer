# 技术说明：CME 的定位过程与修复原理

本文记录 `maid-spawn-defer` 的完整技术依据，便于 review 或移植到其他版本。

## 1. 崩溃现场还原

崩溃发生在服务端 tick 的区块状态更新阶段，调用链（由内向外）：

```
ArrayList$Itr.checkForComodification
  ← ReferencePipeline.forEach
  ← PersistentEntitySectionManager.m_157543_   (line 175)
  ← ForEachOps$ForEachOp.accept                (外层 section 流)
  ← PersistentEntitySectionManager.m_157527_   (line 160)
  ← PersistentEntitySectionManager.m_287207_   (line 146)
  ← ChunkMap.m_287285_ → ChunkHolder → DistanceManager
  ← ServerChunkCache.m_8489_ → ServerLevel.m_8793_ → MinecraftServer.m_5703_
```

关键点：**没有任何 mod 的方法帧**，`Suspected Mods: NONE`。
原因是 CME 的检测发生在迭代器的下一次 `next()`，真正修改集合的调用早已返回。

## 2. 方法名核对

从整合包自带的 `client-1.20.1-20230612.114412-srg.jar` 反汇编
（`javap -p -c -l`）得到以下对应关系：

| SRG | 作用 | 核对方式 |
|---|---|---|
| `m_287207_(ChunkPos, FullChunkStatus)` | `updateChunkStatus` 重载：把 `FullChunkStatus` 映射成 `Visibility` 后转发 | 崩溃帧 + 字节码 |
| `m_157527_(ChunkPos, Visibility)` | `updateChunkStatus` 主实现：遍历 `EntitySectionStorage.m_156888_()` 的 section 流，`forEach` 调用 lambda | 字节码中 `EntitySectionStorage.m_156888_().forEach(lambda)` |
| `m_157543_(Visibility, EntitySection)` | `updateChunkStatus` 的 lambda（Mojang 名 `lambda$updateChunkStatus$6`），内含 **4 处** `EntitySection.m_156845_()` 调用 | `javap` 中该方法为私有、参数为 `(Visibility, EntitySection)`，与崩溃帧完全一致 |
| `m_156845_()` | `EntitySection` 的实体流：`this.storage.stream()`，`storage` 是 `ClassInstanceMultiMap` | 字节码直接可见 |
| `m_157564_` / `m_157570_` / `m_157575_` / `m_157580_` | 四个 `forEach` consumer：`startTicking` / `stopTicking` / `startTracking` / `stopTracking` | 行号 207 / 211 / 215 / 220 与 Mojmap `client-1.20.1-...-mappings.txt` 完全对应 |

> 注：崩溃报告里的行号（146 / 160 / 175）与磁盘上 srg jar 的行号（225 / 230 / 241）不一致——
> 行号来自运行时经过 Forge / Mixin 处理后的类，与 jar 内保存的调试信息存在偏移。
> 偏移的具体来源不影响结论：**定位应以方法名和描述符为准，不要依赖行号。**

## 3. 为什么会 CME

`ClassInstanceMultiMap` 内部按实体基类分桶，每个桶是一个 `ArrayList`。
`EntitySection.m_156845_()` 返回的是这些 `ArrayList` 的**实时流**，没有拷贝。

原版代码：

```java
section.m_156845_()
       .filter(...)
       .forEach(this::m_157564_);   // startTicking → LevelCallback
```

`startTicking` / `stopTicking` / `startTracking` / `stopTracking` 都会回调 `LevelCallback`，
而 `LevelCallback` 的实现里可能：

- 生成实体（召唤、刷怪、结构生成）
- 移除实体（`discard`、区块卸载）
- 传送实体（跨 section 移动 → 先删后加）

只要这些操作命中**当前正在遍历的那个 section**，`ArrayList` 的 `modCount` 变化，
迭代器下一次 `next()` 立刻抛出 CME。

### 为什么重生时必现

- 重生触发玩家周围区块的批量重载；
- 一次 tick 内 `updateChunkStatus` 触及的 section 数量暴涨（事故存档该 tick 统计 8287 个区块）；
- 女仆本身有「跟随主人传送」逻辑，重生点附近女仆被重新加载/传送的概率高。

## 4. 为什么之前的方案都失败

| 版本 | 思路 | 失败原因 |
|---|---|---|
| 1.0.x | 拦截重生、延迟 callresponse 的生成 | 注入点与方法签名反复不匹配（缺 `method`、static/实例 handler 写错）；即使注入成功也只是「换个时机生成」，遍历仍在进行 |
| 2.0.0 | `Level#addFreshEntity` 在遍历期间入队，tick 末尾再放 | **只堵住了「新增」一条路**。移除、传送、section 迁移同样会改集合，实测仍在同一处 CME |
| 2.1.0 | 遍历读取快照 | 通过 |

2.0.0 的实测很关键：它证明了「延迟生成」这条路在原理上就不完备。
只要写入侧还有别的入口（`Entity#setPos` → `onMove` → section 迁移、`discard` 等），
就必须在**读取侧**兜底。

## 5. 修复的作用面

```java
@Redirect(method = "m_157543_", require = 0, remap = false,
    at = @At(value = "INVOKE", remap = false,
        target = "Lnet/minecraft/world/level/entity/EntitySection;m_156845_()Ljava/util/stream/Stream;"))
```

- `@Redirect` 不指定 `ordinal` → 该方法内**所有**匹配调用点都被替换（共 4 处）。
- 返回 `new ArrayList<>(...).stream()`，写入侧维持原样。
- `remap = false` + SRG 目标：生产环境（SRG 运行时）直接命中，不依赖 refmap。
- `require = 0`：映射变化时静默降级为原版行为（会有 mixin 警告），不会让游戏无法启动。
  代价是「补丁失效但不报错」，因此升级 Forge 后建议按第 6 节自查一次。

## 6. 如何自查补丁是否生效

启动后搜索日志：

```bash
grep -n "Mixing PersistentEntitySectionManagerMixin" logs/debug.log
# 期望：[mixin/]: Mixing PersistentEntitySectionManagerMixin from maid_spawn_defer.mixins.json into net.minecraft.world.level.entity.PersistentEntitySectionManager
```

运行一段时间后统计 CME：

```bash
grep -c "ConcurrentModificationException" logs/latest.log   # 期望 0
```

## 7. 开销与风险

- **内存/CPU**：每次遍历多一次 `ArrayList` 拷贝，规模等于「该区段实体数」（通常 < 32，刷怪塔附近可达数百）。
  拷贝发生在区块状态变更路径，不在每 tick 的实体 tick 路径上。未做基准测试，但量级上不构成瓶颈。
- **行为差异**：本轮新增的实体在下一轮 `updateChunkStatus` 才登记 ticking/tracking，
  最多晚一次状态更新；不会丢失实体，也不会写入存档。
- **卸载安全**：补丁不注册任何注册表项、不写 NBT，删除 jar 即完全恢复原版。

## 8. 复现/验证清单

1. 装 jar，启动，确认第 6 节的 `Mixing ...` 日志出现。
2. `/kill` 自己，点重生，重复 ≥ 5 次。
3. `grep -c ConcurrentModificationException logs/latest.log` 应为 0。
4. 观察女仆跟随传送、区块卸载是否正常（回归项）。
