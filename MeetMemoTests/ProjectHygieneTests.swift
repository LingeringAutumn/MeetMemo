import XCTest

final class ProjectHygieneTests: XCTestCase {
    func testRemovedTelemetryAndAutoUpdateDependenciesStayRemoved() throws {
        let root = repositoryRoot()
        let projectFile = try read("MeetMemo.xcodeproj/project.pbxproj", from: root)
        let readme = try read("README.md", from: root)
        let agents = try read("AGENTS.md", from: root)
        let claude = try read("CLAUDE.md", from: root)
        let releaseScript = try read("scripts/build_release.sh", from: root)

        for content in [projectFile, readme, agents, claude, releaseScript] {
            XCTAssertFalse(content.contains("PostHog"))
            XCTAssertFalse(content.contains("posthog"))
            XCTAssertFalse(content.contains("Sparkle"))
            XCTAssertFalse(content.contains("appcast"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("appcast.xml").path))

        let packageResolved = root.appendingPathComponent("MeetMemo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        if FileManager.default.fileExists(atPath: packageResolved.path) {
            let packageText = try String(contentsOf: packageResolved, encoding: .utf8)
            XCTAssertFalse(packageText.contains("PostHog"))
            XCTAssertFalse(packageText.contains("Sparkle"))
        }
    }

    func testCodeSigningVerifierDoesNotPrintNotarizationPassword() throws {
        let script = try read("scripts/verify_codesigning.sh", from: repositoryRoot())
        XCTAssertFalse(script.contains("APP_PASSWORD: $APP_PASSWORD"))
        XCTAssertTrue(script.contains("APP_PASSWORD: Set"))
    }

    func testSherpaBuildDependenciesStayPinnedAndChecksumVerified() throws {
        let root = repositoryRoot()
        let script = try read("scripts/fetch_sherpa_frameworks.sh", from: root)
        let project = try read("MeetMemo.xcodeproj/project.pbxproj", from: root)

        XCTAssertTrue(script.contains("readonly DEFAULT_SHERPA_ONNX_VERSION=\"v1.13.2\""))
        XCTAssertTrue(script.contains("readonly ONNXRUNTIME_VERSION=\"1.24.4\""))
        XCTAssertFalse(script.contains("SHERPA_ONNX_VERSION:-latest"))
        XCTAssertTrue(script.contains("verify_sha256"))
        XCTAssertTrue(script.contains("DEFAULT_XCFW_SHA256"))
        XCTAssertTrue(script.contains("DEFAULT_ORT_SHA256"))
        XCTAssertTrue(script.contains("DEFAULT_WRAPPER_SHA256"))
        XCTAssertTrue(script.contains("COMPILED_WRAPPER_SWIFT"))
        XCTAssertTrue(script.contains("onnxruntime_install_is_valid"))
        XCTAssertTrue(script.contains("The file was not installed."))
        XCTAssertTrue(project.contains("libonnxruntime.1.24.4.dylib"))
    }

    func testLocalCLTBuildStaysOfflineAndHandlesAdHocLibraryValidation() throws {
        let root = repositoryRoot()
        let script = try read("scripts/build_local_clt.sh", from: root)
        let releaseEntitlements = try read("MeetMemo/MeetMemo.entitlements", from: root)

        XCTAssertTrue(script.contains("swiftc \\"))
        XCTAssertTrue(script.contains("-target arm64-apple-macosx15.5"))
        XCTAssertTrue(script.contains("codesign --force --sign - \"${FRAMEWORKS_PATH}/${ONNXRUNTIME_NAME}\""))
        XCTAssertTrue(script.contains("cp \"$SOURCE_ENTITLEMENTS\" \"$LOCAL_ENTITLEMENTS\""))
        XCTAssertTrue(script.contains("Add :com.apple.security.cs.disable-library-validation bool true"))
        XCTAssertTrue(script.contains("--entitlements \"$LOCAL_ENTITLEMENTS\""))
        XCTAssertTrue(script.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(script.contains("codesign --display --entitlements \"$SIGNED_ENTITLEMENTS\""))
        XCTAssertTrue(script.contains("Print :com.apple.security.cs.disable-library-validation"))
        XCTAssertFalse(releaseEntitlements.contains("com.apple.security.cs.disable-library-validation"))
        XCTAssertFalse(script.contains("curl "))
        XCTAssertFalse(script.contains("gh "))
        XCTAssertFalse(script.contains("git push"))
    }

    func testAudioImportFlowKeepsFinalizationAndCancellationGuards() throws {
        let root = repositoryRoot()
        let transcriber = try read("MeetMemo/Services/AudioFileTranscriber.swift", from: root)
        let viewModel = try read("MeetMemo/ViewModels/MeetingListViewModel.swift", from: root)

        XCTAssertTrue(transcriber.contains("analyzer.analyzeSequence(from: file)"))
        XCTAssertTrue(transcriber.contains("analyzer.finalizeAndFinish(through: lastSample)"))
        XCTAssertTrue(viewModel.contains("try Task.checkCancellation()"))
    }

    func testSystemAudioUsesMeetingProcessAllowlistAndBuffersColdStartAudio() throws {
        let root = repositoryRoot()
        let audioManager = try read("MeetMemo/Managers/AudioManager.swift", from: root)
        let processTap = try read("MeetMemo/ProcessTap/ProcessTap.swift", from: root)

        XCTAssertTrue(audioManager.contains("resolveSupportedMeetingAudioProcesses()"))
        XCTAssertTrue(audioManager.contains("supportedMeetingProcessObjectIDs"))
        XCTAssertTrue(audioManager.contains("TapTarget.systemAudio(processObjectIDs: meetingProcessObjectIDs)"))
        XCTAssertFalse(audioManager.contains("TapTarget.systemAudio(processObjectIDs: [])"))
        XCTAssertFalse(processTap.contains("stereoGlobalTapButExcludeProcesses"))
        XCTAssertTrue(processTap.contains("CATapDescription(stereoMixdownOfProcesses: processObjectIDs)"))
        XCTAssertTrue(processTap.contains("noSupportedMeetingAudioProcess"))
        XCTAssertFalse(audioManager.contains("restartSystemAudioTapIfNeeded"))
        XCTAssertFalse(audioManager.contains("Task.sleep(for: .milliseconds(800))"))
        XCTAssertTrue(audioManager.contains("bufferPendingSystemAudio(data)"))
        XCTAssertTrue(audioManager.contains("systemSTTConnectingSessionID = sessionToken"))
        XCTAssertTrue(audioManager.contains("connectSTTProvider(\n                    for: .system,\n                    offsetMilliseconds: offset,\n                    sessionToken: sessionToken"))
    }

    func testRecordingStopSpinnerStaysUntilProviderCleanupCompletes() throws {
        let audioManager = try read("MeetMemo/Managers/AudioManager.swift", from: repositoryRoot())

        guard let disconnectRange = audioManager.range(of: "self.disconnectSTTProviders()"),
              let stopDoneRange = audioManager.range(of: "self.isStoppingRecording = false", range: disconnectRange.upperBound..<audioManager.endIndex) else {
            XCTFail("Expected stop finalization to clear isStoppingRecording after provider cleanup")
            return
        }

        XCTAssertLessThan(disconnectRange.lowerBound, stopDoneRange.lowerBound)
    }

    func testMeetingLogsDoNotExposeUserContentOrModelResponse() throws {
        let root = repositoryRoot()
        let viewModel = try read("MeetMemo/ViewModels/MeetingViewModel.swift", from: root)
        let extractor = try read("MeetMemo/Services/MeetingStructuredExtractor.swift", from: root)

        XCTAssertFalse(viewModel.contains("formattedMeetingContext.prefix"))
        XCTAssertFalse(extractor.contains("Structured extraction response prefix"))
        XCTAssertFalse(extractor.contains("String(cleaned.prefix"))
        XCTAssertFalse(extractor.contains("decode failed: \\(error)"))
    }

    func testRecoveredRecordingCannotStartAutomaticPostProcessing() throws {
        let root = repositoryRoot()
        let sessionManager = try read("MeetMemo/Managers/RecordingSessionManager.swift", from: root)
        let service = try read("MeetMemo/Services/AliyunPostRecordingTranscriptionService.swift", from: root)

        guard let recoveryStart = sessionManager.range(of: "private func recoverInterruptedRecordings()"),
              let recoveryEnd = sessionManager.range(
                of: "\n    }\n}",
                range: recoveryStart.upperBound..<sessionManager.endIndex
              ) else {
            XCTFail("Expected interrupted-recording recovery implementation")
            return
        }
        let recoveryBody = String(sessionManager[recoveryStart.lowerBound..<recoveryEnd.upperBound])
        XCTAssertTrue(recoveryBody.contains(".meetingRecordingArtifactRecovered"))
        XCTAssertFalse(recoveryBody.contains(".meetingRecordingArtifactReady"))

        guard let recoveredHandlerStart = service.range(of: "private func handleRecoveredArtifact"),
              let cloudStart = service.range(
                of: "private func startCloudTranscription",
                range: recoveredHandlerStart.upperBound..<service.endIndex
              ) else {
            XCTFail("Expected recovered and automatic transcription handlers")
            return
        }
        let recoveredHandler = String(service[recoveredHandlerStart.lowerBound..<cloudStart.lowerBound])
        XCTAssertFalse(recoveredHandler.contains("startCloudTranscription("))
        XCTAssertFalse(recoveredHandler.contains("startLocalQwenTranscription("))
    }

    func testPrivacyUsageDescriptionsDoNotPromiseAudioNeverLeavesTheDevice() throws {
        let plist = try read("MeetMemo/Info.plist", from: repositoryRoot())
        XCTAssertFalse(plist.localizedCaseInsensitiveContains("never leaves"))
        XCTAssertTrue(plist.contains("unless you enable optional cloud-accurate transcription"))
    }

    func testAppSourcesAvoidCrashOnlyShortcutsOutsideGeneratedBridge() throws {
        let root = repositoryRoot()
        let appRoot = root.appendingPathComponent("MeetMemo")
        let riskyPatterns = ["as!", "try!", "fatalError("]
        var violations: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("Could not enumerate app sources")
            return
        }

        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            if relativePath.hasPrefix("MeetMemo/SherpaOnnxBridge/") {
                continue
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in riskyPatterns where source.contains(pattern) {
                violations.append("\(relativePath) contains \(pattern)")
            }
        }

        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String, from root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
