# 发布到 GitHub

仓库根目录：`maid-spawn-defer/`（本文件所在 `docs/` 的上一级）。

## 0. 提交前检查

```bash
# 不要提交的东西（.gitignore 已覆盖）
#   build/  run/  logs/  crash-reports/  .gradle/
git status --short
```

确认 `dist/maid_spawn_defer-2.1.1.jar` 存在，且 `git status` 里没有整合包内容、存档、日志。

## 1. 初始化并提交

本目录已执行 `git init -b main` 与 `git add .`，只差身份和第一次提交：

```bash
cd maid-spawn-defer
git config user.name  "你的名字"
git config user.email "你的邮箱"
git commit -m "fix: snapshot entity section iteration to avoid CME on respawn"
```

如果是在别处重新开始：

```bash
cd maid-spawn-defer
git init -b main
git add .
git commit -m "fix: snapshot entity section iteration to avoid CME on respawn"
```

## 2. 创建远程仓库

用 GitHub CLI（推荐）：

```bash
gh repo create maid-spawn-defer --public --source=. --remote=origin --push
```

或手动：网页新建空仓库 → 然后

```bash
git remote add origin https://github.com/<你的用户名>/maid-spawn-defer.git
git push -u origin main
```

## 3. 发布 Release

```bash
git tag -a v2.1.1 -m "v2.1.1"
git push origin v2.1.1

gh release create v2.1.1 dist/maid_spawn_defer-2.1.1.jar \
  --title "v2.1.1 - 重生 CME 修复" \
  --notes-file docs/release-notes-2.1.1.md
```

## 4. Release 文案

见仓库根的 `docs/release-notes-2.1.1.md`，可直接作为 `--notes-file` 使用。

## 5. 可选：向上游反馈

`docs/issue-cme-on-respawn.md` 是可直接粘贴的 issue 正文，建议提交给：

- 爱憎分明（LoveLoathe）仓库 —— 崩溃出现在它的玩法场景里，但根因在原版遍历方式；
- 车万女仆（Touhou Little Maid）仓库 —— 它在同一个类上有 mixin，属于同一条时序链。

提交时附上：

1. issue 正文（现象 + 栈 + 分析 + 建议修法）；
2. 本仓库链接，作为已验证的过渡方案；
3. `crash-*.txt` 原始文件（如上游要求）。

## 6. 备注

- 仓库名与 `modId` 不一致是历史原因（见 README FAQ），发布时不必改名。
- `dist/` 里的 jar 与 Release 资产是同一份文件，保留在仓库里方便直接下载。
- 如果后续要发 2.2.0，记得同步修改三处版本号：`gradle.properties`、`mods.toml`、`CHANGELOG.md`。
