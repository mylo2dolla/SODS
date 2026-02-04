import SwiftUI

struct ModalHeaderView: View {
    let title: String
    let onBack: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
            } else {
                Spacer().frame(width: 32)
            }

            Spacer()
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .keyboardShortcut(.cancelAction)
            .keyboardShortcut("w", modifiers: [.command])
        }
        .padding(.bottom, 8)
    }
}
