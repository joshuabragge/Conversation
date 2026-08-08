import SwiftUI

struct HeadphoneIndicatorView: View {
    let isConnected: Bool

    var body: some View {
        if isConnected {
            Label("Headphones connected", systemImage: "headphones")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("No headphones — works, but that's the whole point of this app", systemImage: "headphones.slash")
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
