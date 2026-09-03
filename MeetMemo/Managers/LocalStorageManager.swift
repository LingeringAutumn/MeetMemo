// LocalStorageManager.swift
// Handles local storage of meetings and app data

import Foundation

/// Replaces only the portions of a source timeline that an accurate recognizer actually
/// returned. Missing channels and quality-gated holes intentionally retain the live draft.
enum AccurateTranscriptReplacement {
    private struct CoverageSpan {
        var start: Int
        var end: Int
    }

    static func merging(
        existing: [TranscriptChunk],
        replacement: [TranscriptChunk],
        replacementStartMilliseconds: Int,
        replacementEndMilliseconds: Int,
        boundaryToleranceMilliseconds: Int = 500
    ) -> [TranscriptChunk] {
        let rangeStart = max(0, replacementStartMilliseconds)
        let rangeEnd = max(rangeStart, replacementEndMilliseconds)
        guard rangeEnd > rangeStart else { return existing.sortedByTranscriptTimeline() }
        let tolerance = max(0, boundaryToleranceMilliseconds)
        var exactCoverageBySource: [AudioSource: [CoverageSpan]] = [:]

        for chunk in replacement {
            guard let start = chunk.startTime, let end = chunk.endTime, end >= start else { continue }
            let exactStart = max(rangeStart, start)
            let exactEnd = min(rangeEnd, end)
            guard exactEnd > exactStart else { continue }
            exactCoverageBySource[chunk.source, default: []].append(CoverageSpan(
                start: exactStart,
                end: exactEnd
            ))
        }

        var toleratedCoverageBySource: [AudioSource: [CoverageSpan]] = [:]
        for source in Array(exactCoverageBySource.keys) {
            let sorted = exactCoverageBySource[source, default: []].sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }
            var merged: [CoverageSpan] = []
            for span in sorted {
                guard var last = merged.popLast() else {
                    merged.append(span)
                    continue
                }
                // Merge only spans that genuinely overlap. Bridging a recognition
                // gap would delete useful live draft text rejected by the quality gate.
                if span.start <= last.end {
                    last.end = max(last.end, span.end)
                    merged.append(last)
                } else {
                    merged.append(last)
                    merged.append(span)
                }
            }
            exactCoverageBySource[source] = merged

            // Apply boundary jitter tolerance only to the outer edges of each real
            // connected component. Expanding each accurate chunk before merging can
            // bridge a quality-gated hole and make an old chunk look fully covered.
            // Keep the expanded components separate even if their tolerated edges
            // overlap; an internal hole must never become replacement coverage.
            toleratedCoverageBySource[source] = merged.compactMap { span in
                let expandedStart = max(rangeStart, span.start - min(span.start, tolerance))
                let (expandedEnd, overflow) = span.end.addingReportingOverflow(tolerance)
                let boundedEnd = min(rangeEnd, overflow ? Int.max : expandedEnd)
                guard boundedEnd > expandedStart else { return nil }
                return CoverageSpan(start: expandedStart, end: boundedEnd)
            }
        }

        var result = existing.filter { chunk in
            guard let spans = toleratedCoverageBySource[chunk.source], !spans.isEmpty,
                  let rawStart = chunk.startTime ?? chunk.endTime,
                  let rawEnd = chunk.endTime ?? chunk.startTime else {
                return true
            }
            let start = min(rawStart, rawEnd)
            let end = max(rawStart, rawEnd)
            guard let exactSpans = exactCoverageBySource[chunk.source] else { return true }

            // Chunks are the smallest durable unit, so a partial overwrite cannot be
            // represented without inventing word-level timestamps. Delete an old chunk
            // only when an accurate span really overlaps it and its expanded boundary
            // fully contains the old chunk. For partial overlap, preserving a possible
            // duplicate is safer than losing the uncovered words on either side.
            let hasPositiveExactOverlap = exactSpans.contains { span in
                max(start, span.start) < min(end, span.end)
            }
            let isFullyCovered = spans.contains { span in
                start >= span.start && end <= span.end
            }
            return !(hasPositiveExactOverlap && isFullyCovered)
        }
        result.append(contentsOf: replacement)
        result.sortByTranscriptTimeline()
        return result
    }
}

