import Foundation

enum VoiceCommand: Equatable, Sendable {
    case copyNumber(Int)
    case pasteNumber(Int)
    case copyNamed(String)
    case permanentCopy(String)
    case pasteNamed(String)
    case deleteNamed(String)
    case clearTemporary

    var telemetryName: String {
        switch self {
        case .copyNumber: "copy-number"
        case .pasteNumber: "paste-number"
        case .copyNamed: "copy-temporary-named"
        case .permanentCopy: "copy-named"
        case .pasteNamed: "paste-named"
        case .deleteNamed: "delete-named"
        case .clearTemporary: "clear-temporary"
        }
    }

    var requiresExternalTarget: Bool {
        switch self {
        case .copyNumber, .pasteNumber, .copyNamed, .permanentCopy, .pasteNamed:
            true
        case .deleteNamed, .clearTemporary:
            false
        }
    }
}

enum VoiceCommandParser {
    static let canonicalSpokenSlotNumbers = [
        "one", "two", "three", "four", "five",
        "six", "seven", "eight", "nine", "ten",
    ]
    static let numberedSlotRange = 1...canonicalSpokenSlotNumbers.count

    // Scoped to the command verb position. These are common on-device
    // transcriptions of a spoken "paste" and must never rewrite slot names or
    // ordinary words elsewhere in an utterance.
    private static let pasteVerbAliases: Set<String> = [
        "pasting", "peace", "pace", "hase", "pase", "pay", "pae", "taste",
    ]

    private static let spokenNumberAliases: [String: Int] = [
        "won": 1,
        "to": 2, "too": 2,
        "for": 4, "fore": 4, "foor": 4,
        "ate": 8,
    ]
    private static let spokenNumbers: [String: Int] = {
        var numbers = Dictionary(
            uniqueKeysWithValues: canonicalSpokenSlotNumbers.enumerated().map {
                ($0.element, $0.offset + 1)
            }
        )
        numbers.merge(spokenNumberAliases) { canonical, _ in canonical }
        return numbers
    }()

    static func parse(_ transcript: String) -> VoiceCommand? {
        let tokens = normalizedTokens(transcript)

        if tokens == ["clear", "copies"] || tokens == ["clear", "numbered", "copies"] {
            return .clearTemporary
        }

        if tokens.count == 2, tokens[0] == "copy" {
            if let number = slotNumber(tokens[1]) {
                return .copyNumber(number)
            }
            return validTemporaryNameTokens([tokens[1]]).map(VoiceCommand.copyNamed)
        }

        if tokens.count == 2, isPasteVerb(tokens[0]) {
            let value = tokens[1]
            if let number = slotNumber(value) {
                return .pasteNumber(number)
            }
            return validNameTokens([value]).map(VoiceCommand.pasteNamed)
        }

        if tokens.starts(with: ["permanent", "copy"]) {
            return validNameTokens(Array(tokens.dropFirst(2))).map(VoiceCommand.permanentCopy)
        }

        if let first = tokens.first, isPasteVerb(first) {
            return validNameTokens(Array(tokens.dropFirst())).map(VoiceCommand.pasteNamed)
        }

        if tokens.starts(with: ["delete", "permanent", "copy"]) {
            return validNameTokens(Array(tokens.dropFirst(3))).map(VoiceCommand.deleteNamed)
        }

        return nil
    }

    static func normalizeName(_ name: String) -> String {
        normalizedTokens(name).joined(separator: " ")
    }

    static func hasExplicitPhraseBoundary(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else {
            return false
        }
        return last == "." || last == "!" || last == "?" || last == "…"
    }

    static func validNormalizedPermanentName(_ name: String) -> String? {
        validNameTokens(normalizedTokens(name))
    }

    static func validNormalizedTemporaryName(_ name: String) -> String? {
        validTemporaryNameTokens(normalizedTokens(name))
    }

    static func isPotentialCommand(_ transcript: String) -> Bool {
        let tokens = normalizedTokens(transcript)
        guard let first = tokens.first else { return true }

        // Volatile recognition can publish "cop…" or "copy" before the
        // numbered argument arrives. Keep that range as an ordering barrier
        // without retaining the transcript itself.
        let commandBeginnings = ["copy", "paste", "permanent", "delete", "clear"]
            + pasteVerbAliases
        return commandBeginnings.contains {
            $0.hasPrefix(first) || first.hasPrefix($0)
        }
    }

    static func canonicalNumberedCommandVerb(_ token: String) -> String? {
        if token == "copy" { return "copy" }
        if isPasteVerb(token) { return "paste" }
        return nil
    }

    static func isPotentialPermanentModifier(_ token: String) -> Bool {
        token == "permanent" || token == "permanently" || token.hasPrefix("perman")
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func slotNumber(_ token: String) -> Int? {
        if let spoken = spokenNumbers[token] {
            return spoken
        }
        guard let number = Int(token), numberedSlotRange.contains(number) else {
            return nil
        }
        return number
    }

    private static func isPasteVerb(_ token: String) -> Bool {
        token == "paste" || pasteVerbAliases.contains(token)
    }

    private static func validNameTokens(_ tokens: [String]) -> String? {
        guard (1...3).contains(tokens.count),
              Int(tokens[0]) == nil,
              slotNumber(tokens[0]) == nil else {
            return nil
        }
        return tokens.joined(separator: " ")
    }

    private static func validTemporaryNameTokens(_ tokens: [String]) -> String? {
        guard tokens.count == 1 else { return nil }
        return validNameTokens(tokens)
    }
}

enum VolatileCommandAcceptancePolicy {
    // Confidence remains a guard for commands without a closed-vocabulary
    // identity. Apple can omit it on volatile results, so numbered slots and
    // exact known-name pastes must not depend on it for responsiveness.
    static let minimumGuardedConfidence = 0.45

    static func accepts<Names: Sequence>(
        _ command: VoiceCommand,
        confidence: Double?,
        knownNamedCopies: Names
    ) -> Bool where Names.Element == String {
        switch command {
        case .copyNumber, .pasteNumber:
            // Closed-vocabulary numbered commands keep the fastest path.
            return true

        case .copyNamed:
            // The streaming scanner owns arbitrary one-word names and releases
            // them only after Apple's finalization watermark clears the name.
            return false

        case .permanentCopy, .deleteNamed:
            // A new arbitrary name has no known word boundary. The result gate
            // releases the last stable candidate when Apple finalizes its range.
            return false

        case .pasteNamed(let name):
            // Existing names form a closed vocabulary just like numbered
            // slots. Apple can omit confidence from otherwise complete
            // volatile results, so requiring it here forces a known paste to
            // wait several seconds for finalization. Exact membership plus the
            // prefix-collision guard is the safety boundary.
            let normalizedName = VoiceCommandParser.normalizeName(name)
            var nameExists = false
            var hasLongerPrefixMatch = false
            for knownName in knownNamedCopies {
                nameExists = nameExists || knownName == normalizedName
                hasLongerPrefixMatch = hasLongerPrefixMatch
                    || (knownName != normalizedName
                        && knownName.hasPrefix(normalizedName))
            }
            return nameExists && !hasLongerPrefixMatch

        case .clearTemporary:
            return meetsGuardedConfidence(confidence)
        }
    }

    private static func meetsGuardedConfidence(_ confidence: Double?) -> Bool {
        guard let confidence else { return false }
        return confidence >= minimumGuardedConfidence
    }
}
