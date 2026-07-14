import Observation
import ServiceManagement

enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isSelected: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var state: LaunchAtLoginState = .disabled
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LaunchAtLoginServicing
    @ObservationIgnored private let openSystemSettingsAction: () -> Void

    var isEnabled: Bool {
        state.isSelected
    }

    init(
        service: any LaunchAtLoginServicing = SMAppService.mainApp,
        openSystemSettingsAction: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.service = service
        self.openSystemSettingsAction = openSystemSettingsAction
        refresh()
    }

    func refresh() {
        state = Self.state(for: service.status)
        if state != .unavailable {
            errorMessage = nil
        }
    }

    @discardableResult
    func setEnabled(_ shouldEnable: Bool) -> Bool {
        errorMessage = nil

        do {
            if shouldEnable {
                switch service.status {
                case .enabled:
                    break
                case .requiresApproval:
                    refresh()
                    return true
                case .notRegistered:
                    try service.register()
                case .notFound:
                    state = .unavailable
                    errorMessage = Self.updateFailureMessage
                    return false
                @unknown default:
                    state = .unavailable
                    errorMessage = Self.updateFailureMessage
                    return false
                }
            } else {
                switch service.status {
                case .enabled, .requiresApproval:
                    try service.unregister()
                case .notRegistered:
                    break
                case .notFound:
                    state = .unavailable
                    errorMessage = Self.updateFailureMessage
                    return false
                @unknown default:
                    state = .unavailable
                    errorMessage = Self.updateFailureMessage
                    return false
                }
            }

            refresh()
            return shouldEnable ? state.isSelected : state == .disabled
        } catch {
            refresh()
            errorMessage = Self.updateFailureMessage
            return false
        }
    }

    func openSystemSettings() {
        openSystemSettingsAction()
    }

    private static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    private static let updateFailureMessage =
        "Ctrl-Say couldn’t update Login Items. Open System Settings and try again."
}
