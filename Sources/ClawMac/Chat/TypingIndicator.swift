import SwiftUI

struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.gray)
                    .frame(width: 6, height: 6)
                    .phaseAnimator([0, 1, 2]) { content, phase in
                        content
                            .scaleEffect(phase == index ? 1.3 : 1.0)
                    } animation: { phase in
                        .easeInOut(duration: 0.3)
                    }
            }
        }
    }
}
