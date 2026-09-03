import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject var langMgr: LanguageManager
    @ObservedObject private var appearanceMgr = AppearanceManager.shared
    @ObservedObject private var speechInstaller = SpeechModelInstaller.shared
    @ObservedObject private var sherpaModel = SherpaModelManager.shared
    @ObservedObject private var funASRNanoModel = FunASRNanoModelManager.shared
    @ObservedObject private var qwen3ASRModel = Qwen3ASRModelManager.shared
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var voiceInputHotkey = VoiceInputHotkeyManager.shared
    @ObservedObject private var voiceInputManager = VoiceInputManager.shared
    @Binding var navigationPath: NavigationPath
    @State private var selectedSection: SettingsSection = .general
    @State private var micPermissionGranted = false
    @State private var systemAudioPermissionGranted = false
    @State private var accessibilityPermissionGranted = false
    @State private var inputMonitoringPermissionGranted = false
    @State private var audioRecordingPermission = AudioRecordingPermission()
    @State private var sttEngine: STTEngine = UserDefaultsManager.shared.sttEngine
    @State private var cloudTranscriptionMode = UserDefaultsManager.shared.cloudTranscriptionMode
    @State private var voiceInputEnabled = UserDefaultsManager.shared.voiceInputEnabled
    @State private var voiceInputTriggerMode = UserDefaultsManager.shared.voiceInputTriggerMode
    @State private var voiceInputTriggerKey = VoiceInputTriggerKey.resolve(from: UserDefaultsManager.shared.voiceInputShortcut)
    @State private var voiceInputShortcut = UserDefaultsManager.shared.voiceInputShortcut
    @State private var voiceInputCleansText = UserDefaultsManager.shared.voiceInputCleansText
    private let llmSetupGuideURL = URL(string: "https://file.348580.xyz/2026/05/8fdfba8153b5029297b42f4ac6c4d00d.html")!

    init(viewModel: SettingsViewModel, navigationPath: Binding<NavigationPath> = .constant(NavigationPath())) {
        self.viewModel = viewModel
        self._navigationPath = navigationPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTabBar(selectedSection: $selectedSection)
                .environmentObject(langMgr)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedSection {
                    case .general:
                        generalSettings
                    case .model:
                        modelSettings
                    case .voiceInput:
                        voiceInputSettings
                    case .prompt:
                        promptSettings
                    }

                    saveButton
                }
                .padding(24)
            }
        }
        .navigationTitle(langMgr.t("设置", "Settings"))
        .frame(minWidth: 600, minHeight: 600)
        .onAppear {
            viewModel.loadTemplates()
            viewModel.loadProviderConfig()
            checkPermissions()
            if sttEngine == .appleSpeechAnalyzer && !isAppleSpeechAnalyzerAvailable {
                sttEngine = .sherpaSenseVoice
                UserDefaultsManager.shared.sttEngine = .sherpaSenseVoice
            }
            reloadVoiceInputSettings()
            VoiceInputHotkeyManager.shared.refresh()
            Task { await speechInstaller.checkModelAvailability() }
            Task { await sherpaModel.refreshReadiness() }
            Task { await funASRNanoModel.refreshReadiness() }
            Task { await qwen3ASRModel.refreshReadiness() }
        }
        .onChange(of: audioRecordingPermission.status) { _, newValue in
            systemAudioPermissionGranted = (newValue == .authorized)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
            speechInstaller.refreshSpeechAuthorizationStatus()
            if voiceInputEnabled && inputMonitoringPermissionGranted {
                VoiceInputHotkeyManager.shared.refresh()
            }
            Task { await speechInstaller.checkModelAvailability() }
            Task { await sherpaModel.refreshReadiness() }
            Task { await funASRNanoModel.refreshReadiness() }
            Task { await qwen3ASRModel.refreshReadiness() }
        }
        .onDisappear {
            DispatchQueue.main.async {
                persistSettingsAndCloudMode(showMessage: false)
            }
        }
        .alert(item: $viewModel.activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(langMgr.t("确定", "OK")))
            )
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(langMgr.t("所需权限", "Required Permissions"))
                    .font(.headline)
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    PermissionRow(
                        title: langMgr.t("麦克风权限", "Microphone Access"),
                        description: langMgr.t("用于转录您在会议中说的话", "Required to transcribe what you say in meetings"),
                        isGranted: micPermissionGranted,
                        grantedLabel: langMgr.t("已授权", "Granted"),
                        enableLabel: langMgr.t("授权", "Enable"),
                        action: requestMicrophonePermission
                    )

                    if sttEngine == .appleSpeechAnalyzer {
                        PermissionRow(
                            title: langMgr.t("语音识别权限", "Speech Recognition"),
                            description: langMgr.t("允许 macOS 本地语音识别处理会议音频", "Allows macOS on-device speech recognition to process meeting audio"),
                            isGranted: speechInstaller.isSpeechAuthorized,
                            grantedLabel: speechInstaller.speechAuthorizationLabel,
                            enableLabel: langMgr.t("授权", "Enable"),
                            action: requestSpeechPermission
                        )
                    }

                    PermissionRow(
                        title: langMgr.t("系统录音权限", "System Audio Recording"),
                        description: langMgr.t("用于转录会议中他人说的话", "Required to transcribe what others say in meetings"),
                        isGranted: systemAudioPermissionGranted,
                        grantedLabel: langMgr.t("已授权", "Granted"),
                        enableLabel: langMgr.t("授权", "Enable"),
                        action: requestSystemAudioPermission
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("语言", "Language"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Picker("", selection: $langMgr.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("外观", "Appearance"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Picker("", selection: $appearanceMgr.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { mode in
                        Text(langMgr.t(mode.chineseLabel, mode.englishLabel)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            AppInfoCard()
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("语音识别", "Speech Recognition"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Picker("", selection: $sttEngine) {
                    Text("SenseVoice").tag(STTEngine.sherpaSenseVoice)
                    Text("Fun-ASR-Nano").tag(STTEngine.funASRNano)
                    Text(langMgr.t("macOS 内置", "macOS Built-in")).tag(STTEngine.appleSpeechAnalyzer)
                        .disabled(!isAppleSpeechAnalyzerAvailable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 420, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(audioManager.isRecording)
                .onChange(of: sttEngine) { _, newValue in
                    if newValue == .appleSpeechAnalyzer && !isAppleSpeechAnalyzerAvailable {
                        sttEngine = .sherpaSenseVoice
                        UserDefaultsManager.shared.sttEngine = .sherpaSenseVoice
                        return
                    }
                    UserDefaultsManager.shared.sttEngine = newValue
                }

                Text(sttEngineDescriptionText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if audioManager.isRecording {
                    Text(langMgr.t("录音过程中无法切换识别引擎，请先结束当前录音。",
                                   "Cannot switch the engine while recording. Stop the current session first."))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if sttEngine == .appleSpeechAnalyzer {
                    appleSpeechEngineCard
                } else if sttEngine == .funASRNano {
                    funASRNanoEngineCard
                } else {
                    sherpaSenseVoiceEngineCard
                }

                qwen3PostRecordingModelCard
            }

            aliyunAccurateTranscriptionSettings

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(langMgr.t("LLM 配置", "LLM Configuration"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        viewModel.testLLMConnection()
                    } label: {
                        if viewModel.isTestingLLM {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(langMgr.t("测试连接", "Test Connection"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isTestingLLM)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(langMgr.t(
                        "填写 Base URL、API Key 和 Model Name 即可。Anthropic 地址会使用 Messages API，其他地址会使用 OpenAI 兼容的 Chat Completions API。",
                        "Fill in Base URL, API Key, and Model Name. Anthropic URLs use the Messages API; other URLs use the OpenAI-compatible Chat Completions API."
                    ))
                    .foregroundColor(.secondary)

                    Link(
                        langMgr.t("LLM配置教程", "LLM Setup Guide"),
                        destination: llmSetupGuideURL
                    )
                    .buttonStyle(.link)
                }
                .font(.caption)

                SecureField("API Key", text: $viewModel.settings.llmApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                TextField("Base URL", text: $viewModel.settings.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                TextField("Model Name", text: $viewModel.settings.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var aliyunAccurateTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(langMgr.t("会后精准转写", "Post-recording Accurate Transcription"))
                .font(.headline)
                .foregroundColor(.primary)

            Picker("", selection: $cloudTranscriptionMode) {
                Text(langMgr.t("仅本地", "Local Only")).tag(CloudTranscriptionMode.localOnly)
                Text(langMgr.t("阿里云精准", "Alibaba Cloud Accurate")).tag(CloudTranscriptionMode.aliyunAccurate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360, alignment: .leading)
            .disabled(audioManager.isRecording)
            .onChange(of: cloudTranscriptionMode) { _, newValue in
                // Returning to local-only is an immediate safety action. Enabling cloud
                // becomes active only after Save succeeds and the Keychain write completes.
                if newValue == .localOnly {
                    UserDefaultsManager.shared.cloudTranscriptionMode = .localOnly
                }
            }

            Text(langMgr.t(
                "录制期间继续用本地模型显示临时文字。结束后，若选择阿里云精准，会上传本次同步双声道录音：声道 0 固定为候选人，声道 1 固定为面试官；失败时保留本地转写并可重试。",
                "Local live captions remain available while recording. After stopping, Alibaba Cloud Accurate uploads the synchronized stereo recording: channel 0 is always the candidate and channel 1 the interviewer. Local text is retained if the cloud job fails and the job can be retried."
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if cloudTranscriptionMode == .aliyunAccurate {
                HStack(spacing: 8) {
                    SecureField("DashScope API Key", text: $viewModel.aliyunDashScopeAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button(langMgr.t("测试连接", "Test")) {
                        viewModel.testAliyunConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        viewModel.isTestingAliyun
                            || viewModel.aliyunDashScopeAPIKey
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                    )
                }

                Label(
                    langMgr.t(
                        "密钥只保存在 macOS 钥匙串中，不会写入会议文件或日志。保存设置后才会启用云端模式；音频会发送到阿里云百炼，双声道通常按两个声道分别计费。",
                        "The key is stored only in macOS Keychain, never in meeting files or logs. Cloud mode is enabled only after saving; audio is sent to Alibaba Cloud Model Studio, and stereo audio is normally billed as two channels."
                    ),
                    systemImage: "lock.shield"
                )
                .font(.caption2)
                .foregroundColor(.secondary)

            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var voiceInputSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(langMgr.t("系统级语音输入", "System Voice Input"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Toggle(isOn: $voiceInputEnabled) {
                    Text(langMgr.t("启用语音输入", "Enable voice input"))
                }
                .onChange(of: voiceInputEnabled) { _, newValue in
                    UserDefaultsManager.shared.voiceInputEnabled = newValue
                    if newValue && !accessibilityPermissionGranted {
                        requestAccessibilityPermission()
                    }
                    if newValue && !inputMonitoringPermissionGranted {
                        requestInputMonitoringPermission()
                    }
                    VoiceInputHotkeyManager.shared.refresh()
                }

                Text(langMgr.t(
                    "可在微信、浏览器、Cursor、备忘录等前台应用中通过快捷键录音，停止后自动插入当前光标。",
                    "Use a shortcut to dictate into the frontmost app, including chat apps, browsers, Cursor, and Notes."
                ))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(langMgr.t("触发方式", "Trigger"))
                    .font(.headline)
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 15) {
                        Text(langMgr.t("快捷键", "Shortcut"))
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)

                        Picker("", selection: $voiceInputTriggerKey) {
                            ForEach(VoiceInputTriggerKey.allCases) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 190, alignment: .leading)
                        .onChange(of: voiceInputTriggerKey) { _, newValue in
                            voiceInputShortcut = newValue.shortcut
                            persistVoiceInputShortcut()
                        }

                        Picker("", selection: $voiceInputTriggerMode) {
                            Text(langMgr.t("短按", "Short Press")).tag(VoiceInputTriggerMode.singlePress)
                            Text(langMgr.t("双击", "Double Tap")).tag(VoiceInputTriggerMode.doublePress)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                        .onChange(of: voiceInputTriggerMode) { _, _ in
                            persistVoiceInputShortcut()
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                    }
                    .cornerRadius(8)

                    Text(voiceInputTriggerModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 10) {
                    Text(langMgr.t("当前：\(voiceInputShortcutSummaryText)", "Current: \(voiceInputShortcutSummaryText)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(langMgr.t("恢复默认", "Reset")) {
                        voiceInputShortcut = .defaultShortcut
                        voiceInputTriggerKey = .rightCommand
                        voiceInputTriggerMode = .singlePress
                        persistVoiceInputShortcut()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(langMgr.t("文本处理", "Text Processing"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Toggle(isOn: $voiceInputCleansText) {
                    Text(langMgr.t("自动过滤口头语并整理标点", "Remove filler words and tidy punctuation"))
                }
                .onChange(of: voiceInputCleansText) { _, newValue in
                    UserDefaultsManager.shared.voiceInputCleansText = newValue
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(langMgr.t("权限与状态", "Permissions & Status"))
                    .font(.headline)
                    .foregroundColor(.primary)

                PermissionRow(
                    title: langMgr.t("辅助功能权限", "Accessibility"),
                    description: langMgr.t("用于向前台应用插入文字", "Required to insert text into other apps"),
                    isGranted: accessibilityPermissionGranted,
                    grantedLabel: langMgr.t("已授权", "Granted"),
                    enableLabel: langMgr.t("授权", "Enable"),
                    action: requestAccessibilityPermission
                )

                PermissionRow(
                    title: langMgr.t("输入监控权限", "Input Monitoring"),
                    description: langMgr.t("用于接收全局快捷键按键事件", "Required to receive global shortcut key events"),
                    isGranted: inputMonitoringPermissionGranted,
                    grantedLabel: langMgr.t("已授权", "Granted"),
                    enableLabel: langMgr.t("授权", "Enable"),
                    action: requestInputMonitoringPermission
                )

                if let message = voiceInputHotkey.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Text(voiceInputHotkey.isMonitoring
                     ? langMgr.t("快捷键监听已启动", "Shortcut listener is running")
                     : langMgr.t("快捷键监听未启动", "Shortcut listener is not running"))
                    .font(.caption)
                    .foregroundColor(voiceInputHotkey.isMonitoring ? .secondary : .orange)

                if let message = voiceInputManager.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private var appleSpeechEngineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(langMgr.t("识别语言", "Recognition Language"))
                    .foregroundColor(.secondary)
                Spacer()
                Text(speechInstaller.resolvedLocaleIdentifier ?? UserDefaultsManager.shared.sttLocaleIdentifier)
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 10) {
                Image(systemName: speechInstaller.isModelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(speechInstaller.isModelReady ? .green : .secondary)
                Text(speechModelStatusText)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await speechInstaller.installModelIfNeeded() }
                } label: {
                    if speechInstaller.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(speechInstaller.isModelReady ? langMgr.t("重新检查", "Check Again") : langMgr.t("安装模型", "Install Model"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(speechInstaller.isInstalling)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var sttEngineDescriptionText: String {
        switch sttEngine {
        case .appleSpeechAnalyzer:
            if !isAppleSpeechAnalyzerAvailable {
                return langMgr.t(
                    "macOS 内置语音识别需要 macOS 26 或更高版本。建议使用本地 SenseVoice。",
                    "macOS built-in speech recognition requires macOS 26 or later. Local SenseVoice is recommended."
                )
            }
            return langMgr.t(
                "适合已升级到 macOS 26 及以上的设备，无需额外下载模型；当前暂不支持区分不同发言人。",
                "Best for devices running macOS 26 or later. No extra model download is needed; speaker separation is not currently supported."
            )
        case .sherpaSenseVoice:
            return langMgr.t(
                "本地小模型（约 240MB），速度快、资源占用低，兼容 macOS 15.5 及以上，支持区分不同发言人；首次启用前需先下载，下载后离线使用。准确率不如 Fun-ASR-Nano——若更看重识别准确率，请选择 Fun-ASR-Nano（模型更大、占用更高）。",
                "A small on-device model (~240 MB): fast and light on resources, compatible with macOS 15.5 or later, with speaker separation. Download once before first use, then runs offline. Accuracy is lower than Fun-ASR-Nano—if accuracy matters more, choose Fun-ASR-Nano (larger model, higher resource use)."
            )
        case .funASRNano:
            return langMgr.t(
                "实验性本地模型（约 1GB）。部分中文场景准确率较高，但生成式解码可能出现短语循环；程序会拦截明显异常结果。面试录制建议继续用稳定的 SenseVoice 预览，结束后再使用 Qwen3 或阿里云精准转写。",
                "Experimental local model (~1 GB). It can be accurate for some Chinese audio, but generative decoding may loop short phrases; obvious bad output is filtered. For interviews, use stable SenseVoice during capture and Qwen3 or Alibaba Cloud after recording."
            )
        }
    }

    private var isAppleSpeechAnalyzerAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private var funASRNanoEngineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(langMgr.t("引擎", "Engine"))
                    .foregroundColor(.secondary)
                Spacer()
                Text("sherpa-onnx · Fun-ASR-Nano int8")
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 10) {
                Image(systemName: funASRNanoModel.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(funASRNanoModel.isReady ? .green : .secondary)
                Text(funASRNanoModelStatusText)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await funASRNanoModel.prepareModels() }
                } label: {
                    if funASRNanoModel.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(funASRNanoModel.isReady ? langMgr.t("重新检查", "Check Again") : langMgr.t("下载模型", "Download Models"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(audioManager.isRecording || funASRNanoModel.isPreparing)
            }

            if funASRNanoModel.isPreparing, let progress = funASRNanoModel.downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            if let error = funASRNanoModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var qwen3PostRecordingModelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(langMgr.t("会后本地精准模型", "Post-recording Local Model"))
                        .font(.subheadline.weight(.semibold))
                    Text("sherpa-onnx · Qwen3-ASR-0.6B INT8")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(langMgr.t("顺序处理双轨", "Sequential dual-track"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(langMgr.t(
                "用于录制结束后的本地重转写，也是阿里云失败时的离线兜底。麦克风与系统音频会按共享时间轴逐轨处理，不会同时加载两个 Qwen 实例，也不会运行发言人聚类。",
                "Used for accurate local retranscription after recording and as the offline fallback for Alibaba Cloud. Mic and system tracks are processed sequentially on their shared timeline, without loading two Qwen instances or running speaker clustering."
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Image(systemName: qwen3ASRModel.isReady ? "checkmark.shield.fill" : "arrow.down.circle")
                    .foregroundColor(qwen3ASRModel.isReady ? .green : .secondary)
                Text(qwen3ASRModelStatusText)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await qwen3ASRModel.prepareModels() }
                } label: {
                    if qwen3ASRModel.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(qwen3ASRModel.isReady
                             ? langMgr.t("重新校验", "Verify Again")
                             : langMgr.t("下载模型", "Download Models"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(audioManager.isRecording || qwen3ASRModel.isPreparing)
            }

            if qwen3ASRModel.isPreparing, let progress = qwen3ASRModel.downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            if let error = qwen3ASRModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(langMgr.t(
                "优先从 ModelScope 国内节点下载，支持断点续传；Qwen 模型文件均经过 SHA-256 校验。",
                "Downloads from the mainland ModelScope mirror first, supports resume, and SHA-256 verifies every Qwen model file."
            ))
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var sherpaSenseVoiceEngineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(langMgr.t("引擎", "Engine"))
                    .foregroundColor(.secondary)
                Spacer()
                Text("sherpa-onnx · SenseVoice-Small INT8")
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 10) {
                Image(systemName: sherpaModel.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(sherpaModel.isReady ? .green : .secondary)
                Text(sherpaModelStatusText)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task {
                        do {
                            try await sherpaModel.installModelsIfNeeded()
                            await sherpaModel.refreshReadiness()
                        } catch {
                            // installError is already set by the manager; UI shows it via status text
                        }
                    }
                } label: {
                    if sherpaModel.isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(sherpaModel.isReady ? langMgr.t("重新检查", "Check Again") : langMgr.t("下载模型", "Download Models"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sherpaModel.isDownloading)
            }

            if let error = sherpaModel.installError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var sherpaModelStatusText: String {
        if sherpaModel.isDownloading {
            if let progress = sherpaModel.downloadProgress {
                return langMgr.t(
                    "正在下载 SenseVoice 模型 \(Int(progress * 100))%",
                    "Downloading SenseVoice models \(Int(progress * 100))%"
                )
            }
            return langMgr.t("正在下载 SenseVoice 模型", "Downloading SenseVoice models")
        }
        if sherpaModel.isReady {
            return langMgr.t("SenseVoice 模型已就绪", "SenseVoice models are ready")
        }
        return langMgr.t(
            "SenseVoice 模型尚未下载（约 \(senseVoiceInstallSizeText)）",
            "SenseVoice models not downloaded yet (~\(senseVoiceInstallSizeText))"
        )
    }

    private var funASRNanoModelStatusText: String {
        if funASRNanoModel.isPreparing {
            if let progress = funASRNanoModel.downloadProgress {
                let pct = Int(progress * 100)
                return langMgr.t("正在下载 Fun-ASR-Nano 模型（约 1GB）… \(pct)%", "Downloading Fun-ASR-Nano models (~1 GB)… \(pct)%")
            }
            return langMgr.t("正在准备 Fun-ASR-Nano 模型…", "Preparing Fun-ASR-Nano models…")
        }
        if funASRNanoModel.isReady {
            if let device = funASRNanoModel.lastDevice {
                return langMgr.t(
                    "Fun-ASR-Nano 模型已就绪（\(device)，缓存 \(funASRNanoModel.cacheSizeText)）",
                    "Fun-ASR-Nano models are ready (\(device), cache \(funASRNanoModel.cacheSizeText))"
                )
            }
            return langMgr.t(
                "Fun-ASR-Nano 模型可能已就绪（缓存 \(funASRNanoModel.cacheSizeText)）",
                "Fun-ASR-Nano models may be ready (cache \(funASRNanoModel.cacheSizeText))"
            )
        }
        return langMgr.t(
            "Fun-ASR-Nano 模型尚未下载或尚未检查",
            "Fun-ASR-Nano models are not downloaded or not checked yet"
        )
    }

    private var qwen3ASRModelStatusText: String {
        if qwen3ASRModel.isPreparing {
            if let progress = qwen3ASRModel.downloadProgress {
                return langMgr.t(
                    "正在下载并校验 Qwen3-ASR… \(Int(progress * 100))%",
                    "Downloading and verifying Qwen3-ASR… \(Int(progress * 100))%"
                )
            }
            return langMgr.t("正在准备 Qwen3-ASR…", "Preparing Qwen3-ASR…")
        }
        if qwen3ASRModel.isReady {
            return langMgr.t(
                "模型已就绪（缓存 \(qwen3ASRModel.cacheSizeText)）",
                "Model ready (\(qwen3ASRModel.cacheSizeText) cached)"
            )
        }
        return langMgr.t(
            "尚未下载（约 \(qwen3ASRModel.installSizeText)）",
            "Not downloaded (~\(qwen3ASRModel.installSizeText))"
        )
    }

    private var senseVoiceInstallSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sherpaModel.activeApproximateBytes)
    }

    private var promptSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("笔记模板", "Note Templates"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(langMgr.t("创建和管理笔记模板", "Create and manage note templates"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    navigationPath.append("templates")
                } label: {
                    Text(langMgr.t("管理模板", "Manage Templates"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("用户信息", "User Information"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(langMgr.t(
                    "在了解您的一些背景信息后，生成效果更佳。请填写您的姓名、职位、公司及其他相关信息。",
                    "Generated notes work best when they include a bit of your background. You should give your name, role, company, and any other relevant information."
                ))
                .font(.caption)
                .foregroundColor(.secondary)

                TextEditor(text: $viewModel.settings.userBlurb)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(langMgr.t("系统提示词", "System Prompt"))
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button {
                        viewModel.resetToDefaults()
                    } label: {
                        Text(langMgr.t("恢复默认", "Reset to Default"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                TextEditor(text: $viewModel.settings.systemPrompt)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    private var saveButton: some View {
        HStack {
            Spacer()

            Button {
                persistSettingsAndCloudMode(showMessage: true)
            } label: {
                Text(langMgr.t("保存设置", "Save Settings"))
                    .font(.headline)
                    .frame(width: 180)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.top)
    }

    private func persistSettingsAndCloudMode(showMessage: Bool) {
        let key = viewModel.aliyunDashScopeAPIKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cloudTranscriptionMode == .aliyunAccurate, key.isEmpty {
            if showMessage {
                viewModel.activeAlert = AlertMessage(
                    title: langMgr.t("设置保存失败", "Settings Save Failed"),
                    message: langMgr.t(
                        "启用阿里云精准转写前，请先填写 DashScope API Key。",
                        "Enter a DashScope API Key before enabling Alibaba Cloud Accurate."
                    )
                )
            }
            return
        }
        if viewModel.saveSettings(showMessage: showMessage) {
            UserDefaultsManager.shared.cloudTranscriptionMode = cloudTranscriptionMode
        }
    }

    private func checkPermissions() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioPermissionGranted = (audioRecordingPermission.status == .authorized)
        accessibilityPermissionGranted = VoiceInputTextInserter.shared.isAccessibilityTrusted
        inputMonitoringPermissionGranted = VoiceInputHotkeyManager.shared.hasInputMonitoringAccess
    }

    private var voiceInputShortcutSummaryText: String {
        switch voiceInputTriggerMode {
        case .singlePress, .keyCombination:
            return langMgr.t("\(voiceInputShortcut.displayName) · 短按", "\(voiceInputShortcut.displayName) · Short Press")
        case .doublePress:
            return langMgr.t("\(voiceInputShortcut.displayName) · 双击", "\(voiceInputShortcut.displayName) · Double Tap")
        case .pressAndHold:
            return langMgr.t("\(voiceInputShortcut.displayName) · 短按", "\(voiceInputShortcut.displayName) · Short Press")
        }
    }

    private var voiceInputTriggerModeDescription: String {
        switch voiceInputTriggerMode {
        case .singlePress, .keyCombination:
            return langMgr.t("短按：按一下开始说话，再按一下结束", "Short press: press once to start, press again to stop")
        case .doublePress:
            return langMgr.t("双击：快速按两下开始，点击任意键结束", "Double tap: double-tap to start, press any key to stop")
        case .pressAndHold:
            return langMgr.t("短按：按一下开始说话，再按一下结束", "Short press: press once to start, press again to stop")
        }
    }

    private func reloadVoiceInputSettings() {
        voiceInputEnabled = UserDefaultsManager.shared.voiceInputEnabled
        let storedMode = UserDefaultsManager.shared.voiceInputTriggerMode
        // UI only exposes short press and double tap; legacy modes fall back to short press.
        let normalizedMode: VoiceInputTriggerMode = (storedMode == .doublePress) ? .doublePress : .singlePress
        let storedShortcut = UserDefaultsManager.shared.voiceInputShortcut
        let resolvedKey = VoiceInputTriggerKey.resolve(from: storedShortcut)
        let normalizedShortcut = resolvedKey.shortcut

        voiceInputTriggerMode = normalizedMode
        voiceInputTriggerKey = resolvedKey
        voiceInputShortcut = normalizedShortcut
        voiceInputCleansText = UserDefaultsManager.shared.voiceInputCleansText

        if storedMode != normalizedMode {
            UserDefaultsManager.shared.voiceInputTriggerMode = normalizedMode
        }
        if storedShortcut != normalizedShortcut {
            UserDefaultsManager.shared.voiceInputShortcut = normalizedShortcut
        }
    }

    private func persistVoiceInputShortcut() {
        if let message = voiceInputShortcut.validationMessage(mode: voiceInputTriggerMode, using: langMgr) {
            viewModel.activeAlert = AlertMessage(
                title: langMgr.t("快捷键冲突", "Shortcut Conflict"),
                message: message
            )
            reloadVoiceInputSettings()
            return
        }

        UserDefaultsManager.shared.voiceInputTriggerMode = voiceInputTriggerMode
        UserDefaultsManager.shared.voiceInputShortcut = voiceInputShortcut
        VoiceInputHotkeyManager.shared.refresh()
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micPermissionGranted = granted
                if !granted {
                    viewModel.activeAlert = AlertMessage(
                        title: langMgr.t("需要权限", "Permission Required"),
                        message: langMgr.t(
                            "录制会议需要麦克风权限，请在「系统设置 > 隐私与安全性 > 麦克风」中开启。",
                            "Microphone access is required for recording meetings. Please enable it in System Preferences > Security & Privacy > Privacy > Microphone."
                        )
                    )
                }
            }
        }
    }

    private func requestSpeechPermission() {
        Task { @MainActor in
            let status = await speechInstaller.requestSpeechAuthorization()
            if status != .authorized {
                viewModel.activeAlert = AlertMessage(
                    title: langMgr.t("需要权限", "Permission Required"),
                    message: langMgr.t(
                        "转录会议需要语音识别权限，请在「系统设置 > 隐私与安全性 > 语音识别」中开启。",
                        "Speech recognition access is required for transcription. Enable it in System Settings > Privacy & Security > Speech Recognition."
                    )
                )
            }
        }
    }

    private func requestSystemAudioPermission() {
        audioRecordingPermission.request()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if audioRecordingPermission.status == .denied {
                viewModel.activeAlert = AlertMessage(
                    title: langMgr.t("需要权限", "Permission Required"),
                    message: langMgr.t(
                        "需要系统录音权限才能捕获他人的声音，请在「系统设置 > 隐私与安全性 > 麦克风」中为本应用开启。",
                        "System audio recording access is required to capture what others say in meetings. Please enable this app in System Preferences > Security & Privacy > Privacy > Microphone."
                    )
                )
            }
        }
    }

    private func requestAccessibilityPermission() {
        VoiceInputTextInserter.shared.requestAccessibilityTrust()
        accessibilityPermissionGranted = VoiceInputTextInserter.shared.isAccessibilityTrusted

        if !accessibilityPermissionGranted {
            openAccessibilitySettings()
            viewModel.activeAlert = AlertMessage(
                title: langMgr.t("需要权限", "Permission Required"),
                message: langMgr.t(
                    "请在「系统设置 > 隐私与安全性 > 辅助功能」中为 MeetMemo 开启权限，开启后回到本窗口会自动刷新状态。\n\n如果已经开启但仍提示未授权，请确认授权的是以下正在运行的应用：\n\(VoiceInputTextInserter.shared.accessibilityTrustDiagnostic)",
                    "Enable MeetMemo in System Settings > Privacy & Security > Accessibility. The status will refresh when you return to this window.\n\nIf it is already enabled but still appears unauthorized, confirm that System Settings granted access to this running app:\n\(VoiceInputTextInserter.shared.accessibilityTrustDiagnostic)"
                )
            )
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func requestInputMonitoringPermission() {
        inputMonitoringPermissionGranted = VoiceInputHotkeyManager.shared.requestInputMonitoringAccess()
        inputMonitoringPermissionGranted = VoiceInputHotkeyManager.shared.hasInputMonitoringAccess

        if !inputMonitoringPermissionGranted {
            openInputMonitoringSettings()
            viewModel.activeAlert = AlertMessage(
                title: langMgr.t("需要权限", "Permission Required"),
                message: langMgr.t(
                    "请在「系统设置 > 隐私与安全性 > 输入监控」中为 MeetMemo 开启权限。开启后可能需要重启 MeetMemo 才能开始监听快捷键。",
                    "Enable MeetMemo in System Settings > Privacy & Security > Input Monitoring. You may need to restart MeetMemo before global shortcuts start working."
                )
            )
        } else {
            VoiceInputHotkeyManager.shared.refresh()
        }
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var speechModelStatusText: String {
        if speechInstaller.isInstalling {
            if let progress = speechInstaller.installProgress {
                return langMgr.t(
                    "正在安装语音识别模型 \(Int(progress * 100))%",
                    "Installing speech recognition model \(Int(progress * 100))%"
                )
            }
            return langMgr.t("正在安装语音识别模型", "Installing speech recognition model")
        }

        if speechInstaller.isModelReady {
            return langMgr.t("语音识别模型已就绪", "Speech recognition model is ready")
        }

        return speechInstaller.installError ?? langMgr.t(
            "语音识别模型尚未安装",
            "Speech recognition model is not installed yet"
        )
    }
}

private struct AppInfoCard: View {
    private let forkURL = URL(string: "https://github.com/LingeringAutumn/MeetMemo")!
    private let upstreamURL = URL(string: "https://github.com/abcwyc/MeetMemo")!

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var versionText: String {
        if appVersion.isEmpty {
            return "Unofficial interview fork · Upstream by youcai"
        }

        return "Version \(appVersion) · Unofficial interview fork · Upstream by youcai"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("MeetMemo Interview")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("让会议记录更聪明")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(versionText)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.82))

                Link(destination: forkURL) {
                    HStack(spacing: 4) {
                        Text("修改版项目：LingeringAutumn/MeetMemo")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                }

                Link(destination: upstreamURL) {
                    HStack(spacing: 4) {
                        Text("上游项目：abcwyc/MeetMemo")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(.top, 4)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSectionTabBar: View {
    @EnvironmentObject var langMgr: LanguageManager
    @Binding var selectedSection: SettingsSection
    @State private var hoveredSection: SettingsSection?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Text(section.title(using: langMgr))
                        .font(.system(size: 13, weight: selectedSection == section ? .semibold : .medium))
                        .foregroundColor(selectedSection == section ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if selectedSection == section || hoveredSection == section {
                                Capsule(style: .continuous)
                                    .fill(tabBackgroundColor(for: section))
                            }
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { isHovering in
                    hoveredSection = isHovering ? section : (hoveredSection == section ? nil : hoveredSection)
                }
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabBackgroundColor(for section: SettingsSection) -> Color {
        if selectedSection == section {
            return Color.secondary.opacity(0.18)
        }

        return Color.secondary.opacity(0.10)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case model
    case voiceInput
    case prompt

    var id: Self { self }

    func title(using langMgr: LanguageManager) -> String {
        switch self {
        case .general:
            return langMgr.t("通用", "General")
        case .model:
            return langMgr.t("模型", "Model")
        case .voiceInput:
            return langMgr.t("语音输入", "Voice Input")
        case .prompt:
            return langMgr.t("提示词", "Prompt")
        }
    }
}

#if canImport(PreviewsMacros)
    #Preview {
        NavigationStack {
            SettingsView(viewModel: SettingsViewModel())
                .environmentObject(LanguageManager.shared)
        }
    }
#endif
