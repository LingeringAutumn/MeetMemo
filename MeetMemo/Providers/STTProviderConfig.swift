import Foundation

enum STTSpeakerMode: Hashable, Sendable {
    /// Imported/mixed recordings where multiple unknown people may share one audio stream.
    case diarized
    /// Live one-to-one capture: the host fixes identity from the physical audio source and the
    /// provider must not load or run CAM++ clustering.
    case fixedByAudioSource
}

struct STTProviderConfig: Hashable {
    var locale: Locale
    var engine: STTEngine
    var speakerMode: STTSpeakerMode
    /// Optional per-job domain terms (for example terms extracted from a JD).
    /// Providers without hotword support safely ignore this field.
    var hotwords: String

    var isConfigured: Bool { true }

    init(
        locale: Locale = Locale(identifier: "zh-CN"),
        engine: STTEngine = .sherpaSenseVoice,
        speakerMode: STTSpeakerMode = .diarized,
        hotwords: String = ""
    ) {
        self.locale = locale
        self.engine = engine
        self.speakerMode = speakerMode
        self.hotwords = hotwords
    }
}
