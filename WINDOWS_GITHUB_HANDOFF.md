# MeetMemo Windows 公开仓库与上游 PR 交接说明

> 本文是给后续 AI 的执行说明。目标是在用户的 **Windows 个人电脑**上，把当前修改整理为用户自己的公开 GitHub 仓库，同时正确保留上游来源和许可证；如用户确认，再把合适的修改通过 Fork + Pull Request 贡献给上游。

## 1. 必须先理解的项目状态

- 上游仓库：<https://github.com/abcwyc/MeetMemo>
- 当前快照所基于的上游提交：`10d3b8c76dc6d94ef216d23cdbc7fc139acdb757`
- 当前本地开发分支名：`fix/continuous-dual-audio-timeline`
- 许可证：`PolyForm Noncommercial License 1.0.0`
- Required Notice：`Copyright (c) 2026 abcwyc (https://github.com/abcwyc/MeetMemo)`
- 用户 GitHub 账号预计为：`LingeringAutumn`，但执行前必须用 `gh api user --jq .login` 核实，不要盲目假设。
- 交接压缩包不含 `.git`，因此它只是**源码工作区快照**，不是一个带提交历史的 Git 仓库。
- 不要直接在解压目录执行 `git init` 后把所有代码说成用户原创。应先克隆上游、切到上述基线提交，再把快照覆盖进去，以保留完整上游历史和作者归属。

## 2. 这次究竟修改了什么

### 2.1 没有更换语音识别模型

本次没有新增或替换 ASR 模型。仍然使用项目原有的三种引擎：

1. `SenseVoice-Small INT8`（sherpa-onnx）
2. `Fun-ASR-Nano`（sherpa-onnx）
3. macOS `SpeechAnalyzer`

同时固定了本地构建依赖版本：

- sherpa-onnx：`v1.13.2`
- ONNX Runtime：`1.24.4`

本次主要解决的是音频时间轴、录音生命周期、并发和打包签名问题。识别文本本身的准确率仍由原模型、音质、语言和环境决定。模型升级应作为后续独立功能开发，不应混进时间轴修复 PR。

当前最合理的准确率验证方式，是先在设置中直接切换现有的 `Fun-ASR-Nano`，用同一段真实面试录音和 `SenseVoice` 做 A/B 对比。只有当现有两种本地模型都不能满足中文口语、英文技术词和延迟要求时，再单独评估 Whisper、Paraformer 或其他模型；评估必须记录字错率、专有名词命中、首字延迟、峰值内存和整场处理时间，不能仅凭模型名判断“更好”。

### 2.2 已实现的主要修复

1. **双音轨时间戳漂移**
   - 原逻辑会丢弃安静的系统音频缓冲区，而识别时间戳来自实际送入模型的采样数，因此系统音轨在静音期间被“压短”。
   - 现在保留静音；转换失败或背压丢帧时，用等时长零 PCM 补齐，维持连续时间轴。

2. **麦克风设备切换后的时间轴连续性**
   - 旧 pipeline 会先优雅 drain。
   - 新 tap 启动前根据墙钟和已交付帧数补静音，避免麦克风重启后时间戳突然向前跳。
   - 多个设备变更通知会合并，避免重复重启。

3. **系统音频捕获稳定性**
   - 改为全局系统音频 tap，并排除 MeetMemo 自身。
   - 去掉固定 800ms 重启空档。
   - 系统音频权限失败时可降级为仅麦克风录制。

4. **模型冷启动不再丢开头音频**
   - 模型加载期间先缓存麦克风和系统音频 PCM。
   - provider 连接完成后再冲刷缓存。
   - 缓存溢出时同步推进时间锚点，避免时间戳压缩。

5. **防止重复识别实例和旧回调污染新会话**
   - 麦克风 provider 连接改为 single-flight。
   - 回调只接受当前会话安装的 provider。
   - 取消或失败的旧 provider 会主动断开，不再产生重复文本或内存循环引用。

6. **停止录制和尾音收尾**
   - 停止生产音频后，依次 drain 双 pipeline、等待启动/重连任务、发送最终音频、等待模型 finalization，再保存。
   - 音频转换器显式发送 EOS 并冲刷尾部采样。
   - 多个并发 `drainAndStop()` 调用共享同一个完成屏障，修复 continuation 二次恢复竞态。

