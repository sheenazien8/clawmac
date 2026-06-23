import Foundation

final class SSEClient: NSObject {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private let parseQueue = DispatchQueue(label: "com.openclaw.sse-client")
    private var completed = false

    var onEvent: ((String?, [String: Any]) -> Void)?
    var onComplete: ((Error?) -> Void)?

    func connect(url: URL, body: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]

        let delegate = SSESessionDelegate(client: self)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        print("📡 SSEClient: connected to \(url)")
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        onEvent = nil
        onComplete = nil
        task?.cancel()
        session?.invalidateAndCancel()
        print("📡 SSEClient: cancelled")
    }

    fileprivate func didReceiveData(_ data: Data) {
        parseQueue.async { [weak self] in
            guard let self = self else { return }
            self.buffer.append(data)
            self.drainEvents(flush: false)
        }
    }

    fileprivate func didCompleteWithError(_ error: Error?) {
        parseQueue.async { [weak self] in
            guard let self = self, !self.completed else { return }
            self.completed = true
            self.drainEvents(flush: true)
            let complete = self.onComplete
            self.onComplete = nil
            DispatchQueue.main.async {
                complete?(error)
            }
        }
    }

    private func drainEvents(flush: Bool) {
        let separator = Data([0x0A, 0x0A])
        while let range = buffer.range(of: separator) {
            let eventData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            parseEvent(eventData)
        }
        if flush && !buffer.isEmpty {
            parseEvent(buffer)
            buffer.removeAll()
        }
    }

    private func parseEvent(_ raw: Data) {
        guard let str = String(data: raw, encoding: .utf8) else { return }
        var eventType: String?
        var dataLines: [String] = []
        for rawLine in str.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst("event:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(
                    String(line.dropFirst("data:".count))
                        .trimmingCharacters(in: .whitespaces)
                )
            }
        }
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        guard let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            print("⚠️ SSEClient: non-JSON event payload")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(eventType, json)
        }
    }
}

private final class SSESessionDelegate: NSObject, URLSessionDataDelegate {
    weak var client: SSEClient?
    init(client: SSEClient) { self.client = client }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.didReceiveData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        client?.didCompleteWithError(error)
    }
}
