import Foundation
import Network

final class SSEWriter {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.openclaw.sse-writer")
    private var headersSent = false
    private var closed = false
    private var heartbeatTimer: DispatchSourceTimer?
    private weak var process: Process?
    var onCancel: (() -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func attachProcess(_ task: Process) {
        process = task
    }

    func sendEvent(type: String?, data: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }
            self.ensureHeaders()
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }
            var payload = ""
            if let type = type {
                payload += "event: \(type)\n"
            }
            for line in jsonString.split(separator: "\n", omittingEmptySubsequences: false) {
                payload += "data: \(line)\n"
            }
            payload += "\n"
            self.connection.send(
                content: payload.data(using: .utf8),
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { error in
                    if let error = error {
                        print("⚠️ SSE send error: \(error)")
                    }
                }
            )
        }
    }

    func sendComment(_ text: String) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }
            self.ensureHeaders()
            let payload = ": \(text)\n\n"
            self.connection.send(
                content: payload.data(using: .utf8),
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { _ in }
            )
        }
    }

    func startHeartbeat(every seconds: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler { [weak self] in
            self?.sendComment("heartbeat")
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func close() {
        queue.async { [weak self] in
            self?.finalize()
        }
    }

    func cancelStream() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let task = self.process, task.isRunning {
                print("🛑 Terminating CLI process (stream cancelled)")
                task.terminate()
            }
            self.finalize()
            self.onCancel?()
        }
    }

    private func finalize() {
        guard !closed else { return }
        closed = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                self.connection.cancel()
            }
        )
    }

    private func ensureHeaders() {
        guard !headersSent else { return }
        headersSent = true
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "X-Accel-Buffering: no",
            "Access-Control-Allow-Origin: *",
            "",
            ""
        ].joined(separator: "\r\n")
        connection.send(
            content: headers.data(using: .utf8),
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { _ in }
        )
    }
}
