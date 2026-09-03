import Foundation

/// Deterministic guardrails for generative ASR output.
///
/// Autoregressive recognizers can occasionally continue a short phrase in a decode loop
/// long after the audio has ended. The recognizer's text is untrusted input: reject obvious
/// loops before they reach the meeting transcript, then let the provider retry the same PCM
/// with a non-generative fallback recognizer when one is available.
struct ASRTranscriptQualityGate {
    enum RejectionReason: String, Equatable {
        case emptySpeechDecode
        case insufficientAudioEnergy
        case excessiveTextDensity
        case repeatedPattern
    }

    struct Evaluation: Equatable {
        let isAcceptable: Bool
        let rejectionReason: RejectionReason?

        static let accepted = Evaluation(isAcceptable: true, rejectionReason: nil)

        static func rejected(_ reason: RejectionReason) -> Evaluation {
            Evaluation(isAcceptable: false, rejectionReason: reason)
        }
    }

    /// Evaluates text against the exact PCM window that produced it.
    ///
    /// Thresholds intentionally have generous fixed headroom for acronyms, URLs and fast
    /// speech. They target catastrophic output (hundreds of characters from a few seconds),
    /// not stylistic repetition in normal conversation.
    static func evaluate(
        text: String,
        samples: [Float],
        sampleRate: Int = 16_000
    ) -> Evaluation {
        let normalized = normalizedTextUnits(text)
        guard !normalized.isEmpty else { return .accepted }

        if samples.count >= max(1, sampleRate / 10), rootMeanSquare(samples) < 0.0002 {
            return .rejected(.insufficientAudioEnergy)
        }

        if containsRunawayRepetition(normalized) {
            return .rejected(.repeatedPattern)
        }

        let duration = max(0.1, Double(samples.count) / Double(max(1, sampleRate)))
        let maximumPlausibleUnits = max(64, Int(ceil(duration * 18.0)) + 24)
        if normalized.count > maximumPlausibleUnits {
            return .rejected(.excessiveTextDensity)
        }

        return .accepted
    }

    private static func normalizedTextUnits(_ text: String) -> [Character] {
        let scalars = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return Array(String(String.UnicodeScalarView(scalars)))
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }

        // Sampling every fourth value is sufficient for a silence guard and avoids adding
        // noticeable CPU work to long VAD segments.
        var sumOfSquares = 0.0
        var count = 0
        var index = 0
        while index < samples.count {
            let value = Double(samples[index])
            sumOfSquares += value * value
            count += 1
            index += 4
        }
        return sqrt(sumOfSquares / Double(max(1, count)))
    }

    private static func containsRunawayRepetition(_ units: [Character]) -> Bool {
        guard units.count >= 20 else { return false }

        let maximumPatternLength = min(12, units.count / 4)
        if maximumPatternLength > 0 {
            for patternLength in 1...maximumPatternLength {
                let minimumRepetitions: Int
                switch patternLength {
                case 1: minimumRepetitions = 12
                case 2: minimumRepetitions = 7
                default: minimumRepetitions = 5
                }

                let requiredLength = patternLength * minimumRepetitions
                guard requiredLength <= units.count else { continue }

                for start in 0...(units.count - requiredLength) {
                    var repetitions = 1
                    while start + (repetitions + 1) * patternLength <= units.count {
                        let first = units[start..<(start + patternLength)]
                        let nextStart = start + repetitions * patternLength
                        let next = units[nextStart..<(nextStart + patternLength)]
                        guard first.elementsEqual(next) else { break }
                        repetitions += 1
                    }

                    let coveredUnits = repetitions * patternLength
                    if repetitions >= minimumRepetitions,
                       coveredUnits >= max(20, units.count / 3) {
                        return true
                    }
                }
            }
        }

        // Catch near-loops such as “那个谁啊、那个谁呢、那个谁吧”, where punctuation or
        // a changing suffix prevents a strictly consecutive repeated-pattern match.
        guard units.count >= 36 else { return false }
        var trigramCounts: [String: Int] = [:]
        for index in 0...(units.count - 3) {
            let trigram = String(units[index..<(index + 3)])
            trigramCounts[trigram, default: 0] += 1
        }
        let dominantCount = trigramCounts.values.max() ?? 0
        let trigramTotal = units.count - 2
        return dominantCount >= 6 && Double(dominantCount) / Double(trigramTotal) >= 0.18
    }
}

/// Detects short hallucinations repeated across adjacent VAD segments. A single-segment
/// gate cannot catch outputs such as one “那个谁” per noise burst because every individual
/// phrase is short and superficially plausible.
struct ASRTranscriptSequenceGate {
    private static let trailingParticles = Set("啊呀呢吧嘛哦噢呃额哈啦了")
    private static let minimumSignatureLength = 3
    private static let maximumSignatureLength = 40
    private static let rejectionRepeatCount = 3

    private var lastSignature = ""
    private var lastEndSampleOffset = 0
    private var repeatCount = 0

    mutating func shouldReject(
        text: String,
        startSampleOffset: Int,
        endSampleOffset: Int,
        sampleRate: Int = 16_000
    ) -> Bool {
        let signature = Self.signature(for: text)
        guard signature.count >= Self.minimumSignatureLength,
              signature.count <= Self.maximumSignatureLength else {
            reset()
            return false
        }

        let maximumGap = max(1, sampleRate) * 8
        let (continuityEnd, overflow) = lastEndSampleOffset.addingReportingOverflow(maximumGap)
        let isContinuous = startSampleOffset <= (overflow ? Int.max : continuityEnd)
            && endSampleOffset >= lastEndSampleOffset

        if signature == lastSignature, isContinuous {
            repeatCount += 1
        } else {
            lastSignature = signature
            repeatCount = 1
        }
        lastEndSampleOffset = max(lastEndSampleOffset, endSampleOffset)
        return repeatCount >= Self.rejectionRepeatCount
    }

    mutating func reset() {
        lastSignature = ""
        lastEndSampleOffset = 0
        repeatCount = 0
    }

    private static func signature(for text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        var characters = Array(String(String.UnicodeScalarView(scalars)))
        while characters.count > minimumSignatureLength,
              let last = characters.last,
              trailingParticles.contains(last) {
            characters.removeLast()
        }
        return String(characters)
    }
}
