import SwiftUI
import Cocoa

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var pairingManager: PairingManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    if let url = Bundle.module.url(forResource: "OpenClawLogo", withExtension: "svg"),
                       let logo = NSImage(contentsOf: url) {
                        Image(nsImage: logo)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "message.fill")
                    }
                    Text("Clawmac")
                        .font(.headline)
                }

                Spacer()

                HStack(spacing: 8) {
                    if !viewModel.connectionStatus.isEmpty {
                        Text(viewModel.connectionStatus)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if pairingManager.isPairing {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if pairingManager.isPaired {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else if pairingManager.awaitingApproval {
                        Image(systemName: "hourglass")
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding()

            Divider()

            if pairingManager.awaitingApproval {
                ApprovalWaitingView(
                    pairingCode: pairingManager.pairingCode,
                    onCheckAgain: { pairingManager.checkIfApproved() }
                )
            } else if !pairingManager.isPaired {
                StartPairingView {
                    pairingManager.generatePairingCode()
                }
            } else {
                chatUI
            }
        }
        .frame(width: 380, height: 600)
    }

    var chatUI: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            elapsedTime: message.isProcessing ? viewModel.elapsedTime : 0
                        )
                    }
                }
                .padding()
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: { viewModel.toggleRecording() }) {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(viewModel.isRecording ? .red : .secondary)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color(.controlBackgroundColor))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color(.separatorColor), lineWidth: 0.5)
                        )
                }
                .buttonStyle(PlainButtonStyle())

                HStack {
                    TextField("Ketik pesan...", text: $viewModel.inputText)
                        .font(.system(size: 14))
                        .textFieldStyle(PlainTextFieldStyle())
                        .onSubmit { viewModel.sendMessage(clientId: pairingManager.clientId) }
                }
                .frame(height: 44)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Color(.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color(.separatorColor), lineWidth: 0.5)
                )

                Button(action: { viewModel.sendMessage(clientId: pairingManager.clientId) }) {
                    ZStack {
                        Circle()
                            .fill(viewModel.inputText.isEmpty ? Color(.controlBackgroundColor) : Color.blue)
                            .frame(width: 44, height: 44)

                        if viewModel.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(viewModel.inputText.isEmpty ? .secondary : .white)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.inputText.isEmpty || viewModel.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.windowBackgroundColor))
            .overlay(
                Rectangle()
                    .fill(Color(.separatorColor))
                    .frame(height: 0.5),
                alignment: .top
            )
        }
    }
}
