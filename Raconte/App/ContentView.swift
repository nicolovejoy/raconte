import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Raconte")
                .font(.largeTitle.weight(.semibold))
            Text("Milestone 1: capture — under construction")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
