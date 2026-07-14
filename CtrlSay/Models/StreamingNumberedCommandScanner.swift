import CoreMedia
import Foundation

struct StreamingNumberedCommandToken: Equatable, Sendable {
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

struct StreamingNumberedCommandSegment: Sendable {
    let range: SpeechResultRange
    let tokens: [StreamingNumberedCommandToken]
    let finalizationTime: CMTime
    let isFinal: Bool
    let hasTrailingPhraseBoundary: Bool

    init(
        range: SpeechResultRange,
        tokens: [StreamingNumberedCommandToken],
        finalizationTime: CMTime = .invalid,
        isFinal: Bool = false,
        hasTrailingPhraseBoundary: Bool = false
    ) {
        self.range = range
        self.tokens = tokens
        self.finalizationTime = finalizationTime
        self.isFinal = isFinal
        self.hasTrailingPhraseBoundary = hasTrailingPhraseBoundary
    }
}

struct StreamingNumberedCommandID: Hashable, Sendable {
    let rawValue: UInt64
}

struct StreamingNumberedCommandCandidate: Equatable, Sendable {
    let id: StreamingNumberedCommandID
    let command: VoiceCommand
    let range: SpeechResultRange
    let minimumConfidence: Double?
    let isReadyForDispatch: Bool
    let isStableForCommit: Bool
}

enum StreamingNumberedCommandMutation: Equatable, Sendable {
    case upsert(StreamingNumberedCommandCandidate)
    case revoke(StreamingNumberedCommandID)
}

struct StreamingNumberedCommandScannerUpdate: Equatable, Sendable {
    let mutations: [StreamingNumberedCommandMutation]
}

/// Extracts numbered, temporary named, and one-word permanent-copy commands
/// from a revisable speech timeline. Temporary names may contain up to five
/// words and expand under the same audio identity as Apple revises the result.
///
/// A candidate stays mutable until `markCommitted(_:)` is called. A committed
/// candidate becomes a tombstone, so Apple's final-result echo or a later text
/// revision cannot execute the same audio twice.
struct StreamingNumberedCommandScanner {
    private struct SegmentID: Hashable {
        let rawValue: UInt64
    }

    private struct SegmentState {
        let id: SegmentID
        var range: SpeechResultRange
        var tokens: [StreamingNumberedCommandToken]
        var isFinalized: Bool
        var hasTrailingPhraseBoundary: Bool
    }

    private struct TokenAnchor: Hashable {
        let segmentID: SegmentID
        let tokenIndex: Int
        let componentIndex: Int
    }

    private struct ResolvedToken {
        let text: String
        let anchor: TokenAnchor
        let segmentID: SegmentID
        let range: SpeechResultRange
        let segmentRange: SpeechResultRange
        let confidence: Double?
        let isFinalized: Bool
        let hasExplicitPhraseBoundary: Bool
    }

    private struct CandidateSnapshot {
        let anchors: [TokenAnchor]
        let sourceSegmentIDs: Set<SegmentID>
        let command: VoiceCommand
        let range: SpeechResultRange
        let minimumConfidence: Double?
        let isReadyForDispatch: Bool
        let isStableForCommit: Bool
        let order: Int
    }

    private struct CandidateState {
        let id: StreamingNumberedCommandID
        var anchors: [TokenAnchor]
        var sourceSegmentIDs: Set<SegmentID>
        var command: VoiceCommand
        var range: SpeechResultRange
        var minimumConfidence: Double?
        var isReadyForDispatch: Bool
        var isStableForCommit: Bool
        var order: Int
        var isPresent: Bool
        var isQueued: Bool
        var isCommitted: Bool
    }

    let maximumCrossSegmentGap: TimeInterval

    private var nextSegmentID: UInt64 = 1
    private var nextCandidateID: UInt64 = 1
    private var segments: [SegmentState] = []
    private var candidates: [CandidateState] = []
    private var finalizedThrough: CMTime = .invalid
    private var resultStreamFinalizedThrough: CMTime = .invalid
    private var latestObservedEnd: CMTime = .invalid

    init(maximumCrossSegmentGap: TimeInterval = 0.8) {
        precondition(
            maximumCrossSegmentGap.isFinite && maximumCrossSegmentGap >= 0,
            "The cross-segment gap must be a finite, nonnegative duration."
        )
        self.maximumCrossSegmentGap = maximumCrossSegmentGap
    }

