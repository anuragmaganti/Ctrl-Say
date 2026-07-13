import Foundation
import Observation

@MainActor
@Observable
final class ClipboardStore {
    private(set) var numbered: [Int: ClipboardPayload] = [:]
    private(set) var named: [String: ClipboardPayload] = [:]

    var numberedSlots: [(number: Int, payload: ClipboardPayload)] {
        numbered.keys.sorted().compactMap { number in
            numbered[number].map { (number, $0) }
        }
    }

    var namedSlots: [(name: String, payload: ClipboardPayload)] {
        named.keys.sorted().compactMap { name in
            named[name].map { (name, $0) }
        }
    }

    func set(_ payload: ClipboardPayload, at number: Int) {
        numbered[number] = payload
    }

    func set(_ payload: ClipboardPayload, named name: String) {
        named[VoiceCommandParser.normalizeName(name)] = payload
    }

    func payload(at number: Int) -> ClipboardPayload? {
        numbered[number]
    }

    func payload(named name: String) -> ClipboardPayload? {
        named[VoiceCommandParser.normalizeName(name)]
    }

    func removeNamed(_ name: String) {
        named.removeValue(forKey: VoiceCommandParser.normalizeName(name))
    }

    func clearNumbered() {
        numbered.removeAll(keepingCapacity: true)
    }
}
