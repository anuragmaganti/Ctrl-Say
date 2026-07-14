import Foundation

enum PermanentCopyPersistenceState: Equatable, Sendable {
    case loading
    case ready
    case saving(pendingCount: Int)
    case loadFailed
    case saveFailed(pendingCount: Int)

    var isLoading: Bool {
        self == .loading
    }

    var isUnavailable: Bool {
        if case .loadFailed = self { return true }
        return false
    }

    var hasFailure: Bool {
        switch self {
        case .loadFailed, .saveFailed:
            true
        case .loading, .ready, .saving:
            false
        }
    }

    var userMessage: String? {
        switch self {
        case .loading:
            "Loading permanent copies…"
        case .loadFailed:
            "Permanent storage is unavailable. Temporary copies still work."
        case .saveFailed:
            "Recent permanent-copy changes haven’t been saved."
        case .ready, .saving:
            nil
        }
    }
}

enum PermanentCopyPersistenceError: LocalizedError {
    case storageUnavailable
    case unsavedChanges
    case flushTimedOut

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Permanent storage is unavailable. Temporary numbered copies still work."
        case .unsavedChanges:
            "Recent permanent-copy changes could not be saved."
        case .flushTimedOut:
            "Ctrl-Say could not finish saving permanent copies before the quit deadline."
        }
    }
}
