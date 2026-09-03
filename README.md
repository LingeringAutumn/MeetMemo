<div align="center">
  <img src="docs/assets/meetmemo-icon.png" alt="MeetMemo Logo" width="80" height="80">


  <h3 align="center">MeetMemo</h3>

  <p align="center">
    免费、源码公开、运行在本地的 macOS AI 会议纪要助手
    <br />
    <a href="https://github.com/LingeringAutumn/MeetMemo/releases">前往 Releases 下载非官方测试版</a>
  </p>

</div>

## 简介

MeetMemo 是一款原生 macOS AI 会议记录工具。它可以同时捕获麦克风和系统音频，在本机完成实时转录，并结合会前资料、系统提示词和自定义模板，调用你自己配置的大模型生成结构化纪要。本修改版还可在录音停止后选择阿里云百炼文件转写；启用时会把本次双声道录音上传至你配置的阿里云账号。

适用于日常会议、站会、1on1、客户访谈、需求评审、招聘面试等场景。会议文件保存在本机；实时语音识别在本地运行。只有当你主动启用阿里云会后精准转写或调用自己配置的纪要大模型时，相应音频或文本才会发送给该服务商。

MeetMemo ：

- **本地语音识别**：内置 SenseVoice、Fun-ASR-Nano 与 macOS SpeechAnalyzer 三种转录引擎，下载模型后无需 STT API Key。
- **说话人识别（Speaker Diarization）**：选用 SenseVoice 或 Fun-ASR-Nano 时，可在双路录音基础上进一步区分发言人，纪要直接标注"谁说了什么"。
- **会前上下文注入**：单场会议可预加载项目背景、专有名词或参考文档，生成纪要时带入业务语境。
- **行动项落地**：纪要中的行动项可直接写入系统「提醒事项」，让会议结论转化为可跟踪的任务。
- **系统级语音输入**：可通过快捷键在微信、浏览器、Cursor、备忘录等前台应用中语音转文字并自动插入当前光标。
- **本地化 UI**：中英文界面一键切换，支持 macOS 浅色 / 深色外观。



- 转录原文

![](docs/assets/transcript.png)
- 会议纪要

![](docs/assets/meeting-summary.png)

- 自定义会议总结提示词

![](docs/assets/prompt-template.png)

## 核心特色

- **双路音频录制**：同时录制麦克风与系统音频，分别标记"自己"和"会议中的其他人"。
- **实时转录**：录制过程中持续接收流式语音识别结果，会议结束后保留完整转录原文，支持中途继续补录。
- **会后精准转写（可选）**：停止录音后可使用本地 Qwen3-ASR，或上传完整双声道 WAV 到阿里云百炼异步转写；原文页会显示上传、处理、下载和完成来源，云端失败时保留本地文字并自动尝试本地兜底。
- **本地多引擎语音识别**：转录完全在本机运行，无需 STT API Key。可按场景选择：
  - **SenseVoice（sherpa-onnx）**：约 240MB，小模型、低资源占用，兼容 macOS 15.5+，支持说话人识别；适合作为默认引擎。
  - **Fun-ASR-Nano（sherpa-onnx）**：约 1GB，高精度多语言 / 方言识别，支持说话人识别；更适合重视准确率的会议。
  - **macOS 内置（SpeechAnalyzer）**：需 macOS 26+，无需下载第三方模型，当前暂不支持说话人区分。
- **音频文件导入**：支持导入音频或视频文件，转写为一场新的会议记录。
- **AI 智能纪要**：基于转录内容流式生成纪要，支持 Markdown 与结构化内容提取，并在标题为空时自动生成会议标题。
- **会前资料补充**：可为单场会议添加背景信息、补充说明或文件内容，让生成结果更贴合业务语境，减少后期人工校对。
- **行动项与提醒**：从纪要中提取行动项（待办任务），选择提醒列表后可一键加入 macOS 系统「提醒事项」App，也可从 MeetMemo 中移除已同步任务。
- **系统级语音输入**：启用后可使用右 Command 等快捷键触发听写，停止后自动插入前台应用光标位置；支持短按 / 双击触发，并可自动过滤口头语、整理标点。
- **模板化输出**：内置 7 套模板——标准会议、一对一沟通、客户需求访谈、需求提报、招聘面试、每日站会、周团队会议，也支持创建和管理自定义提示词模板。
- **可配置 LLM 服务**：纪要生成支持 Anthropic Messages API，以及任意 OpenAI 兼容的 Chat Completions API（火山方舟、Kimi 等），模型自选。
- **系统提示词可编辑**：可以在设置中调整全局系统提示词，也可以为不同会议选择不同模板。
- **本地数据管理**：会议、摘要、结构化提取结果和模板以 JSON 文件保存在本机 Documents 目录；LLM 服务凭据保存在 macOS Keychain。
- **会议列表管理**：支持搜索、重命名、删除会议，并可一键复制会前资料、转录原文或智能纪要；支持导出 HTML 纪要。
- **中英文界面与外观设置**：支持中文 / 英文界面切换，以及浅色、深色外观。



