import SwiftUI
import Cocoa

struct ApprovalWaitingView: View {
    let pairingCode: String
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.orange)

            Text("Menunggu Persetujuan")
                .font(.headline)

            Text("Device ini belum di-approve. Silakan approve dengan menjalankan command berikut di terminal:")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Command untuk Terminal:")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                let commandText = "curl -X POST http://localhost:3456/api/macos/approve -d '{\"pairingCode\": \"\(pairingCode)\"}'"

                HStack {
                    Text(commandText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(10)

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commandText, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
            }
            .padding(.horizontal)

            VStack(spacing: 4) {
                Text("Pairing Code:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(pairingCode)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
            }

            Button(action: onCheckAgain) {
                Text("Cek Lagi")
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
    }
}
