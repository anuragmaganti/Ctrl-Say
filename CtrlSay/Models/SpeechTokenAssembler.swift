import Foundation

struct SpeechAttributedTextFragment: Sendable {
    let text: String
    let range: SpeechResultRange?
    let confidence: Double?

    init(
        _ text: String,
        range: SpeechResultRange? = nil,
        confidence: Double? = nil
    ) {
        self.text = text
        self.range = range
        self.confidence = confidence
    }
}

struct SpeechTokenAssembly: Sendable {
    let tokens: [StreamingNumberedCommandToken]
    let sourceFragmentCount: Int
    let inWordBoundaryMergeCount: Int
}

/// Converts SpeechTranscriber's attributed-text runs into lexical tokens.
///
/// AttributedString runs describe attribute boundaries, not word boundaries.
/// Confidence or audio-range changes can therefore split `pointer` into runs
/// such as `p` and `ointer` even though Apple delivered the complete word in
/// the same result. Command parsing must operate on reconstructed words.
enum SpeechTokenAssembler {
    private struct TokenBuilder {
        var text = ""
        var range: SpeechResultRange?
        var hasMissingRange = false
        var confidence: Double?
        var hasMissingConfidence = false

        mutating func append(
            _ character: Character,
            range fragmentRange: SpeechResultRange?,
            confidence fragmentConfidence: Double?
        ) {
            text.append(character)

            if let fragmentRange {
                range = range.map { $0.union(fragmentRange) } ?? fragmentRange
            } else {
                hasMissingRange = true
            }

            if let fragmentConfidence {
                confidence = confidence.map {
                    min($0, fragmentConfidence)
                } ?? fragmentConfidence
            } else {
                hasMissingConfidence = true
            }
        }

        var token: StreamingNumberedCommandToken {
            StreamingNumberedCommandToken(
                text,
                range: hasMissingRange ? nil : range,
                confidence: hasMissingConfidence ? nil : confidence
            )
        }
    }

    static func assemble(
        _ fragments: [SpeechAttributedTextFragment]
    ) -> SpeechTokenAssembly {
        var tokens: [StreamingNumberedCommandToken] = []
        var builder: TokenBuilder?
        var inWordBoundaryMergeCount = 0

        func isLexical(_ character: Character) -> Bool {
            character.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0)
            }
        }

        func flush(_ builder: inout TokenBuilder?) {
            guard let completed = builder, !completed.text.isEmpty else {
                builder = nil
                return
            }
            tokens.append(completed.token)
            builder = nil
        }

        for fragment in fragments {
            var isFirstCharacter = true
            for character in fragment.text {
                let isWordCharacter = isLexical(character)
                if isFirstCharacter,
                   isWordCharacter,
                   builder != nil {
                    inWordBoundaryMergeCount += 1
                }
                isFirstCharacter = false

                guard isWordCharacter else {
                    flush(&builder)
                    continue
                }

                if builder == nil {
                    builder = TokenBuilder()
                }
                builder?.append(
                    character,
                    range: fragment.range,
                    confidence: fragment.confidence
                )
            }
        }
        flush(&builder)

        return SpeechTokenAssembly(
            tokens: tokens,
            sourceFragmentCount: fragments.count,
            inWordBoundaryMergeCount: inWordBoundaryMergeCount
        )
    }
}
