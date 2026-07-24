import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct StatusBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
