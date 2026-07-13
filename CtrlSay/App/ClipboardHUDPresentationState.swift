import Observation

@MainActor
@Observable
final class ClipboardHUDPresentationState {
    var selectedCollection: ClipboardHUDCollection = .numbered
}
