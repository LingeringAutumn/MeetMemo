import SwiftUI
import AudioToolbox
import OSLog
import Combine

struct AudioProcess: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case process
        case app
    }
    var id: pid_t
    var kind: Kind
    var name: String
    var audioActive: Bool
    var bundleID: String?
    var bundleURL: URL?
    var objectID: AudioObjectID
}

struct AudioProcessGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var processes: [AudioProcess]
}

extension AudioProcess.Kind {
    var defaultIcon: NSImage {
        switch self {
        case .process: NSWorkspace.shared.icon(for: .unixExecutable)
        case .app: NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}

extension AudioProcess {
    var icon: NSImage {
        guard let bundleURL else { return kind.defaultIcon }
        let image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

@MainActor
@Observable
final class AudioProcessController {

    /// Bundle identifiers observed for the supported meeting clients and their audio/helper
    /// processes. Matching uses an exact identifier or a dot-delimited child identifier so a
    /// similarly named, unrelated bundle cannot enter the capture allowlist.
    private nonisolated static let supportedMeetingBundleIdentifiers = [
        "com.tencent.meeting",
        "com.tencent.wemeet",
        "com.tencent.voov",
        "com.electron.lark",
        "com.bytedance.feishu",
        "com.bytedance.lark",
        "com.bytedance.larkaudioplugin",
        "com.larksuite.lark",
        "com.larksuite.suite"
    ]

    /// Executable names are a fallback for Core Audio process objects that do not publish a
    /// bundle identifier. Values are normalized before matching; helper suffixes are allowed
    /// only for an explicitly supported base name.
    private nonisolated static let supportedMeetingExecutableNames = [
        "tencentmeeting",
        "wemeet",
        "voov",
        "voovmeeting",
        "feishu",
        "lark",
        "larksuite",
        "byteviewaudiodevice",
        "腾讯会议",
        "飞书"
    ]

    private nonisolated static let supportedHelperSuffixes = [
        "app",
        "helper",
        "framework",
        "renderer",
        "gpu",
        "plugin",
        "iron",
        "audio",
        "audiodevice"
    ]

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.lingeringautumn.meetmemo.interview",
        category: String(describing: AudioProcessController.self)
    )

    private(set) var processes = [AudioProcess]() {
        didSet {
            guard processes != oldValue else { return }
            processGroups = AudioProcessGroup.groups(with: processes)
        }
    }

    private(set) var processGroups = [AudioProcessGroup]()

    private var cancellables = Set<AnyCancellable>()

    /// Resolves the Core Audio process object for the supplied BSD process id. A process that
    /// has not created a Core Audio object yet simply has no process object to return.
    nonisolated static func audioProcessObjectID(for processID: pid_t) -> AudioObjectID? {
        guard let objectID = try? AudioObjectID.translatePIDToProcessObjectID(pid: processID),
              objectID.isValid else {
            return nil
        }
        return objectID
    }

    nonisolated static var currentProcessAudioObjectID: AudioObjectID? {
        audioProcessObjectID(for: ProcessInfo.processInfo.processIdentifier)
    }

    /// Returns true only for Tencent Meeting/WeMeet/VooV and Feishu/Lark identities.
    /// Bundle identifiers take precedence; executable-name matching exists for helper/audio
    /// processes whose Core Audio metadata omits the bundle identifier.
    nonisolated static func isSupportedMeetingProcess(
        name: String,
        bundleID: String?,
        bundleName: String? = nil
    ) -> Bool {
        if let bundleID, !bundleID.isEmpty {
            let normalizedBundleID = bundleID.lowercased()
            return supportedMeetingBundleIdentifiers.contains(where: {
                normalizedBundleID == $0 || normalizedBundleID.hasPrefix($0 + ".")
            })
        }

        return [name, bundleName]
            .compactMap { $0 }
            .map(normalizedMeetingProcessIdentity)
            .contains(where: matchesSupportedExecutableName)
    }

    /// Pure allowlist filter used both by the Core Audio resolver and policy tests.
    nonisolated static func supportedMeetingProcessObjectIDs(
        in processes: [AudioProcess]
    ) -> [AudioObjectID] {
        var seen = Set<AudioObjectID>()
        return processes.compactMap { process in
            guard process.objectID.isValid,
                  isSupportedMeetingProcess(
                    name: process.name,
                    bundleID: process.bundleID,
                    bundleName: process.bundleURL?.deletingPathExtension().lastPathComponent
                  ),
                  seen.insert(process.objectID).inserted else {
                return nil
            }
            return process.objectID
        }
        .sorted()
    }

    /// Takes a fresh Core Audio process-list snapshot at recording start. The result is an
    /// explicit capture allowlist; callers must treat an empty result as a hard refusal to
    /// create a system tap rather than falling back to global system audio.
    static func resolveSupportedMeetingAudioProcesses() throws -> [AudioProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID }
        let objectIdentifiers = try AudioObjectID.readProcessList()

        var seen = Set<AudioObjectID>()
        return objectIdentifiers.compactMap { objectID in
            guard objectID.isValid,
                  seen.insert(objectID).inserted,
                  let process = try? AudioProcess(
                    objectID: objectID,
                    runningApplications: runningApplications
                  ),
                  isSupportedMeetingProcess(
                    name: process.name,
                    bundleID: process.bundleID,
                    bundleName: process.bundleURL?.deletingPathExtension().lastPathComponent
                  ) else {
                return nil
            }
            return process
        }
        .sorted { $0.objectID < $1.objectID }
    }

    private nonisolated static func normalizedMeetingProcessIdentity(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private nonisolated static func matchesSupportedExecutableName(_ normalizedName: String) -> Bool {
        supportedMeetingExecutableNames.contains { baseName in
            guard normalizedName.hasPrefix(baseName) else { return false }
            let suffix = String(normalizedName.dropFirst(baseName.count))
            return suffix.isEmpty || supportedHelperSuffixes.contains(where: suffix.hasPrefix)
        }
    }

    func activate() {
        logger.debug(#function)

        NSWorkspace.shared
            .publisher(for: \.runningApplications, options: [.initial, .new])
            .map { $0.filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) }
            .sink { [weak self] apps in
                guard let self else { return }
                self.reload(apps: apps)
            }
            .store(in: &cancellables)
    }

    func refresh() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        reload(apps: apps)
    }

    private func reload(apps: [NSRunningApplication]) {
        logger.debug(#function)

        do {
            let objectIdentifiers = try AudioObjectID.readProcessList()
            
            let updatedProcesses: [AudioProcess] = objectIdentifiers.compactMap { objectID in
                do {
                    let proc = try AudioProcess(objectID: objectID, runningApplications: apps)

                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "ACDumpProcessInfo") {
                        logger.debug("[PROCESS] \(String(describing: proc))")
                    }
                    #endif

                    return proc
                } catch {
                    logger.warning("Failed to initialize process with object ID #\(objectID, privacy: .public): \(error, privacy: .public)")
                    return nil
                }
            }

            self.processes = updatedProcesses
                .sorted {
                    if $0.name.localizedStandardCompare($1.name) == .orderedAscending {
                        $1.audioActive && !$0.audioActive ? false : true
                    } else {
                        $0.audioActive && !$1.audioActive ? true : false
                    }
                }
        } catch {
            logger.error("Error reading process list: \(error, privacy: .public)")
        }
    }

}

private extension AudioProcess {
    init(app: NSRunningApplication, objectID: AudioObjectID) {
        let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.bundleIdentifier?.components(separatedBy: ".").last ?? "Unknown \(app.processIdentifier)"

        self.init(
            id: app.processIdentifier,
            kind: .app,
            name: name,
            audioActive: objectID.readProcessIsRunning(),
            bundleID: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            objectID: objectID
        )
    }

    init(objectID: AudioObjectID, runningApplications apps: [NSRunningApplication]) throws {
        let pid: pid_t = try objectID.read(kAudioProcessPropertyPID, defaultValue: -1)

        if let app = apps.first(where: { $0.processIdentifier == pid }) {
            self.init(app: app, objectID: objectID)
        } else {
            try self.init(objectID: objectID, pid: pid)
        }
    }

    init(objectID: AudioObjectID, pid: pid_t) throws {
        let bundleID = objectID.readProcessBundleID()
        let bundleURL: URL?
        let name: String

        (name, bundleURL) = if let info = processInfo(for: pid) {
            (info.name, URL(fileURLWithPath: info.path).parentBundleURL())
        } else if let id = bundleID?.lastReverseDNSComponent {
            (id, nil)
        } else {
            ("Unknown (\(pid))", nil)
        }

        self.init(
            id: pid,
            kind: bundleURL?.isApp == true ? .app : .process,
            name: name,
            audioActive: objectID.readProcessIsRunning(),
            bundleID: bundleID.flatMap { $0.isEmpty ? nil : $0 },
            bundleURL: bundleURL,
            objectID: objectID
        )
    }
}

extension AudioProcessGroup {
    static func groups(with processes: [AudioProcess]) -> [AudioProcessGroup] {
        var byKind = [AudioProcess.Kind: AudioProcessGroup]()

        for process in processes {
            byKind[process.kind, default: .init(for: process.kind)].processes.append(process)
        }

        return byKind.values.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }
}

extension AudioProcessGroup {
    init(for kind: AudioProcess.Kind) {
        self.init(id: kind.rawValue, title: kind.groupTitle, processes: [])
    }
}

extension AudioProcess.Kind {
    var groupTitle: String {
        switch self {
        case .process: "Processes"
        case .app: "Apps"
        }
    }
}

private func processInfo(for pid: pid_t) -> (name: String, path: String)? {
    let nameBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
    let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))

    defer {
        nameBuffer.deallocate()
        pathBuffer.deallocate()
    }

    let nameLength = proc_name(pid, nameBuffer, UInt32(MAXPATHLEN))
    let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))

    guard nameLength > 0, pathLength > 0 else {
        return nil
    }

    let name = String(cString: nameBuffer)
    let path = String(cString: pathBuffer)

    return (name, path)
}

private extension String {
    var lastReverseDNSComponent: String? {
        components(separatedBy: ".").last.flatMap { $0.isEmpty ? nil : $0 }
    }
}

private extension URL {
    func parentBundleURL(maxDepth: Int = 8) -> URL? {
        var depth = 0
        var url = deletingLastPathComponent()
        while depth < maxDepth, !url.isBundle {
            url = url.deletingLastPathComponent()
            depth += 1
        }
        return url.isBundle ? url : nil
    }

    var isBundle: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .bundle) == true
    }

    var isApp: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true
    }
} 
