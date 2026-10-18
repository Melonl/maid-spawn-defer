# [1.20.1 Forge] 死亡重生时 `ConcurrentModificationException: PersistentEntitySectionManager.m_157543_`

> 这份文档是可直接粘贴到 GitHub Issue / 模组反馈区的完整报告。
> 提交前把 `<MOD_NAME>` 换成对应仓库名即可。

## 环境

| 项目 | 值 |
|---|---|
| Minecraft | 1.20.1 |
| 加载器 | Forge 47.4.28 |
| 车万女仆 | `touhoulittlemaid-1.5.3-forge+mc1.20.1.jar` |
| 爱憎分明 | `TouhouLittleMaid-LoveLoathe-1.20.1-forge-2.2.3.jar` |
| 其他 | 67 个 mod（女仆附属为主）、Oculus + Embeddium、Epic Fight |
| 端 | 单人存档（集成服务器） |

## 复现步骤

1. 进入存档，正常游玩。
2. 让玩家死亡（`/kill` 或战斗死亡均可）。
3. 在死亡界面点击「重生」。

**期望**：在出生点重生，区块正常加载。
**实际**：点击后客户端无响应，必须强制结束进程；`latest.log` / `crash-report` 报 `Exception ticking world` + `ConcurrentModificationException`。

复现率：稳定复现——同一存档多份崩溃报告，均发生在点击「重生」之后（用户观察，非随机崩溃）。

## 崩溃信息

```
---- Minecraft Crash Report ----
Description: Exception ticking world

java.util.ConcurrentModificationException: null
    at java.util.ArrayList$Itr.checkForComodification(ArrayList.java:1096)
    at java.util.ArrayList$Itr.next(ArrayList.java:1050)
    at com.google.common.collect.Iterators$1.next(Iterators.java:146)
    at java.util.Iterator.forEachRemaining(Iterator.java:133)
    at java.util.Spliterators$IteratorSpliterator.forEachRemaining(Spliterators.java:1939)
    at java.util.stream.AbstractPipeline.copyInto(AbstractPipeline.java:570)
    at java.util.stream.ForEachOps$ForEachOp.evaluateSequential(ForEachOps.java:153)
    at java.util.stream.ReferencePipeline.forEach(ReferencePipeline.java:632)
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_157543_(PersistentEntitySectionManager.java:175)
    at java.util.stream.ForEachOps$ForEachOp$OfRef.accept(ForEachOps.java:186)
    ...
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_157527_(PersistentEntitySectionManager.java:160)
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_287207_(PersistentEntitySectionManager.java:146)
    at net.minecraft.server.level.ChunkMap.m_287285_(ChunkMap.java:1307)
    at net.minecraft.server.level.ChunkHolder.m_287189_(ChunkHolder.java:346)
    at net.minecraft.server.level.DistanceManager.m_183906_(DistanceManager.java:120)
    at net.minecraft.server.level.ServerChunkCache.m_8489_(ServerChunkCache.java:273)
    at net.minecraft.server.level.ServerLevel.m_8793_(ServerLevel.java:305)
    at net.minecraft.server.MinecraftServer.m_5703_(MinecraftServer.java:893)

-- Head --
Thread: Server thread
Suspected Mods: NONE
```

相关上下文：

- 崩溃时玩家：`ServerPlayer['xxx'/'82, l='ServerLevel[新的世界]', x=607.50, y=67.00, z=701.50]`
- 同 tick 区块数：`Chunk stats: 8287`
- 该方法的 mixin 应用列表（崩溃报告自带）：
  `pl:mixin:APP:touhou_little_maid.mixins.json:PersistentEntitySectionManagerMixin`
- `Suspected Mods: NONE` 说明**异常不是在任何 mod 的方法帧里抛出**的。

## 分析

`m_157543_` 是 `PersistentEntitySectionManager#updateChunkStatus` 的 lambda，它遍历每个
`EntitySection` 的实体流：

```java
// EntitySection#m_156845_  (1.20.1)
public Stream<T> m_156845_() {
    return this.storage.stream();   // ClassInstanceMultiMap 内部 ArrayList 的实时视图
}
```

原版拿这个流直接 `.filter(...).forEach(consumer)`，consumer 是
`startTicking` / `stopTicking` / `startTracking` / `stopTracking`（SRG `m_157564_` /
`m_157570_` / `m_157575_` / `m_157580_`），它们都会回调 `LevelCallback`。
如果回调里新增、移除或传送了同一区段内的实体，底层 `ArrayList` 结构改变，
迭代器在下一次 `next()` 抛出 CME，整个 tick 挂掉。

因此：

- **不是崩溃栈里没出现 mod 就与 mod 无关**——修改发生在 consumer 内部，异常在之后才被检测。
- 触发概率与「一次 tick 内遍历的区段数」正相关，重生时的批量区块加载正好把基数放大到 8000+。
- 这与「哪个 mod 生成实体」无关，任何在实体回调里动实体的 mod 都会踩到。

## 建议的修复

在**读取侧**做快照即可，不需要改任何生成/ tick 逻辑：

```java
@Redirect(method = "m_157543_", require = 0, remap = false,
    at = @At(value = "INVOKE", remap = false,
        target = "Lnet/minecraft/world/level/entity/EntitySection;m_156845_()Ljava/util/stream/Stream;"))
private Stream<?> snapshotSection(EntitySection section) {
    List<?> copy = new ArrayList<>(section.m_156845_().toList());
    return copy.stream();
}
```

（等价的原版写法是把 `EntitySection#m_156845_()` 的返回值改为
`new ArrayList<>(storage).stream()`，或先收集再遍历。）

## 临时规避

| 方案 | 代价 |
|---|---|
| 关闭爱憎分明（`callresponse` 系） | 失去全部相关玩法与结构内容 |
| 删除相关数据包 | **前哨结构内容永久丢失**（不要这样做） |
| 装第三方补丁 | 需要额外维护，见下 |

## 已完成的验证

用上述快照方案写了独立补丁 `maid-spawn-defer`（MIT，2 个类）：

- 启动日志确认注入：`Mixing PersistentEntitySectionManagerMixin ... into net.minecraft.world.level.entity.PersistentEntitySectionManager`
- 整局 `latest.log` 中 CME 计数 0；修复后死亡 → 重生实机测试通过，用户确认不再卡死
- 不修改存档数据，移除即恢复原版行为

如果上游愿意修复，把这段快照逻辑并入 TLM / 相关模组会更干净；本补丁可作为过渡方案。
