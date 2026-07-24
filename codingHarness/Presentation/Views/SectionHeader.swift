import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.top, 6)
    }
}
