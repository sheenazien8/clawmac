import SwiftUI

// MARK: - Enhanced Chat View
struct EnhancedChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var pairingManager: PairingManager
    
    var body: some View {
        ZStack {
            // Background
            OpenClawTheme.background
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Enhanced Header
                EnhancedHeader(
                    isPaired: pairingManager.isPaired,
                    isPairing: pairingManager.isPairing,
                    awaitingApproval: pairingManager.awaitingApproval,
                    connectionStatus: viewModel.connectionStatus
                )
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Content
                Group {
                    if pairingManager.awaitingApproval {
                        EnhancedApprovalView(
                            pairingCode: pairingManager.pairingCode,
                            onCheckAgain: { pairingManager.checkIfApproved() }
                        )
                    } else if !pairingManager.isPaired {
                        EnhancedStartPairingView {
                            pairingManager.generatePairingCode()
                        }
                    } else {
                        enhancedChatUI
                    }
                }
            }
        }
        .frame(width: 400, height: 650)
    }
    
    var enhancedChatUI: some View {
        VStack(spacing: 0) {
            // Messages ScrollView
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        EnhancedMessageBubble(message: message)
                    }
                }
                .padding()
            }
            .background(OpenClawTheme.background)
            
            // Enhanced Input Bar
            EnhancedInputBar(
                text: $viewModel.inputText,
                isRecording: viewModel.isRecording,
                isLoading: viewModel.isLoading,
                onSend: { viewModel.sendMessage(clientId: pairingManager.clientId) },
                onToggleRecording: { viewModel.toggleRecording() }
            )
        }
    }
}

// MARK: - Enhanced Header
struct EnhancedHeader: View {
    let isPaired: Bool
    let isPairing: Bool
    let awaitingApproval: Bool
    let connectionStatus: String
    
    var body: some View {
        HStack(spacing: 12) {
            // Logo
            ZStack {
                Circle()
                    .fill(OpenClawTheme.primaryGradient)
                    .frame(width: 36, height: 36)
                
                Image(systemName: "message.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .glow()
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Clawmac")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(OpenClawTheme.textSecondary)
                }
            }
            
            Spacer()
            
            if isPairing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: OpenClawTheme.primary))
            } else if isPaired {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#22c55e"))
            } else if awaitingApproval {
                Image(systemName: "hourglass")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OpenClawTheme.surface)
        .overlay(
            Rectangle()
                .fill(OpenClawTheme.primaryGradient)
                .frame(height: 2)
                .opacity(isPaired ? 1 : 0.3),
            alignment: .bottom
        )
    }
    
    private var statusColor: Color {
        if isPaired { return Color(hex: "#22c55e") }
        if awaitingApproval { return .orange }
        if isPairing { return OpenClawTheme.primary }
        return OpenClawTheme.textMuted
    }
    
    private var statusText: String {
        if isPaired { return "Connected" }
        if awaitingApproval { return "Waiting approval..." }
        if isPairing { return "Pairing..." }
        return "Not connected"
    }
}

// MARK: - Enhanced Message Bubble
struct EnhancedMessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer()
            } else {
                // Assistant avatar
                ZStack {
                    Circle()
                        .fill(OpenClawTheme.primaryGradient)
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }
            }
            
            if message.isProcessing {
                TypingIndicator()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(OpenClawTheme.surfaceHighlight)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            } else {
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                    Text(message.content)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(message.role == .user ? .white : OpenClawTheme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Group {
                                if message.role == .user {
                                    AnyView(OpenClawTheme.primaryGradient)
                                } else {
                                    AnyView(
                                        RoundedRectangle(cornerRadius: 18)
                                            .fill(OpenClawTheme.surfaceHighlight)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 18)
                                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                                }
                            }
                        )
                        .cornerRadius(18)
                        .shadow(
                            color: message.role == .user
                                ? OpenClawTheme.primary.opacity(0.3)
                                : Color.black.opacity(0.2),
                            radius: message.role == .user ? 8 : 4,
                            x: 0,
                            y: 2
                        )
                    
                    // Timestamp
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(OpenClawTheme.textMuted)
                        .padding(.horizontal, 4)
                }
            }
            
            if message.role == .assistant {
                Spacer()
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Typing Indicator
struct TypingIndicator: View {
    @State private var animationPhase = 0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(OpenClawTheme.primary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .opacity(animationPhase == index ? 1 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animationPhase
                    )
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                animationPhase = (animationPhase + 1) % 3
            }
        }
    }
}