    mutating func ingest(
        _ segment: StreamingNumberedCommandSegment,
        knownNamedCopies: Set<String> = []
    ) -> StreamingNumberedCommandScannerUpdate {
        let rangeWasAlreadyFinalized = isNumeric(resultStreamFinalizedThrough)
            && CMTimeCompare(segment.range.end, resultStreamFinalizedThrough) <= 0

        updateLatestObservedEnd(segment.range.end)

        // Results entirely behind the previous watermark are duplicate final
        // echoes. The first result that advances the watermark is still
        // processed before that watermark takes effect.
        guard !rangeWasAlreadyFinalized else {
            advanceResultStreamFinalizationWatermark(to: segment.finalizationTime)
            advanceFinalizationWatermark(to: segment.finalizationTime)
            pruneFinishedState()
            return StreamingNumberedCommandScannerUpdate(mutations: [])
        }

        let segmentIndex = indexForRevision(of: segment.range)
            ?? appendSegment(for: segment)
        segments[segmentIndex].range = segments[segmentIndex].range.union(segment.range)
        segments[segmentIndex].tokens = segment.tokens
        segments[segmentIndex].isFinalized = segments[segmentIndex].isFinalized
            || segment.isFinal
        segments[segmentIndex].hasTrailingPhraseBoundary =
            segment.hasTrailingPhraseBoundary

        advanceResultStreamFinalizationWatermark(to: segment.finalizationTime)
        advanceFinalizationWatermark(to: segment.finalizationTime)
        let mutations = reconcile(
            with: extractedCandidates(knownNamedCopies: knownNamedCopies)
        )
        pruneFinishedState()
        return StreamingNumberedCommandScannerUpdate(mutations: mutations)
    }

    mutating func markCommitted(_ id: StreamingNumberedCommandID) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else {
            return
        }
        candidates[index].isQueued = false
        candidates[index].isCommitted = true
        pruneFinishedState()
    }

    mutating func advanceFinalization(
        to watermark: CMTime,
        knownNamedCopies: Set<String> = []
    ) -> StreamingNumberedCommandScannerUpdate {
        advanceFinalizationWatermark(to: watermark)
        let mutations = reconcile(
            with: extractedCandidates(knownNamedCopies: knownNamedCopies)
        )
        pruneFinishedState()
        return StreamingNumberedCommandScannerUpdate(mutations: mutations)
    }

    mutating func reset() {
        segments.removeAll(keepingCapacity: true)
        candidates.removeAll(keepingCapacity: true)
        finalizedThrough = .invalid
        resultStreamFinalizedThrough = .invalid
        latestObservedEnd = .invalid
    }

    private mutating func appendSegment(
        for observation: StreamingNumberedCommandSegment
    ) -> Int {
        let id = SegmentID(rawValue: nextSegmentID)
        nextSegmentID &+= 1
        segments.append(
            SegmentState(
                id: id,
                range: observation.range,
                tokens: observation.tokens,
                isFinalized: observation.isFinal,
                hasTrailingPhraseBoundary: observation.hasTrailingPhraseBoundary
            )
        )
        return segments.index(before: segments.endIndex)
    }

    private func indexForRevision(of range: SpeechResultRange) -> Int? {
        if let sameStart = segments.firstIndex(where: {
            CMTimeCompare($0.range.start, range.start) == 0
        }) {
            return sameStart
        }

        return segments.firstIndex { state in
            !state.isFinalized && state.range.overlaps(range)
        }
    }

    private mutating func advanceFinalizationWatermark(to watermark: CMTime) {
        guard isNumeric(watermark) else { return }
        if !isNumeric(finalizedThrough)
            || CMTimeCompare(watermark, finalizedThrough) > 0 {
            finalizedThrough = watermark
        }

        for index in segments.indices where
            CMTimeCompare(segments[index].range.end, finalizedThrough) <= 0
        {
            segments[index].isFinalized = true
        }
    }

    private mutating func advanceResultStreamFinalizationWatermark(
        to watermark: CMTime
    ) {
        guard isNumeric(watermark) else { return }
        if !isNumeric(resultStreamFinalizedThrough)
            || CMTimeCompare(watermark, resultStreamFinalizedThrough) > 0 {
            resultStreamFinalizedThrough = watermark
        }
    }