/// Manages local file storage for meetings and app data
class LocalStorageManager {
    static let shared = LocalStorageManager()
    
    private let documentsDirectory: URL
    private let meetingsDirectory: URL
    private let meetingSummariesDirectory: URL
    private let templatesDirectory: URL
    private let migrationQuarantineDirectory: URL
    private let storageLock = NSRecursiveLock()
    private var deletedMeetingIDs = Set<UUID>()
    private var hasCreatedMigrationBackup = false
    
    private init() {
        // The Documents directory should always exist for the app container, but keep
        // storage initialization fallible-safe so a system lookup failure cannot crash launch.
        if let directory = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            documentsDirectory = directory
        } else {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetMemo", isDirectory: true)
            print("⚠️ Failed to resolve Documents directory. Using temporary fallback: \(fallbackDirectory)")
            documentsDirectory = fallbackDirectory
        }
        
        // Create meetings subdirectory
        meetingsDirectory = documentsDirectory.appendingPathComponent("Meetings")
        meetingSummariesDirectory = documentsDirectory.appendingPathComponent("MeetingSummaries")
        
        // Create templates subdirectory
        templatesDirectory = documentsDirectory.appendingPathComponent("Templates")
        migrationQuarantineDirectory = documentsDirectory.appendingPathComponent("Meetings_Migration_Quarantine")
        
