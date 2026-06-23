import SwiftUI

struct StartPairingView: View {
    let onStartPairing: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "link.circle")
                .font(.system(size: 64))
                .foregroundColor(.orange)

            Text("Hubungkan ke Clawmac")
                .font(.headline)

            Text("Klik tombol di bawah untuk menghubungkan aplikasi ini dengan Clawmac.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onStartPairing) {
                Text("Hubungkan Sekarang")
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
    }
}