    private mutating func updateLatestObservedEnd(_ end: CMTime) {
        guard isNumeric(end) else { return }
        if !isNumeric(latestObservedEnd)
            || CMTimeCompare(end, latestObservedEnd) > 0 {
            latestObservedEnd = end
        }
    }

    private func extractedCandidates(
        knownNamedCopies: Set<String>
    ) -> [CandidateSnapshot] {
        let orderedSegments = segments.sorted { lhs, rhs in
            let comparison = CMTimeCompare(lhs.range.start, rhs.range.start)
            if comparison != 0 { return comparison < 0 }
            return lhs.id.rawValue < rhs.id.rawValue
        }

        var resolvedTokens: [ResolvedToken] = []
        for segment in orderedSegments {
            let lastSemanticTokenIndex = segment.tokens.lastIndex {
                !normalizedComponents($0.text).isEmpty
            }
            for (tokenIndex, token) in segment.tokens.enumerated() {
                let components = normalizedComponents(token.text)
                for (componentIndex, component) in components.enumerated() {
                    let isLastComponent = componentIndex == components.count - 1
                    let tokenClosesPhrase = isLastComponent
                        && VoiceCommandParser.hasExplicitPhraseBoundary(token.text)
                    let segmentClosesPhrase = isLastComponent
                        && tokenIndex == lastSemanticTokenIndex
                        && segment.hasTrailingPhraseBoundary
                    resolvedTokens.append(
                        ResolvedToken(
                            text: component,
                            anchor: TokenAnchor(
                                segmentID: segment.id,
                                tokenIndex: tokenIndex,
                                componentIndex: componentIndex
                            ),
                            segmentID: segment.id,
                            range: token.range ?? segment.range,
                            segmentRange: segment.range,
                            confidence: token.confidence,
                            isFinalized: segment.isFinalized,
                            hasExplicitPhraseBoundary: tokenClosesPhrase
                                || segmentClosesPhrase
                        )
                    )
                }
            }
        }

        guard resolvedTokens.count >= 2 else { return [] }
        var snapshots: [CandidateSnapshot] = []
        let storedNamedCopies = Set(
            knownNamedCopies.map(VoiceCommandParser.normalizeName)
        )
        var availableNamedCopies = storedNamedCopies

        for index in 0..<(resolvedTokens.count - 1) {
            if let permanentCopy = permanentCopyCandidate(
                startingAt: index,
                in: resolvedTokens,
                order: snapshots.count
            ) {
                snapshots.append(permanentCopy)
                continue
            }

            let verb = resolvedTokens[index]
            if verb.text == "copy", index > 0 {
                let precedingToken = resolvedTokens[index - 1]
                if VoiceCommandParser.isPotentialPermanentModifier(
                    precedingToken.text
                ), canBridge(precedingToken, to: verb) {
                    // Never reinterpret `permanent copy N` as temporary
                    // `copy N`. Numeric permanent names are invalid and the
                    // safe result is no command, not a different command.
                    continue
                }
            }
            guard let candidate = temporaryCommandCandidate(
                startingAt: index,
                in: resolvedTokens,
                knownNamedCopies: availableNamedCopies,
                order: snapshots.count
            ) else {
                continue
            }
            switch candidate.command {
            case .copyNamed(let name):
                availableNamedCopies.insert(
                    VoiceCommandParser.normalizeName(name)
                )
            default:
                break
            }
            snapshots.append(candidate)
        }
        return snapshots
    }

