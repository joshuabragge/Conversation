import SwiftUI

/// Manual language-override chip — the plan's "auto-detect with manual
/// override" decision. `nil` selection means auto-detect.
struct LanguageChipView: View {
    let pair: LanguagePair
    @Binding var selection: Locale.Language?

    var body: some View {
        HStack(spacing: 8) {
            /*Text("Language:")
                .font(.caption)
                .foregroundStyle(.secondary)*/
            chip("Auto", isSelected: selection == nil) { selection = nil }
            chip(pair.first.displayName, isSelected: selection == pair.first) { selection = pair.first }
            chip(pair.second.displayName, isSelected: selection == pair.second) { selection = pair.second }
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color(.systemGray5), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
            
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LanguageChipView(
        pair: LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de")),
        selection: .constant(nil)
    )
}
