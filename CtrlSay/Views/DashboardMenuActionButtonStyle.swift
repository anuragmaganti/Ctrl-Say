import AppKit
import SwiftUI

struct DashboardMenuActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DashboardMenuActionButtonBody(configuration: configuration)
    }
}

private struct DashboardMenuActionButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isHovered || configuration.isPressed
                            ? Color(nsColor: .selectedContentBackgroundColor)
                            : .clear
                    )
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
            }
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == DashboardMenuActionButtonStyle {
    static var dashboardMenuAction: Self { .init() }
}