## 系统要求

- macOS **15.5** 及以上（当前随包 onnxruntime 运行库的最低版本）。macOS **26.0** 及以上可选用系统 SpeechAnalyzer 引擎。
- 一个可用的大模型服务（Anthropic 或任意 OpenAI 兼容服务）及对应 API Key。
- 首次使用 SenseVoice 或 Fun-ASR-Nano 时需要下载本地模型；下载完成后转录可离线运行。

## 如何使用

### 1. 安装并打开

从个人仓库的 [Releases 页面](https://github.com/LingeringAutumn/MeetMemo/releases)选择明确标注为 `MeetMemo Interview` 的版本，下载其中的 Apple Silicon ZIP 与 `SHA256SUMS.txt`。校验 SHA-256 后解压，将 `MeetMemo Interview.app` 拖入“应用程序”。若该 Release 标注为 ad-hoc、未公证测试包，首次启动请在 Finder 中右键应用并选择“打开”。

首次启动会进入引导页，需要完成权限和服务配置。你也可以稍后在「设置」中重新配置。

### 2. 授权录音权限

MeetMemo 需要以下权限：

- **麦克风权限**：用于转录你在会议中说的话。
- **语音识别权限**：仅在选择 macOS 内置 SpeechAnalyzer 引擎时需要。
- **系统录音权限**：用于捕获线上会议、播放器或其他应用中的声音。
- **提醒事项权限（可选）**：用于把会议行动项写入系统「提醒事项」App。
- **辅助功能权限（可选）**：仅在启用系统级语音输入时需要，用于向前台应用插入文字。
- **输入监控权限（可选）**：仅在启用系统级语音输入时需要，用于接收全局快捷键。

如果授权失败，请到「系统设置 > 隐私与安全性」中为 MeetMemo 开启对应权限。

### 3. 选择并准备语音识别引擎

引导页默认准备本地 SenseVoice；你也可以稍后在「设置 > 模型」中切换语音识别引擎：

- **SenseVoice**：点击下载本地模型；推荐作为默认引擎，速度快、占用低，支持说话人识别。
- **Fun-ASR-Nano**：点击下载本地模型；准确率更高，模型更大，转写会在每句说完后稍有延迟，支持说话人识别。
- **macOS 内置（SpeechAnalyzer）**：仅 macOS 26+ 可用，检查 / 安装系统语音识别模型即可。

转录在本地运行，无需 STT API Key；首次安装 / 下载模型时可能需要网络。

### 4. 配置 LLM 服务

在「设置 > 模型 > LLM 配置」中填写：

- `API Key`
- `Base URL`
- `Model Name`

默认 `Base URL` 是 `https://api.anthropic.com`。当地址为 Anthropic 时，MeetMemo 会使用 Messages API；其他地址会按 OpenAI 兼容 Chat Completions API 调用。

常见示例：

```text
Anthropic:               https://api.anthropic.com
OpenAI-compatible:       https://api.example.com/v1
火山方舟 Ark:            https://ark.cn-beijing.volces.com/api/v3
火山方舟 Coding Plan:    https://ark.cn-beijing.volces.com/api/coding/v3
Kimi 官方:               https://api.moonshot.cn/v1
```

填写后可以点击「测试连接」确认配置是否可用。

### 5. 创建会议并录制

1. 点击侧边栏「创建会议」。
2. 在会议详情页点击「开始录制」。
3. 会议过程中查看「转录原文」。
4. 结束后点击「生成纪要」，选择合适的模板生成智能纪要。

如果会议中途需要继续补录，可以再次点击「继续录制」。

> 注意：录音过程中无法切换识别引擎，如需切换请先结束当前录音。

### 6. 导入已有音频

点击侧边栏「导入」，选择音频或视频文件。MeetMemo 会读取文件音频，转写为一场新的会议记录。

### 7. 使用会前资料和模板

在「会前资料」中添加背景信息、补充说明或文件内容，这些内容会和转录一起进入纪要生成流程。

在「设置 > 提示词 > 管理模板」中可以查看内置模板、创建自定义模板，并为不同会议选择不同的输出结构。

### 8. 管理结果与行动项

- 会议保存在侧边栏中，可搜索、重命名或删除。
- 打开任意会议后，可以复制当前标签页内容（会前资料、转录原文、智能纪要），或导出 HTML 纪要。
- 从纪要中提取行动项，确认后一键加入系统「提醒事项」App。

### 9. 使用系统级语音输入

在「设置 > 语音输入」中开启后，MeetMemo 可以作为全局听写工具使用：

1. 授权「辅助功能」和「输入监控」。
2. 选择触发按键（默认右 Command）和触发方式（短按或双击）。
3. 在任意前台应用中触发录音，说完后再次触发停止，识别结果会自动插入当前光标。

语音输入使用当前选择的 STT 引擎。会议录音进行中会暂停语音输入，避免同时抢占麦克风。

## 数据与隐私

- 会议文件、会议摘要和模板保存在本机 Documents 目录下的 `Meetings/`、`MeetingSummaries/`、`Templates/`（沙盒构建下位于应用容器内）。
- LLM 的 API Key、Base URL、模型名保存在 macOS Keychain。
- MeetMemo 不提供云端账号系统，也不会把会议数据同步到项目自有服务器。
- 录制期间的临时语音识别在本机进行。若选择“仅本地”，会后精转也不上传音频；若选择“阿里云精准”，停止后会将本次完整双声道 WAV 发送给阿里云百炼做异步转写。纪要生成、结构化提取和行动项提取会把必要文本发送到你配置的 LLM 服务。

## 本地开发

使用 Xcode 打开 `MeetMemo.xcodeproj`，选择 `MeetMemo` scheme 后构建运行。

```bash
xcodebuild -project MeetMemo.xcodeproj -scheme MeetMemo -configuration Debug build
```

> 修改原生 App 后请构建验证；仅构建即可，不需要在命令行启动应用。

本地 SenseVoice 引擎依赖 sherpa-onnx 预编译框架，未纳入版本库，请先拉取：

```bash
./scripts/fetch_sherpa_frameworks.sh
```

只有 Command Line Tools、没有完整 Xcode 时，可构建非公证的 Apple Silicon 测试包：

```bash
./scripts/build_local_clt.sh
```

默认输出 `MeetMemo Interview.app` 和 `MeetMemo-Interview-local-macos-arm64.zip`，Bundle ID 为 `io.github.lingeringautumn.meetmemo.interview`，可与上游并排安装。独立 Bundle ID 也意味着它有独立的会议数据、设置、系统权限和 Keychain，不会自动读取旧版数据。

只为本机覆盖旧安装、尝试沿用旧容器数据时，可显式运行 `MEETMEMO_BUILD_PROFILE=compatibility ./scripts/build_local_clt.sh`。该包沿用上游 Bundle ID，但 ad-hoc 签名的代码要求可能与旧安装不同，因此不能保证继承 sandbox、TCC 或 Keychain；覆盖前应备份，且仍可能需要重新授权和重填 Key。兼容包只能私人使用，绝不能作为本 Fork 的 GitHub Release 附件。两个 profile 都会从生成的 ZIP 往返解包，校验身份、签名、架构、entitlements、许可证哈希和 no-TTS 符号，并输出 `SHA256SUMS.txt` 与 `BUILD_VERIFICATION.md`。

项目架构说明详见 [`CLAUDE.md`](CLAUDE.md)。

## 发布新版本

发布构建需要自己的 Apple Developer ID。先用 `xcrun notarytool store-credentials` 把公证凭据交互式存入 macOS Keychain，再在权限为 `600` 的 `.env` 中只配置 `DEVELOPER_ID` 与 `NOTARY_PROFILE`；不要把 Apple ID 或 app-specific password 写入仓库或命令行参数。

### 准备

```bash
brew install create-dmg
chmod +x scripts/update_version.sh scripts/build_release.sh
```

### 更新版本号

```bash
./scripts/update_version.sh patch
./scripts/update_version.sh minor
./scripts/update_version.sh major
./scripts/update_version.sh custom 1.2.0
```

### 构建发布包

```bash
./scripts/build_release.sh
```

脚本会构建 Release 版本（arm64 + x86_64 通用二进制），验证完整许可证、签名、entitlements 与架构，在隐藏暂存目录完成 Apple 公证、staple 和 Gatekeeper 检查后，才生成正式 DMG、`SHA256SUMS.txt` 与 `BUILD_VERIFICATION.md`。

### 创建 GitHub Release

1. 打开当前维护仓库的 [GitHub Releases](https://github.com/LingeringAutumn/MeetMemo/releases)。
2. 创建新 release，tag 使用 `v版本号`，例如 `v0.4`。
3. 上传 `releases/` 目录下生成的 DMG。
4. 生成并补充 release notes。

## 贡献

欢迎提交 Issue 和 Pull Request，请遵循 [CONTRIBUTING.md](CONTRIBUTING.md)（含约定式提交规范）。

## 许可证

MeetMemo 采用 [PolyForm Noncommercial License 1.0.0](LICENSE)（非商业许可）发布。

这是基于 [abcwyc/MeetMemo](https://github.com/abcwyc/MeetMemo) 的非官方修改版本，不代表上游官方发布。请同时阅读 [NOTICE](NOTICE.md)、[第三方组件说明](THIRD_PARTY_NOTICES.md) 与随 App 一起分发的[完整第三方许可证目录](ThirdPartyLicenses/README.md)。

- 允许：个人、学习、研究、教育、慈善、政府等**任何非商业目的**的使用、修改与分发。
- 要求：修改或再分发时，必须保留版权声明（`Required Notice: Copyright (c) 2026 abcwyc`）与本许可证文本。

如需商业授权，请通过仓库 [Issues](https://github.com/abcwyc/MeetMemo/issues) 联系作者。
