import Foundation
import Combine
import Speech
import AVFoundation

class ChatViewModel: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isRecording: Bool = false
    @Published var isLoading: Bool = false
    @Published var recordingStatus: String = ""
    @Published var connectionStatus: String = ""
    @Published var elapsedTime: TimeInterval = 0

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var activeStream: SSEClient?
    private var typewriterTimer: Timer?
    private var pendingTextBuffer: String = ""
    private var processingStartedAt: Date?
    private var elapsedTimer: Timer?

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "id-ID"))
        speechRecognizer?.delegate = self
        checkConnection()
    }

    func checkConnection() {
        let server = NativeBridgeServer.shared
        if server.isRunning {
            connectionStatus = "🟢 Connected (\(server.approvedClients.count) clients)"
        } else {
            connectionStatus = "🔴 Disconnected"
        }
    }

    func sendMessage(clientId: String?) {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userMessage = Message(role: .user, content: inputText)
        messages.append(userMessage)

        let messageText = inputText
        inputText = ""
        isLoading = true

        activeStream?.cancel()
        activeStream = nil
        typewriterTimer?.invalidate()
        typewriterTimer = nil

        let processingMessage = Message(role: .assistant, content: "", isProcessing: true)
        messages.append(processingMessage)
        processingStartedAt = Date()

        var body: [String: Any] = ["message": messageText]
        if let clientId = clientId {
            body["clientId"] = clientId
        }

        let streamUrl = URL(string: "http://localhost:3456/api/macos/chat/stream")!
        print("📤 ChatViewModel.sendMessage - Streaming to: \(streamUrl)")

        let client = SSEClient()
        activeStream = client

        client.onEvent = { [weak self] eventType, payload in
            self?.handleStreamEvent(eventType: eventType, payload: payload)
        }
        client.onComplete = { [weak self] error in
            self?.handleStreamComplete(error: error)
        }
        client.connect(url: streamUrl, body: body)
    }

    private func handleStreamEvent(eventType: String?, payload: [String: Any]) {
        guard let index = messages.lastIndex(where: { $0.isProcessing }) else { return }

        if eventType != nil {
            startElapsedTimer()
        }

        switch eventType {
        case "started":
            messages[index].progressText = "🤔 Thinking..."
        case "text":
            if let chunk = payload["content"] as? String, !chunk.isEmpty {
                appendTextChunk(chunk, at: index)
            }
        case "tool":
            if let name = payload["name"] as? String {
                messages[index].progressText = "🔧 Running \(name)..."
            }
        case "thinking":
            if let text = payload["text"] as? String {
                messages[index].progressText = "💭 \(text.prefix(80))"
            }
        case "error":
            if let message = payload["message"] as? String {
                messages[index].progressText = nil
                messages[index].content += "\n\n⚠️ \(message)"
                messages[index].isProcessing = false
                isLoading = false
                typewriterTimer?.invalidate()
                typewriterTimer = nil
                pendingTextBuffer.removeAll()
                stopElapsedTimer()
            }
        case "done":
            messages[index].isProcessing = false
            messages[index].progressText = nil
            if let text = payload["text"] as? String, !text.isEmpty, messages[index].content.isEmpty {
                messages[index].content = text
            }
            isLoading = false
            typewriterTimer?.invalidate()
            typewriterTimer = nil
            pendingTextBuffer.removeAll()
            stopElapsedTimer()
        default:
            if let chunk = payload["content"] as? String {
                appendTextChunk(chunk, at: index)
            }
        }
    }

    private func handleStreamComplete(error: Error?) {
        guard let index = messages.lastIndex(where: { $0.isProcessing }) else {
            isLoading = false
            stopElapsedTimer()
            return
        }
        if let error = error {
            print("❌ SSE stream error: \(error.localizedDescription)")
            if messages[index].content.isEmpty {
                messages[index].content = "Error: \(error.localizedDescription)"
            } else {
                messages[index].content += "\n\n⚠️ Connection lost: \(error.localizedDescription)"
            }
            messages[index].isProcessing = false
            messages[index].progressText = nil
        }
        isLoading = false
        stopElapsedTimer()
        activeStream = nil
        typewriterTimer?.invalidate()
        typewriterTimer = nil
    }

    private func startElapsedTimer() {
        guard elapsedTimer == nil else { return }
        processingStartedAt = Date()
        elapsedTime = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.processingStartedAt else { return }
            self.elapsedTime = Date().timeIntervalSince(started)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func appendTextChunk(_ chunk: String, at index: Int) {
        guard index < messages.count else { return }
        pendingTextBuffer.append(chunk)
        if typewriterTimer == nil {
            typewriterTimer = Timer.scheduledTimer(withTimeInterval: 0.015, repeats: true) { [weak self] timer in
                self?.drainTypewriter(timer: timer)
            }
        }
    }

    private func drainTypewriter(timer: Timer) {
        guard let index = messages.lastIndex(where: { $0.isProcessing }) else {
            timer.invalidate()
            typewriterTimer = nil
            pendingTextBuffer.removeAll()
            return
        }
        let charsPerTick = 3
        guard !pendingTextBuffer.isEmpty else { return }
        var drained = ""
        var count = 0
        for char in pendingTextBuffer {
            if count >= charsPerTick { break }
            drained.append(char)
            count += 1
        }
        pendingTextBuffer.removeFirst(drained.count)
        messages[index].content += drained
        if pendingTextBuffer.isEmpty {
            timer.invalidate()
            typewriterTimer = nil
        }
    }

    func cancelActiveStream() {
        activeStream?.cancel()
        activeStream = nil
        typewriterTimer?.invalidate()
        typewriterTimer = nil
        pendingTextBuffer.removeAll()
        if let index = messages.lastIndex(where: { $0.isProcessing }) {
            messages[index].isProcessing = false
            messages[index].progressText = nil
        }
        isLoading = false
        stopElapsedTimer()
    }

    func clearChat() {
        messages.removeAll()
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                self?.beginRecording()
            }
        }
    }

    private func beginRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            if let result = result {
                self?.inputText = result.bestTranscription.formattedString
            }
            if error != nil {
                self?.stopRecording()
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true
    }

    private func stopRecording() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isRecording = false
    }
}
