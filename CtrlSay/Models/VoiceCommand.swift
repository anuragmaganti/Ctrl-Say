import Foundation

enum VoiceCommand: Equatable, Sendable {
    case copyNumber(Int)
    case pasteNumber(Int)
    case saveCurrentClipboard(Int)
    case permanentCopy(String)
    case pasteNamed(String)
    case deleteNamed(String)
    case clearNumbered

    var telemetryName: String {
        switch self {
        case .copyNumber: "copy-number"
        case .pasteNumber: "paste-number"
        case .saveCurrentClipboard: "save-current"
        case .permanentCopy: "copy-named"
        case .pasteNamed: "paste-named"
        case .deleteNamed: "delete-named"
        case .clearNumbered: "clear-numbered"
        }
    }
}

enum VoiceCommandParser {
    private static let spokenNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    static func parse(_ transcript: String) -> VoiceCommand? {
        let tokens = normalizedTokens(transcript)

        if tokens == ["clear", "copies"] || tokens == ["clear", "numbered", "copies"] {
            return .clearNumbered
        }

        if tokens.count == 2, tokens[0] == "copy" {
            return slotNumber(tokens[1]).map(VoiceCommand.copyNumber)
        }

        if tokens.count == 3, tokens[0] == "save", tokens[1] == "clipboard" {
            return slotNumber(tokens[2]).map(VoiceCommand.saveCurrentClipboard)
        }

        if tokens.count == 2, tokens[0] == "paste" {
            let value = tokens[1]
            if let number = slotNumber(value) {
                return .pasteNumber(number)
            }
            return validNameTokens([value]).map(VoiceCommand.pasteNamed)
        }

        if tokens.starts(with: ["permanent", "copy"]) {
            return validNameTokens(Array(tokens.dropFirst(2))).map(VoiceCommand.permanentCopy)
        }

        if tokens.starts(with: ["paste"]) {
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

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func slotNumber(_ token: String) -> Int? {
        if let spoken = spokenNumbers[token] {
            return spoken
        }
        guard let number = Int(token), (1...9).contains(number) else {
            return nil
        }
        return number
    }

    private static func validNameTokens(_ tokens: [String]) -> String? {
        guard (1...3).contains(tokens.count), slotNumber(tokens[0]) == nil else {
            return nil
        }
        return tokens.joined(separator: " ")
    }
}