        // Ensure directories exist
        try? FileManager.default.createDirectory(at: meetingsDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: meetingSummariesDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: templatesDirectory,
                                               withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: migrationQuarantineDirectory,
                                               withIntermediateDirectories: true)
    }
    
    // MARK: - Meeting Management

    func prepareMigrationsForLaunch() {
        withStorageLock {
            guard !hasCreatedMigrationBackup else { return }
            guard meetingFilesContainOlderDataVersionLocked() else { return }
            _ = createMigrationBackupIfNeededLocked()
        }
    }
    
    /// Saves a meeting to local storage
    /// - Parameter meeting: The meeting to save
    /// - Returns: True if successful, false otherwise
    func saveMeeting(_ meeting: Meeting) -> Bool {
        withStorageLock {
            saveMeetingLocked(meeting)
        }
    }

    private func saveMeetingLocked(
        _ meeting: Meeting,
        preserveMissingFinalChunks: Bool = true
    ) -> Bool {
        guard !deletedMeetingIDs.contains(meeting.id) else {
            print("🚫 Skipping save for deleted meeting: \(meeting.id)")
            return false
        }

        let fileURL = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        var meetingToSave = mergedMeetingForSave(
            meeting,
            fileURL: fileURL,
            preserveMissingFinalChunks: preserveMissingFinalChunks
        )
        if meetingToSave.transcriptChunks.contains(where: { $0.source == .mic && $0.speakerTag == "candidate" }) {
            meetingToSave.speakerNameMappings["MIC:candidate"] =
                meetingToSave.speakerNameMappings["MIC:candidate"] ?? "候选人"
        }
        if meetingToSave.transcriptChunks.contains(where: { $0.source == .system && $0.speakerTag == "interviewer" }) {
            meetingToSave.speakerNameMappings["SYS:interviewer"] =
                meetingToSave.speakerNameMappings["SYS:interviewer"] ?? "面试官"
        }
        meetingToSave.syncLegacyUserNotesFromContext()
        meetingToSave.dataVersion = Meeting.currentDataVersion

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(meetingToSave)

            try replaceFileAtomically(at: fileURL, with: data)

            print("✅ Saved meeting: \(meeting.id)")
            saveMeetingSummary(MeetingSummary(meeting: meetingToSave))
            return true
        } catch {
            print("❌ Failed to save meeting: \(error)")
            return false
        }
    }

    private func mergedMeetingForSave(
        _ incoming: Meeting,
        fileURL: URL,
        preserveMissingFinalChunks: Bool
    ) -> Meeting {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return incoming
        }

        guard preserveMissingFinalChunks,
              let existing = loadMeetingFromFileLocked(fileURL) else {
            return incoming
        }

        return incoming.mergingForPersistence(
            with: existing,
            preserveMissingFinalChunks: preserveMissingFinalChunks
        )
    }

    /// Atomically replaces only the recording session represented by an accurate-transcription
    /// delivery. Delivered chunks are already on the absolute meeting timeline; this method deliberately
    /// bypasses the normal "preserve missing chunks" merge so superseded local chunks are
    /// not resurrected from disk. A failed save leaves the original meeting file untouched.
    func applyAliyunCloudTranscription(_ delivery: AliyunCloudTranscriptionDelivery) -> Meeting? {
        withStorageLock {
            guard var meeting = loadMeetingLocked(id: delivery.meetingID),
                  let replacementEnd = delivery.replacementEndMilliseconds,
                  replacementEnd > delivery.replacementStartMilliseconds else {
                return nil
            }

            let replacementStart = delivery.replacementStartMilliseconds
            let (toleratedEnd, endOverflow) = replacementEnd.addingReportingOverflow(1_000)
            let maximumAcceptedEnd = endOverflow ? Int.max : toleratedEnd
            let replacementChunks = delivery.result.chunks.compactMap { chunk -> TranscriptChunk? in
                guard let start = chunk.startTime, let end = chunk.endTime else { return nil }
                guard end >= start,
                      start < replacementEnd,
                      end > replacementStart,
                      end <= maximumAcceptedEnd else {
                    return nil
                }
                let boundedStart = max(replacementStart, start)
                let boundedEnd = min(replacementEnd, end)
                guard boundedEnd > boundedStart else { return nil }
                guard boundedStart != start || boundedEnd != end else { return chunk }
                let (timestampOffset, timestampOffsetOverflow) = boundedStart
                    .subtractingReportingOverflow(start)
                return TranscriptChunk(
                    id: chunk.id,
                    timestamp: chunk.timestamp.addingTimeInterval(
                        Double(timestampOffsetOverflow ? 0 : max(0, timestampOffset)) / 1_000
                    ),
                    source: chunk.source,
                    text: chunk.text,
                    isFinal: chunk.isFinal,
                    speakerTag: chunk.speakerTag,
                    speakerId: chunk.speakerId,
                    startTime: boundedStart,
                    endTime: boundedEnd,
                    isLowConfidence: chunk.isLowConfidence
                )
            }
            guard !replacementChunks.isEmpty else { return nil }

            // A dual-channel job can return only one populated channel, and the local
            // quality gate can deliberately omit a bad segment. Replace only the sources
            // and time spans for which accurate chunks exist so neither case deletes useful
            // live text from the other channel or from an uncovered hole.
            meeting.transcriptChunks = AccurateTranscriptReplacement.merging(
                existing: meeting.transcriptChunks,
                replacement: replacementChunks,
                replacementStartMilliseconds: replacementStart,
                replacementEndMilliseconds: replacementEnd
            )
            if meeting.transcriptRevision < Int.max {
                meeting.transcriptRevision += 1
            }
            // Keep explicit user names; cloud/local accurate engines only provide
            // defaults for stable source roles and must not silently rename people.
            meeting.speakerNameMappings.merge(delivery.result.speakerNameMappings) { existingName, _ in
                existingName
            }

            let receipt = AccurateTranscriptReceipt(
                artifactID: delivery.artifactID,
                recordingSessionID: delivery.recordingSessionID,
                engine: delivery.engine,
                modelName: delivery.modelName,
                replacementStartMilliseconds: replacementStart,
                replacementEndMilliseconds: replacementEnd
            )
            meeting.accurateTranscriptReceipts.removeAll { $0.artifactID == receipt.artifactID }
            meeting.accurateTranscriptReceipts.append(receipt)
            meeting.accurateTranscriptReceipts.sort { lhs, rhs in
                if lhs.replacementStartMilliseconds != rhs.replacementStartMilliseconds {
                    return lhs.replacementStartMilliseconds < rhs.replacementStartMilliseconds
                }
                return lhs.completedAt < rhs.completedAt
            }
            meeting.transcriptionProvenanceVersion = max(
                1,
                meeting.transcriptionProvenanceVersion
            )

            guard saveMeetingLocked(meeting, preserveMissingFinalChunks: false) else { return nil }
            // saveMeetingLocked normalizes default role mappings, legacy context,
            // and dataVersion before writing. Return that canonical persisted value
            // so the notification/UI cannot temporarily disagree with disk.
            return loadMeetingLocked(id: meeting.id) ?? meeting
        }
    }
    
    /// Loads all meetings from local storage
    /// - Returns: Array of meetings, sorted by date (newest first)
    func loadMeetings() -> [Meeting] {
        withStorageLock {
            loadMeetingsLocked()
        }
    }

    private func loadMeetingsLocked() -> [Meeting] {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: meetingsDirectory,
                                                                      includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let meetings = fileURLs.compactMap { url -> Meeting? in
                guard let data = try? Data(contentsOf: url),
                      let meeting = try? decoder.decode(Meeting.self, from: data) else {
                    print("⚠️ Failed to decode meeting at: \(url)")
                    return nil
                }
                // Forward-compatibility guard – skip if file was written by a newer build
                if meeting.dataVersion > Meeting.currentDataVersion {
                    print("🚫 Meeting \(meeting.id) written by newer app version (\(meeting.dataVersion)). Skipping load.")
                    return nil
                }

                // Check if migration is needed
                if meeting.dataVersion < Meeting.currentDataVersion {
                    _ = createMigrationBackupIfNeededLocked()

                    if let migratedMeeting = DataMigrationManager.shared.migrateMeeting(meeting) {
                        if saveMeeting(migratedMeeting) {
                            print("✅ Migrated and saved meeting: \(migratedMeeting.id)")
                            return migratedMeeting
                        }
                        print("❌ Failed to save migrated meeting: \(migratedMeeting.id)")
                        return migratedMeeting
                    } else {
                        print("❌ Failed to migrate meeting: \(meeting.id)")
                        quarantineMeetingFileLocked(url, meetingId: meeting.id, reason: "migration failed")
                    }
                    return nil
                }

                saveMeetingSummary(MeetingSummary(meeting: meeting))
                return meeting
            }
            
            return meetings.sorted { $0.date > $1.date }
        } catch {
            print("❌ Failed to load meetings: \(error)")
            return []
        }
    }

    /// Loads lightweight meeting summaries for the sidebar.
    /// Falls back to full meeting files for older data and writes summary files
    /// so the expensive path is paid only once.
    func loadMeetingSummaries() -> [MeetingSummary] {
        withStorageLock {
            loadMeetingSummariesLocked()
        }
    }

    private func loadMeetingSummariesLocked() -> [MeetingSummary] {
        do {
            let summaryURLs = try FileManager.default.contentsOfDirectory(
                at: meetingSummariesDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }

            if !summaryURLs.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                let summaries = summaryURLs.compactMap { url -> MeetingSummary? in
                    guard let data = try? Data(contentsOf: url),
                          let summary = try? decoder.decode(MeetingSummary.self, from: data),
                          summary.dataVersion <= Meeting.currentDataVersion else {
                        print("⚠️ Failed to decode meeting summary at: \(url)")
                        return nil
                    }
                    return summary
                }

                let summaryIds = Set(summaries.map(\.id))
                let meetingFileIds = meetingFileIds()
                let hasMissingSummaries = !meetingFileIds.isSubset(of: summaryIds)
                let hasInvalidSummaries = summaries.count != summaryURLs.count

                guard hasMissingSummaries || hasInvalidSummaries else {
                    return summaries.sorted { $0.date > $1.date }
                }

                print("⚠️ Meeting summaries are incomplete. Regenerating missing sidebar data.")
                var mergedById = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
                for fullSummary in loadMeetings().map(MeetingSummary.init(meeting:)) {
                    mergedById[fullSummary.id] = fullSummary
                }

                return Array(mergedById.values).sorted { $0.date > $1.date }
            }
        } catch {
            print("⚠️ Failed to read meeting summaries: \(error)")
        }

        return loadMeetings().map(MeetingSummary.init(meeting:))
    }

    private func meetingFileIds() -> Set<UUID> {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return Set(fileURLs.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        })
    }

    private func meetingFilesContainOlderDataVersionLocked() -> Bool {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return fileURLs.contains { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let meeting = try? decoder.decode(Meeting.self, from: data) else {
                return false
            }

            return meeting.dataVersion < Meeting.currentDataVersion
        }
    }

    private func createMigrationBackupIfNeededLocked() -> URL? {
        guard !hasCreatedMigrationBackup else { return nil }
        hasCreatedMigrationBackup = true
        return DataMigrationManager.shared.backupMeetingsDirectory()
    }

    /// Loads a single meeting from local storage.
    /// Use this when opening a detail view so large transcripts in unrelated
    /// meetings do not block navigation.
    /// - Parameter id: The meeting ID to load.
    /// - Returns: The decoded meeting, or nil if it cannot be loaded.
    func loadMeeting(id: UUID) -> Meeting? {
        withStorageLock {
            loadMeetingLocked(id: id)
        }
    }

    private func loadMeetingLocked(id: UUID) -> Meeting? {
        let fileURL = meetingsDirectory.appendingPathComponent("\(id.uuidString).json")

        guard let meeting = loadMeetingFromFileLocked(fileURL) else {
            return nil
        }

        guard meeting.dataVersion <= Meeting.currentDataVersion else {
            print("🚫 Meeting \(meeting.id) written by newer app version (\(meeting.dataVersion)). Skipping load.")
            return nil
        }

        if meeting.dataVersion < Meeting.currentDataVersion {
            _ = createMigrationBackupIfNeededLocked()
            guard let migratedMeeting = DataMigrationManager.shared.migrateMeeting(meeting) else {
                print("❌ Failed to migrate meeting: \(meeting.id)")
                quarantineMeetingFileLocked(fileURL, meetingId: meeting.id, reason: "migration failed")
                return nil
            }

            if !saveMeetingLocked(migratedMeeting) {
                print("❌ Failed to save migrated meeting: \(migratedMeeting.id). Using migrated in-memory copy.")
            }
            return migratedMeeting
        }

        return meeting
    }

    private func loadMeetingFromFileLocked(_ fileURL: URL) -> Meeting? {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            return try decoder.decode(Meeting.self, from: data)
        } catch {
            print("⚠️ Failed to load meeting at \(fileURL.lastPathComponent): \(error)")
            return nil
        }
    }
    
    /// Deletes a meeting from local storage
    /// - Parameter meeting: The meeting to delete
    /// - Returns: True if successful, false otherwise
    func deleteMeeting(_ meeting: Meeting) -> Bool {
        withStorageLock {
            deleteMeetingLocked(meeting.id)
        }
    }

    private func deleteMeetingLocked(_ meetingId: UUID) -> Bool {
        let fileURL = meetingsDirectory.appendingPathComponent("\(meetingId.uuidString).json")
        let summaryURL = meetingSummaryFileURL(for: meetingId)

        do {
            deletedMeetingIDs.insert(meetingId)
            try removeFileIfPresent(at: fileURL)
            try removeFileIfPresent(at: summaryURL)
            print("✅ Deleted meeting: \(meetingId)")
            return true
        } catch {
            // A partial filesystem failure must not permanently block a later retry.
            deletedMeetingIDs.remove(meetingId)
            print("❌ Failed to delete meeting: \(error)")
            return false
        }
    }

    func deleteMeetingSummary(_ summary: MeetingSummary) -> Bool {
        withStorageLock {
            deleteMeetingLocked(summary.id)
        }
    }

    private func removeFileIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func quarantineMeetingFileLocked(_ fileURL: URL, meetingId: UUID, reason: String) {
        do {
            try FileManager.default.createDirectory(at: migrationQuarantineDirectory,
                                                   withIntermediateDirectories: true)

            let destination = uniqueQuarantineURL(for: fileURL)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            try removeFileIfPresent(at: meetingSummaryFileURL(for: meetingId))
            print("🚧 Quarantined meeting \(meetingId) after \(reason): \(destination.lastPathComponent)")
        } catch {
            print("❌ Failed to quarantine meeting \(meetingId): \(error)")
        }
    }

    private func uniqueQuarantineURL(for fileURL: URL) -> URL {
        let baseURL = migrationQuarantineDirectory.appendingPathComponent(fileURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantinedName = "\(fileURL.deletingPathExtension().lastPathComponent)-\(timestamp).\(fileURL.pathExtension)"
        return migrationQuarantineDirectory.appendingPathComponent(quarantinedName)
    }

    private func saveMeetingSummary(_ summary: MeetingSummary) {
        let fileURL = meetingSummaryFileURL(for: summary.id)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(summary)
            try replaceFileAtomically(at: fileURL, with: data)
        } catch {
            print("⚠️ Failed to save meeting summary \(summary.id): \(error)")
        }
    }

    private func meetingSummaryFileURL(for id: UUID) -> URL {
        meetingSummariesDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    
    // MARK: - Template Management
    
    /// Saves a note template to local storage
    /// - Parameter template: The template to save
    /// - Returns: True if successful, false otherwise
    func saveTemplate(_ template: NoteTemplate) -> Bool {
        withStorageLock {
            saveTemplateLocked(template)
        }
    }

    private func saveTemplateLocked(_ template: NoteTemplate) -> Bool {
        let fileURL = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            
            let data = try encoder.encode(template)
            try replaceFileAtomically(at: fileURL, with: data)

            print("✅ Saved template: \(template.id)")
            return true
        } catch {
            print("❌ Failed to save template: \(error)")
            return false
        }
    }
    
    /// Loads all templates from local storage
    /// - Returns: Array of templates, empty if none found
    func loadTemplates() -> [NoteTemplate] {
        withStorageLock {
            loadTemplatesLocked()
        }
    }

    private func loadTemplatesLocked() -> [NoteTemplate] {
        var templates: [NoteTemplate] = []
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: templatesDirectory,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)
            
            let decoder = JSONDecoder()
            
            for fileURL in fileURLs {
                guard fileURL.pathExtension == "json" else { continue }
                
                do {
                    let data = try Data(contentsOf: fileURL)
                    let template = try decoder.decode(NoteTemplate.self, from: data)
                    let migratedTemplate = template.migratedToPromptOnly()
                    if migratedTemplate != template {
                        _ = saveTemplateLocked(migratedTemplate)
                    }
                    templates.append(migratedTemplate)
                    print("✅ Loaded template: \(migratedTemplate.id)")
                } catch {
                    print("❌ Failed to load template from \(fileURL): \(error)")
                }
            }
        } catch {
            print("❌ Failed to read templates directory: \(error)")
        }
        
        migrateDefaultTemplatesIfNeeded(&templates)

        // Always ensure all default templates are available
        let defaultTemplates = NoteTemplate.defaultTemplates()
        let existingTitles = Set(templates.map { $0.title })
        
        // Add any missing default templates
        for defaultTemplate in defaultTemplates {
            if !existingTitles.contains(defaultTemplate.title) {
                _ = saveTemplateLocked(defaultTemplate)
                templates.append(defaultTemplate)
                print("✅ Added missing default template: \(defaultTemplate.title)")
            }
        }
        
        return templates.sorted { $0.title < $1.title }
    }

    /// Keeps bundled defaults available and removes historical default templates.
    private func migrateDefaultTemplatesIfNeeded(_ templates: inout [NoteTemplate]) {
        let defaultsByTitle = Dictionary(uniqueKeysWithValues: NoteTemplate.defaultTemplates().map { ($0.title, $0) })
        var defaultsByTitleToKeep: [String: NoteTemplate] = [:]
        var duplicateDefaultTemplates: [NoteTemplate] = []

        var customTemplates: [NoteTemplate] = []

        for template in templates {
            guard template.isDefault else {
                customTemplates.append(template)
                continue
            }

            if NoteTemplate.historicalDefaultTitles.contains(template.title) {
                deleteTemplateFile(template)
                continue
            }

            guard let bundledDefault = defaultsByTitle[template.title] else {
                customTemplates.append(template)
                continue
            }

            if defaultsByTitleToKeep[template.title] == nil {
                let templateToKeep = NoteTemplate(
                    id: template.id,
                    title: bundledDefault.title,
                    context: bundledDefault.context,
                    sections: bundledDefault.sections,
                    isDefault: true
                )
                _ = saveTemplateLocked(templateToKeep)
                defaultsByTitleToKeep[template.title] = templateToKeep
            } else {
                duplicateDefaultTemplates.append(template)
            }
        }

        for template in duplicateDefaultTemplates {
            deleteTemplateFile(template)
        }

        let defaultsToKeep = NoteTemplate.defaultTemplates().map { defaultTemplate -> NoteTemplate in
            if let existing = defaultsByTitleToKeep[defaultTemplate.title] {
                return existing
            }

            _ = saveTemplateLocked(defaultTemplate)
            return defaultTemplate
        }

        templates = (customTemplates + defaultsToKeep).sorted { $0.title < $1.title }
    }

    private func deleteTemplateFile(_ template: NoteTemplate) {
        try? FileManager.default.removeItem(at: templateFileURL(for: template))
    }

    private func templateFileURL(for template: NoteTemplate) -> URL {
        templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
    }
    
    /// Deletes a template from local storage
    /// - Parameter template: The template to delete
    /// - Returns: True if successful, false otherwise
    func deleteTemplate(_ template: NoteTemplate) -> Bool {
        withStorageLock {
            deleteTemplateLocked(template)
        }
    }

    private func deleteTemplateLocked(_ template: NoteTemplate) -> Bool {
        // Don't allow deletion of default templates
        if template.isDefault {
            print("⚠️ Cannot delete default template")
            return false
        }
        
        let fileURL = templatesDirectory.appendingPathComponent("\(template.id.uuidString).json")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            print("✅ Deleted template: \(template.id)")
            return true
        } catch {
            print("❌ Failed to delete template: \(error)")
            return false
        }
    }
    
    // MARK: - Settings Management
    
    /// Saves non-sensitive settings to local storage
    /// - Parameter settings: The settings to save (sensitive data should use Keychain)
    func saveSettings(_ settings: Settings) -> Bool {
        // For now, all settings are stored in Keychain
        // This method is here for future non-sensitive settings
        return true
    }
    
    /// Gets the app's documents directory URL
    var documentsDirectoryURL: URL {
        documentsDirectory
    }
    
    /// Gets the meetings directory URL
    var meetingsDirectoryURL: URL {
        meetingsDirectory
    }

    private func replaceFileAtomically(at fileURL: URL, with data: Data) throws {
        let tmpURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

        try data.write(to: tmpURL, options: .atomic)

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItem(
                    at: fileURL,
                    withItemAt: tmpURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    private func withStorageLock<T>(_ operation: () -> T) -> T {
        storageLock.lock()
        defer { storageLock.unlock() }
        return operation()
    }
} 