// MARK: - Enhanced Input Bar
struct EnhancedInputBar: View {
    @Binding var text: String
    let isRecording: Bool
    let isLoading: Bool
    let onSend: () -> Void
    let onToggleRecording: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Voice button
            Button(action: onToggleRecording) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isRecording ? OpenClawTheme.primary : OpenClawTheme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(isRecording ? OpenClawTheme.primary.opacity(0.2) : OpenClawTheme.surfaceHighlight)
                    )
                    .overlay(
                        Circle()
                            .stroke(isRecording ? OpenClawTheme.primary.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            
            // Text field
            HStack {
                TextField("Ketik pesan...", text: $text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(.horizontal, 12)
            }
            .frame(height: 44)
            .background(OpenClawTheme.surfaceHighlight)
            .cornerRadius(22)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            
            // Send button
            Button(action: onSend) {
                ZStack {
                    Circle()
                        .fill(text.isEmpty ? AnyShapeStyle(OpenClawTheme.surfaceHighlight) : AnyShapeStyle(OpenClawTheme.primaryGradient))
                        .frame(width: 44, height: 44)
                    
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(text.isEmpty ? OpenClawTheme.textMuted : .white)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(text.isEmpty && !isLoading)
            .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OpenClawTheme.surface)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - Enhanced Start Pairing View
struct EnhancedStartPairingView: View {
    let onStart: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Illustration
            ZStack {
                Circle()
                    .fill(OpenClawTheme.primary.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                Circle()
                    .fill(OpenClawTheme.primary.opacity(0.2))
                    .frame(width: 90, height: 90)
                
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 40))
                    .foregroundColor(OpenClawTheme.primary)
            }
            
            VStack(spacing: 8) {
                Text("Hubungkan ke OpenClaw")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Klik tombol di bawah untuk menghubungkan aplikasi ini dengan OpenClaw.")
                    .font(.system(size: 14))
                    .foregroundColor(OpenClawTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            
            Button(action: onStart) {
                HStack(spacing: 8) {
                    Text("Hubungkan Sekarang")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(OpenClawTheme.primaryGradient)
                )
                .glow()
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer()
        }
        .padding(32)
        .background(OpenClawTheme.background)
    }
}

// MARK: - Enhanced Approval View
struct EnhancedApprovalView: View {
    let pairingCode: String
    let onCheckAgain: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .stroke(OpenClawTheme.primary.opacity(0.3), lineWidth: 2)
                    .frame(width: 100, height: 100)
                
                Circle()
                    .fill(OpenClawTheme.primary.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "hourglass")
                    .font(.system(size: 32))
                    .foregroundColor(OpenClawTheme.primary)
            }
            
            VStack(spacing: 8) {
                Text("Menunggu Persetujuan")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Jalankan command berikut di terminal untuk approve:")
                    .font(.system(size: 13))
                    .foregroundColor(OpenClawTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            // Command box
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(OpenClawTheme.textMuted)
                    
                    Spacer()
                    
                    Button(action: {
                        let command = "openclaw pairing approve macos \(pairingCode)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(OpenClawTheme.primary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                Text("openclaw pairing approve macos \(pairingCode)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(OpenClawTheme.textPrimary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OpenClawTheme.surfaceHighlight)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .padding(16)
            .background(OpenClawTheme.surface)
            .cornerRadius(12)
            
            // Pairing code display
            VStack(spacing: 6) {
                Text("PAIRING CODE")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(OpenClawTheme.textMuted)
                    .tracking(2)
                
                Text(pairingCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(OpenClawTheme.primary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OpenClawTheme.primary.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(OpenClawTheme.primary.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
            
            Button(action: onCheckAgain) {
                Text("Cek Status")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OpenClawTheme.surfaceHighlight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer()
        }
        .padding(24)
        .background(OpenClawTheme.background)
    }
}