7. **Sherpa 识别运行时并发治理**
   - session generation、runtime、ring buffer、speaker ledger 等状态串行化。
   - 最终标记原子关闭音频输入。
   - 增加真实超时处理和 30 秒 ring buffer 上限。
   - 无效 speaker embedding 不再导致崩溃，文本仍会保留。

8. **录音状态和自动保存**
   - 状态机拒绝重叠 start/stop 和过期完成回调。
   - debounce 保存携带 meeting/session 身份，避免写入错误会议。
   - 自动停止也会保存最终转录。

9. **语音输入模式稳定性**
   - 会议录音与语音输入在冷启动期间互斥。
   - 使用优雅 drain 和确定性的主队列结果屏障，不再依赖固定 120ms 猜测。

10. **日志与健壮性**
    - 移除可能暴露会议标题、上下文和模型响应正文的日志。
    - 增加会话删除、取消、重入和过期回调保护。

11. **本地构建及启动修复**
    - 新增只使用 macOS Command Line Tools 的本地 arm64 构建脚本。
    - 本地 ad-hoc 主程序与 ONNX dylib 没有 Developer Team ID，Hardened Runtime 默认会拒绝加载。构建脚本现在只对本地包加入 `com.apple.security.cs.disable-library-validation`，同时保留 release entitlements 不变。
    - 构建脚本会提取最终签名 entitlement 并防回归验证。

12. **测试覆盖**
    - 增加时间轴补偿、系统 tap 策略、会话状态、并发 provider、speaker clustering、保存身份和 pipeline drain/EOS 等测试。

### 2.3 当前验证边界

已经确认：

- App 完整 Swift 编译和链接成功。
- arm64 架构、RPATH、Info.plist、entitlements 和嵌入 dylib 正常。
- `codesign --verify --deep --strict` 通过。
- 用户已经确认修复版 App 可以打开，说明启动时 Library Validation 崩溃已解决。
- 所有 Swift 测试文件通过语法解析；构建脚本通过 `bash -n`；`git diff --check` 通过。

尚未确认：

- 用户还没有完成一次真实的“麦克风 + 腾讯会议/飞书系统音频”录制。
- 没有完整 Xcode，因此尚未运行完整 XCTest test bundle。
- Windows 不能编译或运行这个 macOS App；Windows 只能整理 Git、许可证和 PR。

后续 AI 不得声称“所有问题百分之百解决”。时间戳修复必须通过真实会议测试验收。

## 3. 推荐的 GitHub 结构

用户希望拥有一个真正属于自己的公开仓库，因此推荐同时保留两条线：

### 主线：用户自己的独立 public 仓库

建议名称：`LingeringAutumn/MeetMemo-Interview`，也可以在创建前让用户换名。

作用：

- 作为用户长期维护的个人版本。
- 可以有自己的 Issues、Releases、README 和内部 PR。
- 保留上游 Git 历史、LICENSE 和版权声明。

### 可选线：GitHub 官方 Fork

建议 Fork：`abcwyc/MeetMemo` → `LingeringAutumn/MeetMemo`。

作用：

- 只用于向 `abcwyc/MeetMemo` 提交上游 PR。
- GitHub 的 Fork 关系让跨仓库 PR 最清晰。
- 如果该 Fork 已经存在，直接复用，不要重复创建。

独立仓库和 Fork 可以同时存在，只要名称不同，例如：

- 独立仓库：`MeetMemo-Interview`
- 官方 Fork：`MeetMemo`

## 4. Windows 环境准备

以下命令在 **PowerShell** 中运行。安装完成后必须关闭整个 Windows Terminal 窗口再重新打开。

### 4.1 安装 Git 和 GitHub CLI

```powershell
winget install --id Git.Git -e --source winget
winget install --id GitHub.cli --source winget
```

验证：

```powershell
git --version
gh --version
```

如果 `winget` 不可用，使用官方安装包：

- Git for Windows：<https://git-scm.com/download/win>
- GitHub CLI：<https://github.com/cli/cli/releases/latest>