    private func temporaryCommandCandidate(
        startingAt index: Int,
        in tokens: [ResolvedToken],
        knownNamedCopies: Set<String>,
        order: Int
    ) -> CandidateSnapshot? {
        guard index + 1 < tokens.count else { return nil }
        let verb = tokens[index]
        guard let canonicalVerb = VoiceCommandParser.canonicalNumberedCommandVerb(
            verb.text
        ) else {
            return nil
        }
        let firstArgument = tokens[index + 1]
        guard canBridge(verb, to: firstArgument) else { return nil }

        let arguments: [ResolvedToken]
        if let numberedCommand = VoiceCommandParser.parse(
            "\(canonicalVerb) \(firstArgument.text)"
        ), case .copyNumber = numberedCommand {
            arguments = [firstArgument]
        } else if let numberedCommand = VoiceCommandParser.parse(
            "\(canonicalVerb) \(firstArgument.text)"
        ), case .pasteNumber = numberedCommand {
            arguments = [firstArgument]
        } else if canonicalVerb == "copy" {
            arguments = temporaryNameArguments(
                startingAt: index + 1,
                in: tokens
            )
        } else {
            arguments = longestKnownNameArguments(
                startingAt: index + 1,
                in: tokens,
                knownNamedCopies: knownNamedCopies
            )
        }
        guard let finalArgument = arguments.last else { return nil }

        let spokenName = arguments.map(\.text).joined(separator: " ")
        guard let command = VoiceCommandParser.parse(
            "\(canonicalVerb) \(spokenName)"
        ) else {
            return nil
        }
        if case .pasteNamed(let name) = command,
           !knownNamedCopies.contains(VoiceCommandParser.normalizeName(name)) {
            return nil
        }

        let commandTokens = [verb] + arguments
        let confidences = commandTokens.map(\.confidence)
        let minimumConfidence = confidences.allSatisfy { $0 != nil }
            ? confidences.compactMap { $0 }.min()
            : nil
        let range = commandTokens.dropFirst().reduce(verb.range) {
            $0.union($1.range)
        }

        return CandidateSnapshot(
            anchors: commandTokens.map(\.anchor),
            sourceSegmentIDs: Set(commandTokens.map(\.segmentID)),
            command: command,
            range: range,
            minimumConfidence: minimumConfidence,
            isReadyForDispatch: isReadyForDispatch(
                command,
                argument: finalArgument,
                minimumConfidence: minimumConfidence,
                knownNamedCopies: knownNamedCopies
            ),
            isStableForCommit: isStableForCommit(
                command,
                argument: finalArgument
            ),
            order: order
        )
    }

    private func temporaryNameArguments(
        startingAt start: Int,
        in tokens: [ResolvedToken]
    ) -> [ResolvedToken] {
        var arguments: [ResolvedToken] = []
        var previous: ResolvedToken?

        for index in start..<tokens.count {
            let token = tokens[index]
            if let previous, !canBridge(previous, to: token) { break }
            if !arguments.isEmpty, isExplicitCommandBoundary(token.text) { break }
            if beginsCommandTransition(at: index, in: tokens) { break }
            guard arguments.count < VoiceCommandParser.temporaryNameWordRange.upperBound else {
                break
            }
            arguments.append(token)
            previous = token
            if token.hasExplicitPhraseBoundary { break }
        }
        return arguments
    }

    private func longestKnownNameArguments(
        startingAt start: Int,
        in tokens: [ResolvedToken],
        knownNamedCopies: Set<String>
    ) -> [ResolvedToken] {
        var arguments: [ResolvedToken] = []
        var longestMatch: [ResolvedToken] = []
        var previous: ResolvedToken?

        for index in start..<tokens.count {
            let token = tokens[index]
            if let previous, !canBridge(previous, to: token) { break }
            if !arguments.isEmpty, isExplicitCommandBoundary(token.text) { break }
            guard arguments.count < VoiceCommandParser.temporaryNameWordRange.upperBound else {
                break
            }
            arguments.append(token)
            previous = token
            let name = VoiceCommandParser.normalizeName(
                arguments.map(\.text).joined(separator: " ")
            )
            if knownNamedCopies.contains(name) {
                longestMatch = arguments
            }
            if token.hasExplicitPhraseBoundary { break }
        }
        return longestMatch
    }

    private func beginsCommandTransition(
        at index: Int,
        in tokens: [ResolvedToken]
    ) -> Bool {
        guard tokens[index].text == "and" || tokens[index].text == "then" else {
            return false
        }
        let nextIndex = index + 1
        guard nextIndex < tokens.count else { return false }
        if isExplicitCommandBoundary(tokens[nextIndex].text) {
            return true
        }
        let followingIndex = nextIndex + 1
        return tokens[nextIndex].text == "then"
            && followingIndex < tokens.count
            && isExplicitCommandBoundary(tokens[followingIndex].text)
    }

