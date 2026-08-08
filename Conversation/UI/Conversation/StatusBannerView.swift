import SwiftUI

struct StatusBannerView: View {
    let state: TurnState

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    var body: some View {
        if let text = state.statusDescription {
            Text(text)
                .font(.footnote)
                .foregroundStyle(isError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .transition(.opacity)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBannerView(state: .listening)
        StatusBannerView(state: .identifying)
        StatusBannerView(state: .rejected("Didn't catch that — try again."))
        StatusBannerView(state: .error("Couldn't start listening."))
    }
}