### 4.2 登录个人 GitHub

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh auth status
gh api user --jq .login
```

要求：

- 使用浏览器登录个人 GitHub。
- 不要让用户把 Token、验证码或密码粘贴进 AI 对话。
- 如果 `gh api user --jq .login` 不是预期个人账号，先停止，不要创建仓库或 push。

### 4.3 配置本仓库专用 Git 身份

不要修改用户整台 Windows 的全局 Git 设置。仓库级配置只能在克隆完成并进入 Git 仓库后执行，因此具体命令放在第 6.2 节。如果 GitHub 的 noreply 地址不同，应先在 GitHub → Settings → Emails 中核实。

## 5. 解压交接包

压缩包名称：`0901腾讯面经总结.zip`。

解压后应看到：

```text
NewMeetMemo/
  LICENSE
  README.md
  WINDOWS_GITHUB_HANDOFF.md
  MeetMemo/
  MeetMemoTests/
  MeetMemo.xcodeproj/
  scripts/
  ...
```

压缩包刻意排除了：

- `.git`
- `dist`
- `Frameworks`
- `.build`
- `DerivedData`
- `xcuserdata`
- 编译后的 App 和本地二进制依赖

不要把解压目录直接当成最终 Git 仓库。下一节会从上游历史重建工作区。

## 6. 创建用户自己的独立 public 仓库（推荐方案）

以下变量只是示例。后续 AI 应先让用户确认仓库名，然后再执行产生外部状态的命令。

```powershell
$GitHubUser = gh api user --jq .login
$RepoName = "MeetMemo-Interview"
$Upstream = "https://github.com/abcwyc/MeetMemo.git"
$BaseCommit = "10d3b8c76dc6d94ef216d23cdbc7fc139acdb757"
$Branch = "fix/continuous-dual-audio-timeline"
$Workspace = Join-Path $HOME "source\MeetMemo-Interview"
$Snapshot = "C:\请替换成实际解压路径\NewMeetMemo"
```

执行前验证路径，避免覆盖已有目录：

```powershell
if (Test-Path $Workspace) {
    throw "Workspace already exists: $Workspace"
}
if (-not (Test-Path (Join-Path $Snapshot "LICENSE"))) {
    throw "Snapshot path is wrong or incomplete: $Snapshot"
}
```

### 6.1 在 GitHub 创建空 public 仓库

CLI 方案：

```powershell
gh repo view "$GitHubUser/$RepoName"
gh repo create "$GitHubUser/$RepoName" --public --description "Unofficial noncommercial MeetMemo variant focused on reliable dual-audio interview transcription"
```

第一条命令用于检查同名仓库是否已经存在：如果存在，先让用户确认是否复用，禁止删除或覆盖；只有确认不存在时才执行第二条创建命令。

浏览器方案：GitHub → `New repository` → `Public`。

无论采用哪种方案：

- 不要勾选初始化 README。
- 不要选择新的 License。
- 不要生成新的 `.gitignore`。
- 原因是这些文件需要从上游原样继承，避免历史和许可证冲突。

### 6.2 克隆上游并配置 remote

```powershell
New-Item -ItemType Directory -Force (Split-Path -Parent $Workspace) | Out-Null
git clone $Upstream $Workspace
Set-Location $Workspace
git remote rename origin upstream
git remote add origin "https://github.com/$GitHubUser/$RepoName.git"
git remote -v
git config --local user.name "LingeringAutumn"
git config --local user.email "121529104+LingeringAutumn@users.noreply.github.com"
git config --local --get user.name
git config --local --get user.email
```

期望结果：

```text
origin    https://github.com/<用户>/<独立仓库>.git
upstream  https://github.com/abcwyc/MeetMemo.git
```

### 6.3 从准确的上游基线创建修复分支

```powershell
git cat-file -e "$BaseCommit^{commit}"
git switch -c $Branch $BaseCommit
git push origin "$BaseCommit`:refs/heads/main"
```

这样用户独立仓库的 `main` 首先对应原始上游基线，修复则通过单独分支进入，历史清楚。

### 6.4 将交接快照覆盖到克隆仓库

使用 `robocopy /E`，不要使用会删除目标文件的 `/MIR`：

```powershell
robocopy $Snapshot $Workspace /E /XD .git dist Frameworks .build DerivedData xcuserdata /XF .DS_Store *.xcuserstate
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}
Set-Location $Workspace
git status --short
```

`robocopy` 的 0～7 通常都属于成功或带差异的成功结果，8 以上才应当作失败。

## 7. 许可证和仓库说明怎么写

### 7.1 LICENSE 必须怎么处理

必须保留上游的 `LICENSE`，不要改成 MIT、Apache-2.0 或 GPL，也不要在 GitHub 创建仓库时选择另一个 License。

文件中必须继续包含：

```text
# PolyForm Noncommercial License 1.0.0

