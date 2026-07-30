import SwiftUI

struct ContentView: View {
    @State private var model = CaptureScreenModel.live()

    var body: some View {
        CaptureView(model: model)
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 560)
            #endif
    }
}

#Preview {
    ContentView()
}