    private func permanentCopyCandidate(
        startingAt index: Int,
        in tokens: [ResolvedToken],
        order: Int
    ) -> CandidateSnapshot? {
        guard index + 2 < tokens.count else { return nil }
        let modifier = tokens[index]
        let verb = tokens[index + 1]
        let argument = tokens[index + 2]

        guard VoiceCommandParser.isPotentialPermanentModifier(modifier.text),
              VoiceCommandParser.canonicalNumberedCommandVerb(
                  verb.text
              ) == "copy",
              canBridge(modifier, to: verb),
              canBridge(verb, to: argument),
              let name = VoiceCommandParser.validNormalizedPermanentName(
                  argument.text
              ) else {
            return nil
        }

        var hasFollowingCommandBoundary = false
        // If Apple has already supplied another ordinary word in the same
        // result, the permanent name may be multiword. Leave that case on the
        // whole-phrase gate instead of prematurely capturing only its prefix.
        if index + 3 < tokens.count {
            let following = tokens[index + 3]
            if !canBridge(argument, to: following) {
                hasFollowingCommandBoundary = true
            } else if isExplicitCommandBoundary(following.text)
                        || beginsCommandTransition(at: index + 3, in: tokens) {
                hasFollowingCommandBoundary = true
            } else {
                return nil
            }
        }

        let command = VoiceCommand.permanentCopy(name)
        let range = modifier.range.union(verb.range).union(argument.range)
        let confidences = [
            modifier.confidence,
            verb.confidence,
            argument.confidence,
        ]
        let minimumConfidence = confidences.allSatisfy { $0 != nil }
            ? confidences.compactMap { $0 }.min()
            : nil

        return CandidateSnapshot(
            anchors: [modifier.anchor, verb.anchor, argument.anchor],
            sourceSegmentIDs: [
                modifier.segmentID,
                verb.segmentID,
                argument.segmentID,
            ],
            command: command,
            range: range,
            minimumConfidence: minimumConfidence,
            isReadyForDispatch: isReadyForDispatch(
                command,
                argument: argument,
                hasFollowingCommandBoundary: hasFollowingCommandBoundary
            ),
            isStableForCommit: isStableForCommit(
                command,
                argument: argument
            ),
            order: order
        )
    }

    private func isExplicitCommandBoundary(_ token: String) -> Bool {
        VoiceCommandParser.canonicalNumberedCommandVerb(token) != nil
            || VoiceCommandParser.isPotentialPermanentModifier(token)
            || ["clear", "delete", "make", "rename", "save"].contains(token)
    }

    private func isReadyForDispatch(
        _ command: VoiceCommand,
        argument: ResolvedToken,
        hasFollowingCommandBoundary: Bool = false,
        minimumConfidence: Double? = nil,
        knownNamedCopies: Set<String> = []
    ) -> Bool {
        let isFinalized = argument.isFinalized
            || argument.segmentRange.isFinalized(through: finalizedThrough)

        switch command {
        case .copyNamed:
            // Temporary named copies are latency-first, just like numbered
            // copies. Trust Apple's complete volatile two-token command; its
            // audio identity still deduplicates later punctuation and final
            // echoes. Do not wait for result finalization.
            return true

        case .permanentCopy:
            // Keep replacing unfinished volatile prefixes, but trust Apple's
            // explicit phrase boundary as soon as it appears. The boundary is
            // dispatch metadata only; punctuation never becomes part of the
            // normalized slot name. Finalization remains the fallback for
            // results that contain no explicit boundary.
            return argument.hasExplicitPhraseBoundary
                || hasFollowingCommandBoundary
                || isFinalized

        case .pasteNamed:
            // Pasting can use the volatile fast path because its name must
            // already exist. Exact known-name membership is the closed-
            // vocabulary guard; prefix collisions remain pending until Apple
            // finalizes the result.
            return isFinalized
                || VolatileCommandAcceptancePolicy.accepts(
                    command,
                    confidence: minimumConfidence,
                    knownNamedCopies: knownNamedCopies
                )

        case .copyNumber, .pasteNumber:
            // Preserve the latency-first closed-vocabulary path.
            return true

        default:
            return false
        }
    }

    private func isStableForCommit(
        _ command: VoiceCommand,
        argument: ResolvedToken
    ) -> Bool {
        guard case .copyNamed = command else { return true }
        return argument.hasExplicitPhraseBoundary
            || argument.isFinalized
            || argument.segmentRange.isFinalized(through: finalizedThrough)
    }