Required Notice: Copyright (c) 2026 abcwyc (https://github.com/abcwyc/MeetMemo)
```

许可证允许个人非商业目的使用、修改和公开分发，但不允许未经授权的商业用途。

### 7.2 README 顶部建议增加的声明

后续 AI可以把下面文字加入 README 靠前位置，但不得删除原作者信息：

```markdown
> [!IMPORTANT]
> 本仓库是基于 [abcwyc/MeetMemo](https://github.com/abcwyc/MeetMemo) 的非官方修改版本，
> 主要增强双音轨时间轴连续性、录音收尾、并发稳定性与本地构建流程。
> 项目继续遵循 PolyForm Noncommercial License 1.0.0，仅限非商业用途。
> 原始版权声明和许可证见 [LICENSE](LICENSE)。
```

### 7.3 建议增加修改说明

可以新增 `MODIFICATIONS.md`：

```markdown
# Modifications

This repository is an unofficial modified version of
[abcwyc/MeetMemo](https://github.com/abcwyc/MeetMemo).

Base upstream commit: `10d3b8c76dc6d94ef216d23cdbc7fc139acdb757`

Major changes:

- Preserve silence and continuous timestamps across microphone and system audio.
- Drain and finalize audio pipelines deterministically on stop.
- Prevent duplicate recognizer connections and stale session callbacks.
- Improve system-audio tap recovery and microphone restart continuity.
- Harden Sherpa runtime concurrency and speaker-clustering failure handling.
- Add an offline Command Line Tools build and local ad-hoc signing checks.

Maintained as a noncommercial personal project. The upstream Required Notice
and PolyForm Noncommercial License 1.0.0 remain in effect.
```

注意：这些修改说明是归属透明度和维护便利性的最佳实践；不要声称整个 MeetMemo 项目由用户原创。

## 8. 上传前检查

### 8.1 检查改动范围

```powershell
git status --short
git diff --check
git diff --stat
git diff --name-only
```

后续 AI 必须逐项确认：

- 没有 `.env` 实际密钥文件。
- 没有 API Key、Token、Cookie、证书、`.p12` 或 provisioning profile。
- 没有会议录音、转录文本、个人简历或面试资料。
- 没有 `dist`、`.app`、模型权重和下载的 `Frameworks`。
- `LICENSE` 和 Required Notice 仍然存在。
- remote 指向用户自己的仓库，不是直接向上游 main push。

### 8.2 暂存后再次检查

```powershell
git add -A
git diff --cached --check
git diff --cached --stat
git diff --cached --name-only
git diff --cached
git diff --cached --numstat
git grep --cached -n -I -E 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|ghp_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|api[_-]?key[[:space:]]*='
git ls-files | Select-String -Pattern '\.(p12|pfx|key|pem|wav|mp3|m4a|mov|mp4)$'
```

秘密扫描可能因为 `.env.template` 或示例字符串产生误报，AI 必须逐条人工判断，不能直接忽略。`git diff --cached --numstat` 中显示为 `- -` 的二进制文件也必须单独核对用途。AI 应展示完整 staged diff 摘要和异常匹配给用户确认，再提交。不要未经检查直接 `git add -A && git commit && git push`。

## 9. 提交并推送到用户自己的仓库

为了首次迁移简单，可以先做一个完整 Conventional Commit：

```powershell
git commit -m "fix: stabilize dual-audio capture and local app startup"
git push -u origin $Branch
```

如果后续 AI 能可靠拆分提交，建议拆成：

1. `fix: preserve continuous dual-audio transcription timelines`
2. `fix: harden recording finalization and provider lifecycle`
3. `build: add offline Command Line Tools app packaging`
4. `test: cover audio timeline and session concurrency`

不要为了拆分而遗漏文件或破坏当前已经能编译的快照。

## 10. 在自己的仓库创建 PR

先检查：

```powershell
gh pr status --repo "$GitHubUser/$RepoName"
```

创建 PR 最省心的方式：

```powershell
gh pr create --repo "$GitHubUser/$RepoName" --base main --head $Branch --draft --web
```

建议标题：

```text
fix: stabilize dual-audio capture and local app startup
```

建议正文：

```markdown
## Summary

- preserve silence so microphone and system-audio timestamps share a continuous timeline
- drain and finalize audio deterministically on stop
- prevent duplicate recognizer connections and stale callbacks
- improve tap/device-change recovery and Sherpa concurrency safety
- add an offline Apple Silicon build with local signing validation

## Validation

- full arm64 app compile and link succeeded on macOS 26.5
- app bundle, RPATH, entitlements, embedded ONNX Runtime and code signature verified
- corrected local build launches successfully
- Swift test sources parse successfully
- shell scripts pass `bash -n`
- `git diff --check` passes

## Remaining validation

- run a real Tencent Meeting or Feishu call with microphone and headphone system audio
- verify a long silence advances both source timestamps equally
- verify final words are retained after stopping
- full XCTest requires Xcode or a macOS CI runner

## Model scope

No ASR model was replaced. Existing SenseVoice, Fun-ASR-Nano and SpeechAnalyzer engines remain unchanged.
```

该命令会创建 Draft PR。检查 Files changed 后，再把它标记为 Ready 并合并进自己的 `main`。

## 11. 可选：向原作者提交上游 PR

这一步不是创建个人 public 仓库的必要条件。只有用户明确同意后才执行。

### 11.1 先阅读贡献条款

上游 `CONTRIBUTING.md` 规定：提交 PR 后，贡献者仍保留自己贡献的版权，但授权维护者在项目许可证下使用贡献，并可重新许可，包括向第三方提供商业许可证。

后续 AI 必须把这一点明确告诉用户，并在用户接受后再提交上游 PR。

另外，上游 `CONTRIBUTING.md` 明确要求 major changes 先开 Issue。本次属于重大改动，因此必须先搜索现有 Issue；若没有覆盖同一问题的 Issue，应先创建 Issue，解释时间轴根因和拟议方案，等待维护者反馈后再准备 PR。不要为了自动关闭 Issue 而盲目写 `Fixes #...`。

### 11.2 创建或复用官方 Fork

先在浏览器打开：<https://github.com/abcwyc/MeetMemo>，点击 `Fork`。

如果 `LingeringAutumn/MeetMemo` 已存在，先确认它确实属于 `abcwyc/MeetMemo` 的 Fork 网络：

```powershell
gh api "repos/$GitHubUser/MeetMemo" --jq '{fork: .fork, parent: .parent.full_name}'
```

只有输出同时满足 `fork: true` 且 `parent: abcwyc/MeetMemo` 时才可复用。若只是同名独立仓库，不能把它当作官方 Fork；应先让用户决定改名或处理现有仓库，禁止自动删除。

在本地添加 remote：

```powershell
git remote add personal-fork "https://github.com/$GitHubUser/MeetMemo.git"
git remote -v
```

如果 remote 已存在，先读取其 URL，不要直接覆盖：

```powershell
git remote get-url personal-fork
```

### 11.3 基于最新上游准备独立 PR 分支

不要直接复制个人仓库的整包提交，否则会把 `WINDOWS_GITHUB_HANDOFF.md`、个人 README 或其他只属于个人仓库的文件带进上游 PR。应从最新 `upstream/main` 创建干净分支，再只应用源码、测试与构建脚本差异：

```powershell
git fetch upstream
git switch -c "upstream-pr/continuous-dual-audio-timeline" upstream/main
$PatchFile = Join-Path $env:TEMP "meetmemo-upstream.patch"
git diff --output="$PatchFile" "$BaseCommit..$Branch" -- .gitignore MeetMemo MeetMemoTests scripts
git apply --3way "$PatchFile"
Remove-Item $PatchFile
git status --short
git diff --check
git add .gitignore MeetMemo MeetMemoTests scripts
git diff --cached --check
git diff --cached --stat
git diff --cached
git commit -m "fix: preserve continuous dual-audio transcription timelines"
git diff --stat upstream/main...HEAD
git diff upstream/main...HEAD
```

如果 `git apply --3way` 冲突，停止并逐文件解决；不要用 `git reset --hard` 或盲目选择 ours/theirs。推送前必须确认 diff 中不包含 `WINDOWS_GITHUB_HANDOFF.md`、个人 README 声明、会议数据或密钥。

随后推送到官方 Fork：

```powershell
git push -u personal-fork "upstream-pr/continuous-dual-audio-timeline"
```

如果更新已推送分支需要改写历史，只能在用户确认后使用：

```powershell
git push --force-with-lease personal-fork "upstream-pr/continuous-dual-audio-timeline"
```

禁止使用裸 `--force`。

### 11.4 创建上游 PR

```powershell
$UpstreamPRBranch = "upstream-pr/continuous-dual-audio-timeline"
gh pr create --repo abcwyc/MeetMemo --base main --head "${GitHubUser}:$UpstreamPRBranch" --web
```

PR 正文应：

- 解释丢弃系统静音导致采样时间轴压缩的根因。
- 说明模型没有更换。
- 列出测试和真实硬件验证边界。
- 不声称修复了“所有潜在 bug”。
- 链接前面按 `CONTRIBUTING.md` 要求创建或确认的 Issue；只有 PR 合并后确实应自动关闭时才写 `Fixes #...`。

## 12. Windows 上不能完成的验证

MeetMemo 是原生 macOS App。Windows 无法完成以下事项：

- 编译 SwiftUI/AppKit/macOS Framework 代码。
- 运行 Xcode XCTest test bundle。
- 验证麦克风与 Core Audio system tap。
- 对 `.app` 做 macOS codesign/TCC 实机验证。

可以选择：

1. 回到个人 Mac 上运行 `scripts/build_local_clt.sh` 并实测。
2. 在 public 仓库中增加 GitHub Actions macOS runner，但应由后续 AI先审查并获得用户同意。

不要在 Windows 上因为 `swiftc` 不可用就误判源码损坏。

## 13. 真实会议验收清单

在 Mac 上至少完成一次 5～10 分钟测试：

1. 戴耳机打开腾讯会议或飞书。
2. MeetMemo 先开始录制。
3. 自己说一句，系统端播放/让对方说一句。
4. 制造 15～30 秒双方都不说话的静音。
5. 再交替说话，确认静音后两个来源的时间戳都继续前进，没有一条被压短。
6. 录制期间切换一次麦克风设备，确认可以恢复且时间不倒退。
7. 停止后等待处理完成，确认最后一句没有丢失。
8. 连续开始/停止两次，确认没有重复文本或上一场内容混入。
9. 分别测试 SenseVoice 和用户实际准备使用的另一个模型。

只有通过这些步骤，才能说主要时间轴问题在真实环境中得到验证。

## 14. 后续 AI 的最终交付要求

操作结束后必须向用户报告：

- 独立 public 仓库的完整 URL。
- 分支名和提交 SHA。
- 自己仓库 PR 的完整 URL（如果创建）。
- 上游 PR 的完整 URL（只有确实创建时才报告）。
- LICENSE、Required Notice 和 README 来源声明是否保留。
- 实际执行了哪些检查，哪些 macOS 验证仍未执行。
- 明确说明没有上传密钥、会议数据、模型权重或编译产物。

不要编造构建成功、测试结果或 PR URL。

## 15. 官方参考资料

- 上游仓库：<https://github.com/abcwyc/MeetMemo>
- PolyForm Noncommercial 1.0.0：<https://polyformproject.org/licenses/noncommercial/1.0.0>
- GitHub：添加本地代码到新仓库：<https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github>
- GitHub：Fork 仓库：<https://docs.github.com/en/pull-requests/how-tos/work-with-forks/fork-a-repo?platform=windows>
- GitHub：配置 upstream remote：<https://docs.github.com/en/pull-requests/how-tos/work-with-forks/configuring-a-remote-repository-for-a-fork>
- GitHub：从 Fork 创建 PR：<https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-a-pull-request-from-a-fork>
- GitHub：设置仓库级 Git 用户名：<https://docs.github.com/en/get-started/git-basics/setting-your-username-in-git>
- GitHub CLI 登录：<https://cli.github.com/manual/gh_auth_login>
- GitHub CLI 创建仓库：<https://cli.github.com/manual/gh_repo_create>
- GitHub CLI 创建 PR：<https://cli.github.com/manual/gh_pr_create>
