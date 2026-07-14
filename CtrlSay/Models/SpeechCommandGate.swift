import CoreMedia
import Foundation

struct SpeechResultRange: Hashable, Sendable {
    let start: CMTime
    let end: CMTime

    init(_ range: CMTimeRange) {
        start = range.start
        end = range.end
    }

    init(start: CMTime, end: CMTime) {
        self.start = start
        self.end = end
    }

    func overlaps(_ other: SpeechResultRange) -> Bool {
        CMTimeCompare(start, other.end) < 0
            && CMTimeCompare(other.start, end) < 0
    }

    func contains(_ other: SpeechResultRange) -> Bool {
        CMTimeCompare(start, other.start) <= 0
            && CMTimeCompare(end, other.end) >= 0
    }

    func union(_ other: SpeechResultRange) -> SpeechResultRange {
        SpeechResultRange(
            start: CMTimeCompare(start, other.start) <= 0 ? start : other.start,
            end: CMTimeCompare(end, other.end) >= 0 ? end : other.end
        )
    }

    func isFinalized(through finalizationTime: CMTime) -> Bool {
        finalizationTime.isNumeric && CMTimeCompare(finalizationTime, end) >= 0
    }
}

struct SpeechCommandMetadata: Equatable, Sendable {
    let resultReceivedAtNanoseconds: UInt64
    let audioEndUptimeNanoseconds: UInt64?
    let minimumConfidence: Double?
    let isFinal: Bool

    var recognitionLatencyMilliseconds: Double? {
        guard let audioEndUptimeNanoseconds,
              resultReceivedAtNanoseconds >= audioEndUptimeNanoseconds else {
            return nil
        }
        return Double(resultReceivedAtNanoseconds - audioEndUptimeNanoseconds) / 1_000_000
    }

    func finalized(releasedAtNanoseconds: UInt64? = nil) -> SpeechCommandMetadata {
        SpeechCommandMetadata(
            resultReceivedAtNanoseconds: releasedAtNanoseconds
                ?? resultReceivedAtNanoseconds,
            audioEndUptimeNanoseconds: audioEndUptimeNanoseconds,
            minimumConfidence: minimumConfidence,
            isFinal: true
        )
    }
}

enum SpeechCommandFreshnessPolicy {
    // A delayed side effect is more dangerous than an ignored ambiguous
    // command. This adds no wait; it only prevents an old recognition result
    // or a command stalled behind startup work from firing much later.
    static let maximumSideEffectAgeNanoseconds: UInt64 = 1_500_000_000

    static func isFresh(
        _ metadata: SpeechCommandMetadata,
        at uptimeNanoseconds: UInt64
    ) -> Bool {
        guard let audioEnd = metadata.audioEndUptimeNanoseconds,
              uptimeNanoseconds >= audioEnd else {
            return true
        }
        return uptimeNanoseconds - audioEnd
            <= maximumSideEffectAgeNanoseconds
    }
}

struct SpeechCommandObservation: Sendable {
    let range: SpeechResultRange
    let finalizationTime: CMTime
    let isFinal: Bool
    let command: VoiceCommand?
    let isPotentialCommand: Bool
    let acceptsVolatileResult: Bool
    let metadata: SpeechCommandMetadata
}

struct SpeechUtteranceID: Hashable, Sendable {
    let rawValue: UInt64
}

enum SpeechCommandMutation: Equatable, Sendable {
    case upsert(SpeechUtteranceID, VoiceCommand, SpeechCommandMetadata)
    case revoke(SpeechUtteranceID)
}

struct SpeechCommandGateUpdate: Sendable {
    let utteranceID: SpeechUtteranceID
    let isNewUtterance: Bool
    let mutations: [SpeechCommandMutation]
}

struct SpeechCommandGate {
    private struct State {
        let id: SpeechUtteranceID
        var range: SpeechResultRange
        var command: VoiceCommand?
        var commandRange: SpeechResultRange?
        var isPotentialCommand: Bool
        var metadata: SpeechCommandMetadata
        var acceptsVolatileResult: Bool
        var queuedCommand: VoiceCommand?
        var isCommitted = false
        var isFinalized = false
    }

    private var nextID: UInt64 = 1
    private var states: [State] = []

    var activeUtteranceIDs: Set<SpeechUtteranceID> {
        Set(states.map(\.id))
    }