    private func canBridge(_ verb: ResolvedToken, to argument: ResolvedToken) -> Bool {
        guard verb.segmentID != argument.segmentID else { return true }
        guard isNumeric(verb.range.end), isNumeric(argument.range.start) else {
            return false
        }

        let gap = CMTimeGetSeconds(
            CMTimeSubtract(argument.range.start, verb.range.end)
        )
        guard gap.isFinite else { return false }
        return max(0, gap) <= maximumCrossSegmentGap
    }

    private mutating func reconcile(
        with snapshots: [CandidateSnapshot]
    ) -> [StreamingNumberedCommandMutation] {
        var assignedStateIndices = Set<Int>()
        var assignments: [(snapshot: CandidateSnapshot, stateIndex: Int)] = []

        for snapshot in snapshots {
            let stateIndex = exactStateIndex(
                for: snapshot,
                excluding: assignedStateIndices
            ) ?? fallbackStateIndex(
                for: snapshot,
                excluding: assignedStateIndices
            ) ?? appendCandidate(for: snapshot)
            assignedStateIndices.insert(stateIndex)
            assignments.append((snapshot, stateIndex))
        }

        var stagedMutations: [(
            order: Int,
            mutation: StreamingNumberedCommandMutation
        )] = []

        for index in candidates.indices where !assignedStateIndices.contains(index) {
            guard candidates[index].isPresent else { continue }
            candidates[index].isPresent = false
            if candidates[index].isQueued && !candidates[index].isCommitted {
                candidates[index].isQueued = false
                stagedMutations.append(
                    (candidates[index].order, .revoke(candidates[index].id))
                )
            }
        }

        for assignment in assignments {
            let snapshot = assignment.snapshot
            let index = assignment.stateIndex
            let priorCommand = candidates[index].command
            let wasReadyForDispatch = candidates[index].isReadyForDispatch
            let wasStableForCommit = candidates[index].isStableForCommit
            let wasPresent = candidates[index].isPresent

            candidates[index].anchors = snapshot.anchors
            candidates[index].sourceSegmentIDs = snapshot.sourceSegmentIDs
            candidates[index].command = snapshot.command
            // The newest revision is the best audio localization. Keeping the
            // union would leave a volatile whole-phrase range attached to a
            // final word partition and could hide a real repeated command.
            candidates[index].range = snapshot.range
            candidates[index].minimumConfidence = snapshot.minimumConfidence
            candidates[index].isReadyForDispatch = snapshot.isReadyForDispatch
            candidates[index].isStableForCommit = snapshot.isStableForCommit
            candidates[index].order = snapshot.order
            candidates[index].isPresent = true

            guard !candidates[index].isCommitted else { continue }
            guard !candidates[index].isQueued
                    || !wasPresent
                    || priorCommand != snapshot.command
                    || wasReadyForDispatch != snapshot.isReadyForDispatch
                    || wasStableForCommit != snapshot.isStableForCommit else {
                continue
            }

            candidates[index].isQueued = true
            let candidate = StreamingNumberedCommandCandidate(
                id: candidates[index].id,
                command: snapshot.command,
                range: candidates[index].range,
                minimumConfidence: snapshot.minimumConfidence,
                isReadyForDispatch: snapshot.isReadyForDispatch,
                isStableForCommit: snapshot.isStableForCommit
            )
            stagedMutations.append((snapshot.order, .upsert(candidate)))
        }

        return stagedMutations
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.order != rhs.element.order {
                    return lhs.element.order < rhs.element.order
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element.mutation)
    }

    private func exactStateIndex(
        for snapshot: CandidateSnapshot,
        excluding assignedIndices: Set<Int>
    ) -> Int? {
        candidates.indices.first {
            !assignedIndices.contains($0)
                && candidates[$0].anchors == snapshot.anchors
                && rangesCorrespond(candidates[$0].range, snapshot.range)
        }
    }

