# Maid Spawn Defer · 实体区段遍历 CME 修复

> Minecraft 1.20.1 · Forge 47.x · 客户端/服务端通用 · 不修改存档

一个只有 2 个类的小补丁，修掉一类**通用**的服务端崩溃：

```
java.util.ConcurrentModificationException
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_157543_(PersistentEntitySectionManager.java:175)
```

外在表现是：**死亡后点击「重生」→ 游戏卡死/未响应**，日志里是 `Exception ticking world`。

它不是针对某个 mod 打补丁，而是把原版「实体区段遍历」改成**快照遍历**：
遍历过程中任何 mod 增删、传送实体，都不会再打断迭代。

---

## 1. 症状

| 项目 | 值 |
|---|---|
| 游戏版本 | Minecraft 1.20.1 |
| 加载器 | Forge 47.4.28 |
| 触发动作 | 玩家死亡 → 点击「重生」按钮 |
| 表现 | 客户端卡死（未响应），需强制结束进程；服务端 tick 中断 |
| 日志关键字 | `ConcurrentModificationException` / `Exception ticking world` |
| 栈顶 | `PersistentEntitySectionManager.m_157543_` → `ArrayList$Itr.checkForComodification` |

典型栈（省略中间框架帧）：

```
java.util.ConcurrentModificationException: null
    at java.util.ArrayList$Itr.checkForComodification(ArrayList.java:1096)
    at java.util.ArrayList$Itr.next(ArrayList.java:1050)
    at java.util.Iterator.forEachRemaining(Iterator.java:133)
    at java.util.stream.ReferencePipeline.forEach(ReferencePipeline.java:632)
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_157543_(PersistentEntitySectionManager.java:175)
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_157527_(PersistentEntitySectionManager.java:160)
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_287207_(PersistentEntitySectionManager.java:146)
    at net.minecraft.server.level.ChunkMap.m_287285_(ChunkMap.java:1307)
    ...
    at net.minecraft.server.MinecraftServer.m_5703_(MinecraftServer.java:893)
```

崩溃报告中 `Suspected Mods: NONE`，因为异常不是在某个 mod 的方法里抛出的——
它在下一次 `Iterator.next()` 才被检测到，真正动手改集合的调用栈已经返回了。

## 2. 根因

### 2.1 原版在直接遍历「活集合」

`m_157543_` 是 `updateChunkStatus` 内部那个 lambda（Mojang 名 `lambda$updateChunkStatus$6`）。
它对每个 `EntitySection` 调用 `EntitySection.m_156845_()`，而后者返回的是
`ClassInstanceMultiMap` 内部 `ArrayList` 的**实时流**，不是副本：

```java
// EntitySection#m_156845_ (1.20.1)
return this.storage.stream();   // ClassInstanceMultiMap -> ArrayList 视图
```

拿到流后，原版直接 `.filter(...).forEach(consumer)`，四个 consumer 分别是
`startTicking` / `stopTicking` / `startTracking` / `stopTracking`（SRG：`m_157564_` /
`m_157570_` / `m_157575_` / `m_157580_`）。这四个方法都会回调 `LevelCallback`，
而回调里完全可能**生成、移除或传送实体**（女仆跟随传送、召唤物、区块卸载清理等）。

### 2.2 撞车点

只要回调里动了同一个 `ArrayList`，迭代器下一次 `next()` 就抛 `ConcurrentModificationException`，
服务器 tick 中断，客户端表现为卡死。

### 2.3 为什么偏偏在「重生」时爆发

重生会让玩家周围区块成批重新加载，`ChunkMap → updateChunkStatus → 逐区段遍历` 在同一个 tick 内被放大。
事故存档崩溃时玩家坐标 `607, 67, 701`，该 tick 统计到 **8287** 个区块：
遍历基数越大，与「回调里动实体」撞车的概率越高。

### 2.4 这不是某一个 mod 的 bug

这是**原版遍历方式**与**任何在实体回调里增删实体的 mod** 的组合问题。
本案例中车万女仆（TLM 1.5.3）自己在同一个类上也挂了 mixin（`tick` 末尾、`processUnloads` 之前传送女仆），
说明这个类的实体增删时序本来就敏感。

具体是哪一次写入触发的，无法从崩溃栈直接定位——异常在下一次 `next()` 才被检测到，
真正修改集合的调用栈已经返回（`Suspected Mods: NONE` 也是这个原因）。
女仆附属（爱憎分明 2.2.3 等）在区块加载与重生路径上频繁生成、传送实体，是主要的写入方。

> 早期为了绕开崩溃曾禁用爱憎分明、并关闭相关数据包，结果「背叛女仆前哨」内容丢失。
> 本补丁的目标就是**不禁用任何内容**也能正常玩。

## 3. 修复方式

只在**读的一侧**加一层快照：把 `EntitySection.m_156845_()` 的返回值改成
「先把当前实体拷进 `ArrayList`，再对副本开流」。

```java
@Redirect(method = "m_157543_", require = 0, remap = false,
    at = @At(value = "INVOKE", remap = false,
        target = "Lnet/minecraft/world/level/entity/EntitySection;m_156845_()Ljava/util/stream/Stream;"))
private Stream<?> maidfix$snapshotSection(EntitySection section) {
    List<?> copy = new ArrayList<>(section.m_156845_().toList());
    return copy.stream();
}
```

设计取舍：

