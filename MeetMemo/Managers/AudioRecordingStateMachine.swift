import Foundation

enum AudioRecordingState: Equatable {
    case idle
    case starting(UUID)
    case recording(UUID)
    case stopping(UUID)
    case recovering(UUID)

    var sessionID: UUID? {
        switch self {
        case .idle:
            return nil
        case .starting(let id),
             .recording(let id),
             .stopping(let id),
             .recovering(let id):
            return id
        }
    }

    var isRecordingVisible: Bool {
        if case .recording = self { return true }
        if case .recovering = self { return true }
        return false
    }

    var isStopping: Bool {
        if case .stopping = self { return true }
        return false
    }

    var isRecovering: Bool {
        if case .recovering = self { return true }
        return false
    }

    func isActiveSession(_ id: UUID) -> Bool {
        sessionID == id && !isStopping
    }
}

struct AudioRecordingStateMachine {
    private(set) var state: AudioRecordingState = .idle

    /// Starts a new session only after the previous one has been fully reset.
    /// Returning `false` lets callers/tests detect duplicate or overlapping starts
    /// without allowing them to replace the active session identity.
    @discardableResult
    mutating func start(sessionID: UUID) -> Bool {
        guard case .idle = state else { return false }
        state = .starting(sessionID)
        return true
    }

    mutating func markRecording(sessionID: UUID) {
        guard state.isActiveSession(sessionID) else { return }
        state = .recording(sessionID)
    }

    mutating func markRecovering(sessionID: UUID) {
        guard state.isActiveSession(sessionID) else { return }
        state = .recovering(sessionID)
    }

    /// Stops only the session that currently owns the state machine. A late stop
    /// from an older session must never terminate a newer recording.
    @discardableResult
    mutating func stop(sessionID: UUID) -> Bool {
        guard state.sessionID == sessionID, !state.isStopping else { return false }
        state = .stopping(sessionID)
        return true
    }

    mutating func reset() {
        state = .idle
    }
}
