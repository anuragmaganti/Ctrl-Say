import SwiftUI

extension View {
    func temporarySlotSwipeToDelete(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: action) {
                Label("Delete copy", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
            }
            .buttonStyle(.plain)
            .frame(
                minWidth: 56,
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
            .background(.red)
            .contentShape(.rect)
            .accessibilityLabel("Delete copy")
            .accessibilityHint("Deletes this temporary copy")
        }
    }

    func temporarySlotListRow(
        verticalInset: CGFloat = 0,
        showsBottomSeparator: Bool = false
    ) -> some View {
        listRowInsets(
            EdgeInsets(
                top: verticalInset,
                leading: 0,
                bottom: verticalInset,
                trailing: 0
            )
        )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .clipboardRowSeparator(isVisible: showsBottomSeparator)
    }

    func clipboardRowSeparator(isVisible: Bool) -> some View {
        overlay(alignment: .bottom) {
            if isVisible {
                Divider()
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
            }
        }
    }
}