| 决定 | 原因 |
|---|---|
| 只改读取侧，不改写入侧 | 不延迟生成、不拦截 `addFreshEntity`、不改 tick 顺序，避免「怪/女仆不刷了」这类副作用 |
| `@Redirect` 覆盖方法内全部调用点 | 四个 consumer（ticking/tracking）一次全包 |
| `require = 0` | 将来映射变化导致注入点找不到时，只退回原版行为并打警告，不会让游戏起不来 |
| `remap = false` + SRG 名 | 不需要 refmap，生产环境直接命中 |

### 语义代价（明确写清）

快照意味着：**本轮遍历中新加入的实体，会在下一次 `updateChunkStatus` 才登记 ticking/tracking**。
也就是最多晚一次状态更新（毫秒级到一次区块状态变更），实体不会丢失，也不写任何持久化数据。

## 4. 安装

1. 从 [Releases](../../releases) 下载 `maid_spawn_defer-2.1.1.jar`
2. 放进 `mods/`（PCL 版本隔离时是 `.minecraft/versions/<实例名>/mods/`）
3. 启动即可，无配置项

单人和服务器都能装。崩溃是**服务端** tick 抛出的，联机时服务端也要装同一份 jar。

## 5. 兼容性

| 项 | 说明 |
|---|---|
| 必需 | Forge 47.x + Minecraft 1.20.1 |
| 可选 | `callresponse`（爱憎分明）——代码不引用它，缺失时不会报错（依赖声明为 optional） |
| 已知冲突 | 无。与 TLM 自带的 `PersistentEntitySectionManagerMixin` 注入点不同，可共存 |
| 存档 | 不写持久化数据；移除后立即恢复原版行为 |

已在使用环境验证：`1.20.1-Forge 47.4.28` + `Touhou Little Maid 1.5.3` +
`TouhouLittleMaid-LoveLoathe 2.2.3` + 67 个 mod 的整合包。

## 6. 验证记录

- 启动日志确认注入成功：
  `[mixin/]: Mixing PersistentEntitySectionManagerMixin from maid_spawn_defer.mixins.json into net.minecraft.world.level.entity.PersistentEntitySectionManager`
- 整局游戏 `latest.log` 中 `ConcurrentModificationException` 计数为 **0**，正常退出
- 修复前该操作稳定复现（同一存档多份崩溃报告，均发生在点击重生之后）；
  修复后实机测试（死亡 → 重生）通过，用户确认不再卡死

## 7. 构建

### 方式 A：ForgeGradle（标准）

需要 Gradle 8.1+（仓库未附带 wrapper，可先执行 `gradle wrapper` 生成）：

```bash
gradle build
# 产物：build/libs/maid_spawn_defer-2.1.1.jar
```

### 方式 B：离线 javac（无需联网）

`tools/build-offline.sh` 直接对着一个已安装的 1.20.1 Forge 环境编译打包：

```bash
MC_DIR="/path/to/.minecraft" ./tools/build-offline.sh
# 产物：dist/maid_spawn_defer-2.1.1.jar
```

脚本流程：定位 `client-*-srg.jar` / `forge-*-universal.jar` / `fmlcore` /
`javafmllanguage` / `mixin` → `javac --release 17` → 复制 resources →
`jar --create` 并写入 `MixinConfigs`、`FMLModType` 清单属性。
（`@Mod` 注解在 `javafmllanguage` 里，不在 `forge-universal`，这是最容易漏的一个依赖。）

> 保留这条路径的原因很实际：本补丁就是在 Forge maven 不可达的环境里产出的，
> 离线构建是当时唯一可用的方式，现在依然可用。

## 8. 常见问题

**Q：会不会让女仆/怪物生成变慢？**
不会。补丁只影响「遍历时读到的是副本」，生成逻辑本身没有延迟。

**Q：能只装在客户端吗？**
单人游戏可以（集成服务器同进程）。联机时客户端装不装都行，**服务端必须装**。

**Q：为什么 mod 名叫 "Maid Spawn Defer"？**
历史原因。1.x/2.0.0 尝试过「延迟生成」的修法，2.1.0 起实际机制已改为「快照遍历」，
但为了不打断已有存档和整合包引用，`modId` 保持不变。

**Q：1.20.1 以外的版本能用吗？**
源码只针对 1.20.1 的 SRG 名编写，其他版本需要替换目标方法名与描述符。

## 9. 仓库结构

```
maid-spawn-defer/
├─ src/main/java/com/maidfix/
│  ├─ SpawnFixMod.java                    # 空入口，只有一个 @Mod
│  └─ mixin/PersistentEntitySectionManagerMixin.java
├─ src/main/resources/
│  ├─ META-INF/mods.toml
│  ├─ maid_spawn_defer.mixins.json
│  └─ pack.mcmeta
├─ docs/
│  ├─ issue-cme-on-respawn.md             # 可直接粘贴的 issue 报告
│  ├─ root-cause.md                       # 定位过程 / SRG 核对 / 风险分析
│  ├─ release-notes-2.1.1.md
│  └─ publish.md                          # 发布到 GitHub 的步骤
├─ tools/build-offline.sh                 # 无网构建
├─ dist/maid_spawn_defer-2.1.1.jar
└─ README.md
```

## 10. 许可

MIT，见 [LICENSE](LICENSE)。

---

## English summary

A 2-class Forge 1.20.1 patch for a generic server-side `ConcurrentModificationException`
thrown from `PersistentEntitySectionManager#updateChunkStatus` (SRG `m_157543_`) when a mod
adds/removes/teleports an entity while vanilla iterates an `EntitySection`'s live storage.
It redirects `EntitySection#m_156845_()` to return a snapshot stream, so iteration is immune to
structural modification. No spawn/tick behaviour changes, no world data touched, removable at will.