    private func fallbackStateIndex(
        for snapshot: CandidateSnapshot,
        excluding assignedIndices: Set<Int>
    ) -> Int? {
        let eligible = candidates.indices.filter { index in
            !assignedIndices.contains(index)
                && !candidates[index].sourceSegmentIDs
                    .isDisjoint(with: snapshot.sourceSegmentIDs)
        }

        return eligible.first {
            candidates[$0].command == snapshot.command
                && rangesCorrespond(candidates[$0].range, snapshot.range)
        } ?? eligible.first {
            // AttributedString runs can change from one aggregate run to one
            // run per word. Within the same source segment, command order is
            // the stable fallback when both anchors and placeholder timing
            // change at once.
            candidates[$0].command == snapshot.command
                && candidates[$0].order == snapshot.order
        } ?? eligible.first {
            rangesCorrespond(candidates[$0].range, snapshot.range)
        } ?? candidates.indices.first {
            // Apple can replace one broad volatile segment with several final
            // partitions. The command partition then has a new SegmentID, but
            // its audio is still inside the already-executed broad candidate.
            !assignedIndices.contains($0)
                && (candidates[$0].isCommitted || candidates[$0].isQueued)
                && candidates[$0].command == snapshot.command
                // Across distinct Apple result segments, require real audio
                // overlap. Endpoint-inclusive zero-range containment is safe
                // for revisions of one source segment, but could otherwise
                // absorb a genuine adjacent repeat that begins at that point.
                && strictlyOverlaps(candidates[$0].range, snapshot.range)
        }
    }

    private mutating func appendCandidate(
        for snapshot: CandidateSnapshot
    ) -> Int {
        let id = StreamingNumberedCommandID(rawValue: nextCandidateID)
        nextCandidateID &+= 1
        candidates.append(
            CandidateState(
                id: id,
                anchors: snapshot.anchors,
                sourceSegmentIDs: snapshot.sourceSegmentIDs,
                command: snapshot.command,
                range: snapshot.range,
                minimumConfidence: snapshot.minimumConfidence,
                isReadyForDispatch: snapshot.isReadyForDispatch,
                isStableForCommit: snapshot.isStableForCommit,
                order: snapshot.order,
                isPresent: false,
                isQueued: false,
                isCommitted: false
            )
        )
        return candidates.index(before: candidates.endIndex)
    }

    private mutating func pruneFinishedState() {
        let queuedSourceIDs = Set(
            candidates
                .filter { $0.isQueued && !$0.isCommitted }
                .flatMap(\.sourceSegmentIDs)
        )
        let latestEnd = latestObservedEnd
        let maximumGap = maximumCrossSegmentGap

        segments.removeAll { segment in
            guard segment.isFinalized,
                  !queuedSourceIDs.contains(segment.id),
                  latestEnd.isNumeric,
                  segment.range.end.isNumeric else {
                return false
            }
            let age = CMTimeGetSeconds(
                CMTimeSubtract(latestEnd, segment.range.end)
            )
            return age.isFinite && age > maximumGap
        }

        let retainedSegmentIDs = Set(segments.map(\.id))
        candidates.removeAll { candidate in
            let hasRetainedSource = !candidate.sourceSegmentIDs
                .isDisjoint(with: retainedSegmentIDs)
            if candidate.isCommitted {
                return !hasRetainedSource
            }
            return !candidate.isQueued && !candidate.isPresent && !hasRetainedSource
        }
    }

    private func normalizedComponents(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func rangesCorrespond(
        _ lhs: SpeechResultRange,
        _ rhs: SpeechResultRange
    ) -> Bool {
        if lhs == rhs || lhs.overlaps(rhs) {
            return true
        }

        // Apple can initially publish both command tokens at a single audio
        // instant, then replace that volatile point with the full word span.
        // Strict half-open overlap considers a zero-duration range disjoint,
        // which would turn the final echo into a second command identity.
        return zeroDurationRange(lhs, isContainedIn: rhs)
            || zeroDurationRange(rhs, isContainedIn: lhs)
    }

    private func strictlyOverlaps(
        _ lhs: SpeechResultRange,
        _ rhs: SpeechResultRange
    ) -> Bool {
        lhs.overlaps(rhs)
    }

    private func zeroDurationRange(
        _ pointRange: SpeechResultRange,
        isContainedIn other: SpeechResultRange
    ) -> Bool {
        guard CMTimeCompare(pointRange.start, pointRange.end) == 0 else {
            return false
        }
        return CMTimeCompare(pointRange.start, other.start) >= 0
            && CMTimeCompare(pointRange.start, other.end) <= 0
    }

    private func isNumeric(_ time: CMTime) -> Bool {
        time.isNumeric
    }
}
