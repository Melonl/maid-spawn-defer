# v2.1.1 — 实体区段遍历 CME 修复

## 修了什么

死亡后点击「重生」不再卡死。崩溃栈：

```
java.util.ConcurrentModificationException
    at net.minecraft.world.level.entity.PersistentEntitySectionManager.m_157543_(PersistentEntitySectionManager.java:175)
```

`m_157543_` 是 `updateChunkStatus` 的 lambda，原版在这里**直接遍历** `EntitySection`
内部的 `ArrayList`（`ClassInstanceMultiMap`），而遍历时的回调（`startTicking` /
`stopTicking` / `startTracking` / `stopTracking`）可能生成、移除或传送实体。
只要动到正在遍历的区段，就会 CME，服务端 tick 中断，客户端卡死。

本补丁把这 4 处读取改成**快照流**（先拷贝再遍历），写入侧完全不动。

## 安装

1. 下载 `maid_spawn_defer-2.1.1.jar`
2. 放入 `mods/`
3. 启动，无需配置

单人、服务端通用。联机时**服务端也要装**（异常是服务端 tick 抛的）。

## 兼容性

- Minecraft 1.20.1 + Forge 47.x
- 与车万女仆自带的 `PersistentEntitySectionManagerMixin` 注入点不同，可共存
- 不修改存档数据，删除 jar 即恢复原版行为
- `callresponse`（爱憎分明）为**可选**依赖，代码不引用它，缺失时不会报错

## 验证

- `debug.log`：`Mixing PersistentEntitySectionManagerMixin from maid_spawn_defer.mixins.json into net.minecraft.world.level.entity.PersistentEntitySectionManager`
- 整局 `latest.log` 中 `ConcurrentModificationException` 计数 0
- 修复后死亡 → 重生实机测试通过（修复前该操作稳定复现）

## 与 2.1.0 的差异

**仅元数据**：修正了 `mods.toml` 中仍在描述旧「延迟生成」方案的文案，
并更新版本号。两个 `.class` 文件与 2.1.0 的 SHA-256 完全一致，行为无任何变化。
已经装 2.1.0 的可以不用升级。

## 文件

| 文件 | 大小 | SHA-256 |
|---|---|---|
| `maid_spawn_defer-2.1.1.jar` | 3.2 KB | `53f18c399bb130261f0ab2cf948c21c8000bfbd95467f3665798155543a562bd` |

## 已知限制

- 只针对 1.20.1 的 SRG 名编写，其他版本需替换目标方法名与描述符。
- `require = 0`：若将来映射变动导致注入失败，补丁会静默退回原版行为（有 mixin 警告），
  不会阻止游戏启动；升级 Forge 后建议按 README 第 6 节自查一次。
