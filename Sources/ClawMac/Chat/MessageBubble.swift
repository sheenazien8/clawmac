import SwiftUI

struct MessageBubble: View {
    let message: Message
    let elapsedTime: TimeInterval

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.isProcessing && message.content.isEmpty {
                    HStack(spacing: 8) {
                        TypingIndicator()
                        if !elapsedTimeText.isEmpty {
                            Text(elapsedTimeText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.windowBackgroundColor))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                } else {
                    contentBubble
                }

                if message.isProcessing, let progress = message.progressText, !progress.isEmpty {
                    HStack(spacing: 6) {
                        Text(progress)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if !elapsedTimeText.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(elapsedTimeText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            if message.role == .assistant {
                Spacer()
            }
        }
    }

    private var elapsedTimeText: String {
        guard elapsedTime > 0 else { return "" }
        if elapsedTime < 60 { return String(format: "%.1fs", elapsedTime) }
        let m = Int(elapsedTime) / 60
        let s = Int(elapsedTime) % 60
        return String(format: "%dm %02ds", m, s)
    }

    @ViewBuilder
    private var contentBubble: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Text(message.content)
                .font(.system(size: 14))
                .foregroundColor(message.role == .user ? .white : .primary)
                .textSelection(.enabled)
            if message.isProcessing {
                BlinkingCaret()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(message.role == .user ? Color.blue : Color(.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(message.role == .user ? Color.clear : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}
