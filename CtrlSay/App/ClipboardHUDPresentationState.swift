import Observation

@MainActor
@Observable
final class ClipboardHUDPresentationState {
    var selectedCollection: ClipboardCollection = .numbered
}
