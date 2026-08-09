import SwiftUI

struct HeadphoneIndicatorView: View {
    let isConnected: Bool

    var body: some View {
        if isConnected {
            Label("", systemImage: "headphones")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("", systemImage: "headphones.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

#Preview {
    VStack {
        HeadphoneIndicatorView(isConnected: true)
        HeadphoneIndicatorView(isConnected: false)
    }
}