    mutating func ingest(_ observation: SpeechCommandObservation) -> SpeechCommandGateUpdate {
        let existingIndex = stateIndex(overlapping: observation.range)
        let isNewUtterance = existingIndex == nil
        let stateIndex = existingIndex ?? appendState(for: observation)
        var mutations: [SpeechCommandMutation] = []
        var state = states[stateIndex]

        state.range = state.range.union(observation.range)
        let finalResultCoversState = observation.isFinal
            && observation.range.contains(state.range)
        state.isFinalized = state.isFinalized
            || finalResultCoversState
            || state.range.isFinalized(through: observation.finalizationTime)

        if !state.isCommitted {
            if let command = observation.command {
                state.command = command
                state.commandRange = observation.range
            } else if let commandRange = state.commandRange,
                      observation.range.contains(commandRange) {
                // A whole-range revision invalidates the prior parse. Final
                // word partitions only cover part of Apple's earlier volatile
                // phrase and must not erase the complete pending command.
                state.command = nil
                state.commandRange = nil
            }
            // Apple may replace any volatile text until the range finalizes.
            // Once a range has looked command-like, keep it as an audio-order
            // barrier even if an intermediate revision does not parse.
            state.isPotentialCommand = state.isPotentialCommand
                || observation.isPotentialCommand
                || observation.command != nil
            state.metadata = observation.metadata
            state.acceptsVolatileResult = observation.acceptsVolatileResult
            if state.isFinalized {
                state.metadata = observation.metadata.finalized()
            }
        }

        states[stateIndex] = state
        finalizeStates(
            through: observation.finalizationTime,
            releasedAtNanoseconds: observation.metadata.resultReceivedAtNanoseconds
        )
        reconcileQueue(mutations: &mutations)
        pruneFinishedStates()
        return SpeechCommandGateUpdate(
            utteranceID: state.id,
            isNewUtterance: isNewUtterance,
            mutations: mutations
        )
    }

    mutating func markCommitted(_ id: SpeechUtteranceID) {
        guard let index = states.firstIndex(where: { $0.id == id }) else { return }
        states[index].queuedCommand = nil
        states[index].isCommitted = true
        pruneFinishedStates()
    }

    mutating func reset() {
        states.removeAll(keepingCapacity: true)
    }

    private func stateIndex(overlapping range: SpeechResultRange) -> Int? {
        states.firstIndex { $0.range.overlaps(range) }
    }

    private mutating func appendState(for observation: SpeechCommandObservation) -> Int {
        let id = SpeechUtteranceID(rawValue: nextID)
        nextID &+= 1
        states.append(
            State(
                id: id,
                range: observation.range,
                command: nil,
                commandRange: nil,
                isPotentialCommand: observation.isPotentialCommand,
                metadata: observation.metadata,
                acceptsVolatileResult: observation.acceptsVolatileResult,
                queuedCommand: nil
            )
        )
        return states.index(before: states.endIndex)
    }

    private mutating func finalizeStates(
        through finalizationTime: CMTime,
        releasedAtNanoseconds: UInt64
    ) {
        guard finalizationTime.isNumeric else { return }

        for index in states.indices {
            guard !states[index].isFinalized,
                  states[index].range.isFinalized(through: finalizationTime) else {
                continue
            }
            states[index].isFinalized = true
            states[index].metadata = states[index].metadata.finalized(
                releasedAtNanoseconds: releasedAtNanoseconds
            )
        }
    }

    private mutating func reconcileQueue(
        mutations: inout [SpeechCommandMutation]
    ) {
        let orderedIndices = states.indices.sorted {
            CMTimeCompare(states[$0].range.start, states[$1].range.start) < 0
        }
        var isBlockedByEarlierCandidate = false

        for index in orderedIndices {
            guard !states[index].isCommitted else { continue }

            if isBlockedByEarlierCandidate {
                if states[index].queuedCommand != nil {
                    states[index].queuedCommand = nil
                    mutations.append(.revoke(states[index].id))
                }
                continue
            }

            let mayQueue = states[index].isFinalized
                || states[index].acceptsVolatileResult

            if let queuedCommand = states[index].queuedCommand {
                guard let command = states[index].command, mayQueue else {
                    states[index].queuedCommand = nil
                    mutations.append(.revoke(states[index].id))

                    // A revised but still parseable command remains an audio-
                    // order barrier until it becomes safe or is finalized.
                    if states[index].command != nil
                        || (!states[index].isFinalized && states[index].isPotentialCommand) {
                        isBlockedByEarlierCandidate = true
                    }
                    continue
                }

                if queuedCommand != command {
                    states[index].queuedCommand = command
                    mutations.append(
                        .upsert(
                            states[index].id,
                            command,
                            states[index].metadata
                        )
                    )
                }
                continue
            }

            guard let command = states[index].command else {
                if !states[index].isFinalized && states[index].isPotentialCommand {
                    isBlockedByEarlierCandidate = true
                }
                continue
            }
            guard mayQueue else {
                // Do not allow a later paste to pass an earlier copy that is
                // waiting for confidence/finalization.
                isBlockedByEarlierCandidate = true
                continue
            }

            states[index].queuedCommand = command
            mutations.append(
                .upsert(
                    states[index].id,
                    command,
                    states[index].metadata
                )
            )
        }
    }

    private mutating func pruneFinishedStates() {
        states.removeAll { state in
            guard state.isFinalized else { return false }
            return state.isCommitted
                || (state.queuedCommand == nil && state.command == nil)
        }
    }
}
