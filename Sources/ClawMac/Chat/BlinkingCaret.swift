import SwiftUI

struct BlinkingCaret: View {
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(Color.secondary)
            .frame(width: 2, height: 14)
            .opacity(on ? 1 : 0.2)
            .animation(.easeInOut(duration: 0.5), value: on)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    on.toggle()
                }
            }
    }
}
