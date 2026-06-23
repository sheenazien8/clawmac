import Cocoa
import SwiftUI
import Speech
import AVFoundation
import Network
import Combine

// MARK: - Models
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var isProcessing: Bool
    var progressText: String?

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date(), isProcessing: Bool = false, progressText: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isProcessing = isProcessing
        self.progressText = progressText
    }
}

// MARK: - macOS Client Model
struct MacOSClient: Codable {
    let clientId: String
    let clientName: String
    let sessionKey: String
    var approved: Bool
    var pairingCode: String?
    var pairingExpiresAt: Date?
    let createdAt: Date
}

// MARK: - Streaming Helpers

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

final class StreamBuffer {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshotLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        var current = Data()
        for byte in data {
            if byte == 0x0A {
                if let line = String(data: current, encoding: .utf8), !line.isEmpty {
                    lines.append(line)
                }
                current.removeAll()
            } else {
                current.append(byte)
            }
        }
        return lines
    }

    func takeAllString() -> String {
        lock.lock(); defer { lock.unlock() }
        let str = String(data: data, encoding: .utf8) ?? ""
        data.removeAll()
        return str
    }
}

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

// MARK: - Native Bridge Server (Swift)
class NativeBridgeServer: ObservableObject {
    @MainActor
    static let shared = NativeBridgeServer()
    
    @Published var isRunning = false
    @Published var approvedClients: [MacOSClient] = []
    @Published var pendingPairings: [MacOSClient] = []
    
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private var activeStreams: [String: SSEWriter] = [:]
    private let port: UInt16 = 3456
    private let queue = DispatchQueue(label: "com.openclaw.bridge")
    
    // File storage
    private let credentialsDir: URL
    private let pairingFile: URL
    private let allowlistFile: URL
    
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        credentialsDir = home.appendingPathComponent(".openclaw/credentials", isDirectory: true)
        pairingFile = credentialsDir.appendingPathComponent("macos-pairing.json")
        allowlistFile = credentialsDir.appendingPathComponent("macos-allowFrom.json")
        
        createCredentialsDir()
        loadStoredData()
    }
    
    private func createCredentialsDir() {
        try? FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true, attributes: nil)
    }
    
    private func loadStoredData() {
        // Load pending pairings
        if let data = try? Data(contentsOf: pairingFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pending = json["pending"] as? [[String: Any]] {
            pendingPairings = pending.compactMap { dict in
                guard let clientId = dict["clientId"] as? String,
                      let clientName = dict["clientName"] as? String,
                      let sessionKey = dict["sessionKey"] as? String else { return nil }
                return MacOSClient(
                    clientId: clientId,
                    clientName: clientName,
                    sessionKey: sessionKey,
                    approved: false,
                    pairingCode: dict["pairingCode"] as? String,
                    pairingExpiresAt: (dict["pairingExpiresAt"] as? Double).flatMap { Date(timeIntervalSince1970: $0 / 1000) },
                    createdAt: Date(timeIntervalSince1970: (dict["createdAt"] as? Double ?? 0) / 1000)
                )
            }
        }
        
        // Load approved clients
        if let data = try? Data(contentsOf: allowlistFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let approved = json["approved"] as? [[String: Any]] {
            approvedClients = approved.compactMap { dict in
                guard let clientId = dict["clientId"] as? String,
                      let clientName = dict["clientName"] as? String,
                      let sessionKey = dict["sessionKey"] as? String else { return nil }
                return MacOSClient(
                    clientId: clientId,
                    clientName: clientName,
                    sessionKey: sessionKey,
                    approved: true,
                    pairingCode: dict["pairingCode"] as? String,
                    pairingExpiresAt: nil,
                    createdAt: Date(timeIntervalSince1970: (dict["createdAt"] as? Double ?? 0) / 1000)
                )
            }
        }
    }
    
    private func savePairingData() {
        let pending = pendingPairings.map { client -> [String: Any] in
            var dict: [String: Any] = [
                "clientId": client.clientId,
                "clientName": client.clientName,
                "sessionKey": client.sessionKey,
                "approved": client.approved,
                "createdAt": client.createdAt.timeIntervalSince1970 * 1000
            ]
            if let code = client.pairingCode {
                dict["pairingCode"] = code
            }
            if let expires = client.pairingExpiresAt {
                dict["pairingExpiresAt"] = expires.timeIntervalSince1970 * 1000
            }
            return dict
        }
        let data = try? JSONSerialization.data(withJSONObject: ["pending": pending], options: .prettyPrinted)
        try? data?.write(to: pairingFile)
    }
    
    private func saveAllowlistData() {
        let approved = approvedClients.map { client -> [String: Any] in
            var dict: [String: Any] = [
                "clientId": client.clientId,
                "clientName": client.clientName,
                "sessionKey": client.sessionKey,
                "approved": client.approved,
                "createdAt": client.createdAt.timeIntervalSince1970 * 1000
            ]
            if let code = client.pairingCode {
                dict["pairingCode"] = code
            }
            return dict
        }
        let data = try? JSONSerialization.data(withJSONObject: ["approved": approved], options: .prettyPrinted)
        try? data?.write(to: allowlistFile)
    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: port))
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        print("🟢 Native Bridge Server running on port \(self?.port ?? 0)")
                    case .failed(let error):
                        print("❌ Server failed: \(error)")
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: queue)
        } catch {
            print("❌ Failed to start server: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.activeConnections.removeAll { $0 === connection }
            }
        }
        
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection)
    }
    
    private func receiveHTTPRequest(on connection: NWConnection) {
        var receivedData = Data()
        
        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    connection.cancel()
                    return
                }
                
                if let data = data {
                    receivedData.append(data)
                }
                
                // Check if we have a complete HTTP request
                if let request = String(data: receivedData, encoding: .utf8) {
                    // Check for complete HTTP request (has \r\n\r\n for headers and content-length satisfied)
                    if request.contains("\r\n\r\n") {
                        // Check if we have complete body based on Content-Length
                        let headerEnd = request.range(of: "\r\n\r\n")!.upperBound
                        let headers = String(request[..<headerEnd])
                        
                        if let contentLengthMatch = headers.range(of: "Content-Length: "),
                           let lengthEnd = headers[contentLengthMatch.upperBound...].range(of: "\r\n") {
                            let lengthStr = String(headers[contentLengthMatch.upperBound..<lengthEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
                            if let contentLength = Int(lengthStr) {
                                let bodyStart = headerEnd
                                let bodyLength = request[bodyStart...].count
                                if bodyLength >= contentLength {
                                    self.handleHTTPRequest(request, on: connection)
                                    return
                                }
                            } else {
                                // No content length or error parsing, handle anyway
                                self.handleHTTPRequest(request, on: connection)
                                return
                            }
                        } else {
                            // No Content-Length header (e.g., GET request), handle immediately
                            self.handleHTTPRequest(request, on: connection)
                            return
                        }
                    }
                }
                
                if isComplete || error != nil {
                    // Try to handle whatever we have
                    if let request = String(data: receivedData, encoding: .utf8), !request.isEmpty {
                        self.handleHTTPRequest(request, on: connection)
                    } else {
                        connection.cancel()
                    }
                } else {
                    receiveNext()
                }
            }
        }
        
        receiveNext()
    }
    
    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        print("📨 Raw HTTP Request (first 300 chars): \(request.prefix(300))")
        
        // Check if this is a raw JSON body (not a proper HTTP request)
        if request.hasPrefix("{") {
            print("📨 Detected raw JSON body - parsing directly")
            if let data = request.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                // This is a chat request
                handleChatDirect(json: json, connection: connection)
                return
            }
        }
        
        let lines = request.split(separator: "\r\n")
        guard let firstLine = lines.first else {
            print("❌ No request line found")
            sendResponse(connection, status: 400, body: ["error": "Invalid request"])
            return
        }
        
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            print("❌ Invalid request line: \(firstLine)")
            sendResponse(connection, status: 400, body: ["error": "Invalid request line"])
            return
        }
        
        let method = String(parts[0])
        let path = String(parts[1])
        
        print("📨 HTTP \(method) \(path)")
        
        // Parse body for POST requests
        var body: [String: Any] = [:]
        if method == "POST", let bodyStart = request.range(of: "\r\n\r\n") {
            let bodyString = String(request[bodyStart.upperBound...])
            print("📨 Body string: \(bodyString)")
            if let bodyData = bodyString.data(using: .utf8) {
                body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
                print("📨 Parsed body: \(body)")
            } else {
                print("❌ Failed to decode body data")
            }
        } else if method == "POST" {
            print("⚠️ POST request but no body separator found")
        }
        
        if path == "/api/macos/chat" {
            routeRequest(method: method, path: path, body: body, connection: connection)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.routeRequest(method: method, path: path, body: body, connection: connection)
            }
        }
    }
    
    private func routeRequest(method: String, path: String, body: [String: Any], connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/health"):
            handleHealthCheck(connection)
        case ("POST", "/api/macos/pair"):
            handlePair(body: body, connection: connection)
        case ("POST", "/api/macos/approve"):
            handleApprove(body: body, connection: connection)
        case ("POST", "/api/macos/chat"):
            handleChat(body: body, connection: connection)
        case ("POST", "/api/macos/chat/stream"):
            handleChatStream(body: body, connection: connection)
        case ("GET", "/api/macos/clients"):
            handleListClients(connection)
        case ("GET", "/api/macos/pending"):
            handleListPending(connection)
        default:
            sendResponse(connection, status: 404, body: ["error": "Not found"])
        }
    }
    
    private func handleHealthCheck(_ connection: NWConnection) {
        let response: [String: Any] = [
            "status": "ok",
            "server": "native-swift",
            "macosChannel": [
                "enabled": true,
                "approvedClients": approvedClients.count,
                "pendingPairings": pendingPairings.count
            ]
        ]
        sendResponse(connection, status: 200, body: response)
    }
    
    private func handlePair(body: [String: Any], connection: NWConnection) {
        let clientName = body["clientName"] as? String ?? "macOS Client"
        let clientId = UUID().uuidString
        let pairingCode = generatePairingCode()
        
        let client = MacOSClient(
            clientId: clientId,
            clientName: clientName,
            sessionKey: "agent:main:macos:direct:\(clientId)",
            approved: false,
            pairingCode: pairingCode,
            pairingExpiresAt: Date().addingTimeInterval(3600),
            createdAt: Date()
        )
        
        pendingPairings.append(client)
        savePairingData()
        
        // Update published property
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        let response: [String: Any] = [
            "success": true,
            "pairingCode": pairingCode,
            "clientId": clientId,
            "sessionKey": client.sessionKey,
            "expiresAt": client.pairingExpiresAt?.timeIntervalSince1970 ?? 0
        ]
        sendResponse(connection, status: 200, body: response)
    }
    
    private func handleApprove(body: [String: Any], connection: NWConnection) {
        guard let pairingCode = body["pairingCode"] as? String else {
            sendResponse(connection, status: 400, body: ["error": "Missing pairingCode"])
            return
        }
        
        // Find and approve client
        guard let index = pendingPairings.firstIndex(where: { $0.pairingCode == pairingCode }) else {
            sendResponse(connection, status: 404, body: ["error": "Invalid or expired pairing code"])
            return
        }
        
        let client = pendingPairings.remove(at: index)
        
        // Check expiry
        if let expiresAt = client.pairingExpiresAt, Date() > expiresAt {
            savePairingData()
            sendResponse(connection, status: 400, body: ["error": "Pairing code expired"])
            return
        }
        
        // Approve client
        var approvedClient = client
        approvedClient.approved = true
        approvedClient.pairingExpiresAt = nil
        approvedClients.append(approvedClient)
        
        savePairingData()
        saveAllowlistData()
        
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        let response: [String: Any] = [
            "success": true,
            "clientId": approvedClient.clientId,
            "sessionKey": approvedClient.sessionKey
        ]
        sendResponse(connection, status: 200, body: response)
    }
    
    private func handleChatDirect(json: [String: Any], connection: NWConnection) {
        guard let message = json["message"] as? String else {
            sendResponse(connection, status: 400, body: ["error": "Missing message"])
            return
        }
        
        let clientId = json["clientId"] as? String
        
        // Validate client
        if let clientId = clientId {
            guard approvedClients.contains(where: { $0.clientId == clientId }) else {
                sendResponse(connection, status: 403, body: ["error": "Client not approved"])
                return
            }
        }
        
        print("📤 Direct chat handler - Forwarding to Clawmac")
        
        // Forward to Clawmac CLI
        forwardToClawmac(message: message, clientId: clientId) { responseText in
            let response: [String: Any] = [
                "success": true,
                "response": responseText ?? "No response from Clawmac"
            ]
            self.sendResponse(connection, status: 200, body: response)
        }
    }
    
    private func handleChat(body: [String: Any], connection: NWConnection) {
        guard let message = body["message"] as? String else {
            sendResponse(connection, status: 400, body: ["error": "Missing message"])
            return
        }

        let clientId = body["clientId"] as? String

        if let clientId = clientId {
            guard approvedClients.contains(where: { $0.clientId == clientId }) else {
                sendResponse(connection, status: 403, body: ["error": "Client not approved"])
                return
            }
        }

        print("📤 Forwarding message to Clawmac: \(message)")
        forwardToClawmac(message: message, clientId: clientId) { responseText in
            print("📥 Clawmac response received: \(responseText?.prefix(100) ?? "nil")...")
            let response: [String: Any] = [
                "success": true,
                "response": responseText ?? "No response from Clawmac"
            ]
            self.sendResponse(connection, status: 200, body: response)
        }
    }

    private func handleChatStream(body: [String: Any], connection: NWConnection) {
        guard let message = body["message"] as? String else {
            sendResponse(connection, status: 400, body: ["error": "Missing message"])
            return
        }

        let clientId = body["clientId"] as? String

        if let clientId = clientId {
            guard approvedClients.contains(where: { $0.clientId == clientId }) else {
                sendResponse(connection, status: 403, body: ["error": "Client not approved"])
                return
            }
        }

        print("📡 Streaming chat for: \(message.prefix(80))")

        let sse = SSEWriter(connection: connection)
        let streamId = UUID().uuidString
        activeStreams[streamId] = sse

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .cancelled:
                print("🔌 SSE client disconnected, killing stream \(streamId)")
                self.activeStreams.removeValue(forKey: streamId)
                sse.cancelStream()
            case .failed(let error):
                print("❌ SSE connection failed: \(error)")
                self.activeConnections.removeAll { $0 === connection }
                self.activeStreams.removeValue(forKey: streamId)
                sse.cancelStream()
            default:
                break
            }
        }

        sse.onCancel = { [weak self] in
            self?.activeStreams.removeValue(forKey: streamId)
        }

        forwardToClawmacStreaming(message: message, clientId: clientId, sse: sse)
    }
    
    private func forwardToClawmac(message: String, clientId: String?, completion: @escaping (String?) -> Void) {
        // Find session key
        let sessionKey: String
        if let clientId = clientId,
           let client = approvedClients.first(where: { $0.clientId == clientId }) {
            sessionKey = client.sessionKey
        } else if let defaultClient = approvedClients.first {
            sessionKey = defaultClient.sessionKey
        } else {
            print("❌ No approved clients found")
            completion(nil)
            return
        }

        print("🤖 Calling Clawmac with sessionKey: \(sessionKey)")

        // Call Clawmac CLI
        let task = Process()
        task.launchPath = "/Users/sheenazien8/.nvm/versions/node/v22.19.0/bin/openclaw"
        task.arguments = ["agent", "--session-key", sessionKey, "-m", message, "--json"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe

        task.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                print("⚠️ Clawmac stderr: \(errorOutput)")
            }

            if let output = String(data: data, encoding: .utf8) {
                print("✅ Clawmac response length: \(output.count)")
                completion(output)
            } else {
                print("❌ Failed to decode Clawmac output")
                completion(nil)
            }
        }

        do {
            try task.run()
        } catch {
            print("❌ Clawmac execution error: \(error)")
            completion(nil)
        }
    }

    private func forwardToClawmacStreaming(
        message: String,
        clientId: String?,
        sse: SSEWriter
    ) {
        let sessionKey: String
        if let clientId = clientId,
           let client = approvedClients.first(where: { $0.clientId == clientId }) {
            sessionKey = client.sessionKey
        } else if let defaultClient = approvedClients.first {
            sessionKey = defaultClient.sessionKey
        } else {
            sse.sendEvent(type: "error", data: ["message": "No approved clients"])
            sse.close()
            return
        }

        print("🤖 Streaming call to Clawmac with sessionKey: \(sessionKey)")

        sse.sendEvent(type: "started", data: [
            "sessionKey": sessionKey,
            "startedAt": Date().timeIntervalSince1970
        ])

        let task = Process()
        task.launchPath = "/Users/sheenazien8/.nvm/versions/node/v22.19.0/bin/openclaw"
        task.arguments = ["agent", "--session-key", sessionKey, "-m", message, "--json"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe

        let buffer = StreamBuffer()
        let stdoutHandle = pipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading

        sse.attachProcess(task)

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(data)
            for line in buffer.snapshotLines() {
                sse.sendEvent(type: "stdout", data: ["line": line])
            }
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("⚠️ stderr: \(str.prefix(200))")
            }
        }

        task.terminationHandler = { process in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            let remaining = stdoutHandle.readDataToEndOfFile()
            if !remaining.isEmpty {
                buffer.append(remaining)
            }
            let errorRemaining = stderrHandle.readDataToEndOfFile()
            if let errorString = String(data: errorRemaining, encoding: .utf8), !errorString.isEmpty {
                print("⚠️ stderr tail: \(errorString.prefix(200))")
            }

            let exitCode = process.terminationStatus
            let fullOutput = buffer.takeAllString()

            if exitCode != 0 && fullOutput.isEmpty {
                sse.sendEvent(type: "error", data: [
                    "message": "CLI exited with code \(exitCode)"
                ])
                sse.close()
                return
            }

            var textContent = ""
            var meta: [String: Any] = [:]
            if let jsonData = fullOutput.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                if let result = json["result"] as? [String: Any],
                   let payloads = result["payloads"] as? [[String: Any]],
                   let firstPayload = payloads.first,
                   let text = firstPayload["text"] as? String {
                    textContent = text
                }
                if let summary = json["summary"] as? String {
                    meta["summary"] = summary
                }
                if let runId = json["runId"] as? String {
                    meta["runId"] = runId
                }
                if let result = json["result"] as? [String: Any],
                   let innerMeta = result["meta"] as? [String: Any] {
                    if let duration = innerMeta["durationMs"] as? Int {
                        meta["durationMs"] = duration
                    }
                }
            } else {
                textContent = fullOutput
            }

            if !textContent.isEmpty {
                sse.sendEvent(type: "text", data: ["content": textContent])
            }

            sse.sendEvent(type: "done", data: [
                "success": true,
                "response": fullOutput,
                "text": textContent,
                "exitCode": exitCode,
                "meta": meta
            ])

            sse.close()
        }

        do {
            try task.run()
            sse.startHeartbeat(every: 15)
        } catch {
            sse.sendEvent(type: "error", data: [
                "message": "Failed to spawn CLI: \(error.localizedDescription)"
            ])
            sse.close()
        }
    }
    
    private func handleListClients(_ connection: NWConnection) {
        let clients = approvedClients.map { ["clientId": $0.clientId, "clientName": $0.clientName, "approved": $0.approved] }
        sendResponse(connection, status: 200, body: ["success": true, "clients": clients])
    }
    
    private func handleListPending(_ connection: NWConnection) {
        let pending = pendingPairings.map { ["clientId": $0.clientId, "clientName": $0.clientName, "pairingCode": $0.pairingCode ?? "", "expiresAt": $0.pairingExpiresAt?.timeIntervalSince1970 ?? 0] }
        sendResponse(connection, status: 200, body: ["success": true, "pending": pending])
    }
    
    private func sendResponse(_ connection: NWConnection, status: Int, body: [String: Any]) {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyString = String(data: bodyData, encoding: .utf8) else {
            connection.cancel()
            return
        }
        
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bodyString.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(bodyString)"
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func generatePairingCode() -> String {
        let chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        var code = ""
        for _ in 0..<8 {
            code.append(chars.randomElement()!)
        }
        return code
    }
}

// MARK: - Pairing Manager
class PairingManager: ObservableObject {
    @Published var isPaired: Bool = false
    @Published var isPairing: Bool = false
    @Published var pairingCode: String = ""
    @Published var clientId: String?
    @Published var sessionKey: String?
    @Published var pairingError: String?
    @Published var awaitingApproval: Bool = false
    
    private let userDefaults = UserDefaults.standard
    private let clientIdKey = "macos_client_id"
    private let sessionKeyKey = "macos_session_key"
    
    private var checkApprovalTimer: Timer?
    
    init() {
        let savedClientId = userDefaults.string(forKey: clientIdKey)
        let savedSessionKey = userDefaults.string(forKey: sessionKeyKey)
        
        if let savedClientId = savedClientId {
            verifyClientApproved(clientId: savedClientId, sessionKey: savedSessionKey)
        } else {
            isPaired = false
            clientId = nil
            sessionKey = nil
        }
        
        print("🔄 PairingManager init - checking saved credentials: clientId=\(savedClientId ?? "nil")")
    }
    
    deinit {
        checkApprovalTimer?.invalidate()
    }
    
    func verifyClientApproved(clientId: String, sessionKey: String?) {
        // Check in native bridge server
        let isApproved = NativeBridgeServer.shared.approvedClients.contains { $0.clientId == clientId }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if isApproved {
                self.clientId = clientId
                self.sessionKey = sessionKey
                self.isPaired = true
                print("✅ Verified: Saved client is still approved")
            } else {
                print("❌ Saved client not found, clearing credentials")
                self.clearSavedCredentials()
            }
        }
    }
    
    private func clearSavedCredentials() {
        userDefaults.removeObject(forKey: clientIdKey)
        userDefaults.removeObject(forKey: sessionKeyKey)
        clientId = nil
        sessionKey = nil
        isPaired = false
        awaitingApproval = false
        print("🗑️ Cleared saved credentials")
    }
    
    func generatePairingCode(clientName: String = "Sheena MacBook") {
        print("🚀 Generating pairing code...")
        isPairing = true
        pairingError = nil
        awaitingApproval = false
        
        let url = URL(string: "http://localhost:3456/api/macos/pair")!
        let body: [String: Any] = ["clientName": clientName]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPairing = false
                
                if let error = error {
                    self.pairingError = "Network error: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    self.pairingError = "Invalid response"
                    return
                }
                
                self.pairingCode = json["pairingCode"] as? String ?? ""
                self.clientId = json["clientId"] as? String
                self.sessionKey = json["sessionKey"] as? String
                self.awaitingApproval = true
                
                print("🎉 Pairing code generated: \(self.pairingCode)")
                
                // Start polling
                self.startCheckingApproval()
            }
        }.resume()
    }
    
    private func startCheckingApproval() {
        checkApprovalTimer?.invalidate()
        checkApprovalTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkIfApproved()
        }
    }
    
    func checkIfApproved() {
        guard let clientId = clientId else { return }
        
        let isApproved = NativeBridgeServer.shared.approvedClients.contains { $0.clientId == clientId }
        
        if isApproved {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.awaitingApproval = false
                self.isPaired = true
                self.checkApprovalTimer?.invalidate()
                self.checkApprovalTimer = nil
                
                if let clientId = self.clientId {
                    self.userDefaults.set(clientId, forKey: self.clientIdKey)
                }
                if let sessionKey = self.sessionKey {
                    self.userDefaults.set(sessionKey, forKey: self.sessionKeyKey)
                }
                
                print("✅ Client approved!")
            }
        }
    }
    
    func approvePairingCode(pairingCode: String, completion: (() -> Void)? = nil) {
        let url = URL(string: "http://localhost:3456/api/macos/approve")!
        let body: [String: Any] = ["pairingCode": pairingCode]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let success = json["success"] as? Bool, success else {
                    self.pairingError = "Approval failed"
                    completion?()
                    return
                }
                
                self.awaitingApproval = false
                self.isPaired = true
                
                if let clientId = self.clientId {
                    self.userDefaults.set(clientId, forKey: self.clientIdKey)
                }
                if let sessionKey = self.sessionKey {
                    self.userDefaults.set(sessionKey, forKey: self.sessionKeyKey)
                }
                
                print("✅ Manual approve successful!")
                completion?()
            }
        }.resume()
    }
    
    func clearPairing() {
        checkApprovalTimer?.invalidate()
        checkApprovalTimer = nil
        clearSavedCredentials()
    }
}

// MARK: - Chat ViewModel
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

        // Cancel any in-flight request before starting a new one
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

// MARK: - Views
struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var pairingManager: PairingManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
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
            
            // Content
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
            
            // Enhanced Input Bar - larger size, macOS standard colors
            HStack(spacing: 12) {
                // Voice button
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
                
                // Text field - larger, rounded
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
                
                // Send button - larger, circle
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
            
            // Copyable command box
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

// MARK: - Global Hot Key & Settings

import Carbon.HIToolbox

private let kHotKeySignature: OSType = 0x636C6177 // 'claw'

private let hotKeyCallback: EventHandlerUPP = { (_, _, userData) -> OSStatus in
    guard let userData = userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.fire()
    }
    return noErr
}

extension NSEvent.ModifierFlags {
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command) { carbon |= UInt32(cmdKey) }
        if contains(.shift) { carbon |= UInt32(shiftKey) }
        if contains(.option) { carbon |= UInt32(optionKey) }
        if contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

enum HotKeyRegistrationResult {
    case success
    case permissionDenied
    case alreadyTaken
    case failed(OSStatus)
}

enum ShortcutFormatter {
    private static let keyCodeToString: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "N", 45: "M", 46: ".", 47: "/", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        115: "Home", 116: "PgUp", 117: "Fwd Del", 119: "End",
        121: "PgDn", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        65: "Num .", 67: "Num *", 69: "Num +", 71: "Num Clear",
        75: "Num /", 76: "Num Enter", 78: "Num -", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3",
        86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7",
        91: "Num 8", 92: "Num 9"
    ]

    static func format(keyCode: Int, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyCodeToString[UInt16(keyCode)] ?? "Key \(keyCode)"
        return s
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var shortcutKeyCode: UInt32
    @Published var shortcutModifiers: UInt32
    @Published var lastErrorMessage: String?
    @Published var needsPermissionAlert: Bool = false

    private let defaults = UserDefaults.standard
    private let keyCodeKey = "globalShortcutKeyCode"
    private let modifiersKey = "globalShortcutModifiers"

    static let defaultKeyCode: UInt32 = 47
    static let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    init() {
        if defaults.object(forKey: keyCodeKey) != nil {
            var savedKey = UInt32(defaults.integer(forKey: keyCodeKey))
            var savedMods = UInt32(defaults.integer(forKey: modifiersKey))
            // Migrate: if saved is the old default (Space + cmd|shift), use new default (Period + cmd|shift)
            if savedKey == 49, savedMods == UInt32(cmdKey | shiftKey) {
                savedKey = Self.defaultKeyCode
                savedMods = Self.defaultModifiers
                defaults.set(Int(savedKey), forKey: keyCodeKey)
                defaults.set(Int(savedMods), forKey: modifiersKey)
                defaults.synchronize()
            }
            self.shortcutKeyCode = savedKey
            self.shortcutModifiers = savedMods
        } else {
            self.shortcutKeyCode = Self.defaultKeyCode
            self.shortcutModifiers = Self.defaultModifiers
            defaults.set(Int(Self.defaultKeyCode), forKey: keyCodeKey)
            defaults.set(Int(Self.defaultModifiers), forKey: modifiersKey)
            defaults.synchronize()
        }
    }

    func setShortcut(keyCode: UInt32, modifiers: UInt32) {
        shortcutKeyCode = keyCode
        shortcutModifiers = modifiers
        defaults.set(Int(keyCode), forKey: keyCodeKey)
        defaults.set(Int(modifiers), forKey: modifiersKey)
    }

    func resetToDefault() {
        setShortcut(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers)
    }
}

@MainActor
final class HotKeyManager {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: kHotKeySignature, id: 1)
    private var trigger: (() -> Void)?

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    func register(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping @MainActor () -> Void) -> HotKeyRegistrationResult {
        unregister()

        guard CGRequestListenEventAccess() else {
            return .permissionDenied
        }

        trigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userDataPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = withUnsafePointer(to: &eventType) { ptr -> OSStatus in
            InstallEventHandler(
                GetEventDispatcherTarget(),
                hotKeyCallback,
                1,
                ptr,
                userDataPtr,
                &eventHandler
            )
        }

        guard installStatus == noErr else {
            print("⚠️ HotKeyManager: failed to install event handler (\(installStatus))")
            return .failed(installStatus)
        }

        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard regStatus == noErr else {
            print("⚠️ HotKeyManager: failed to register hot key (\(regStatus))")
            if let handler = eventHandler {
                RemoveEventHandler(handler)
                eventHandler = nil
            }
            if regStatus == OSStatus(eventHotKeyExistsErr) {
                return .alreadyTaken
            }
            return .failed(regStatus)
        }

        hotKeyRef = ref
        print("✅ HotKeyManager: registered keyCode=\(keyCode) modifiers=\(modifiers)")
        return .success
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        trigger = nil
    }

    fileprivate func fire() {
        trigger?()
    }
}

final class ShortcutRecorderModel: ObservableObject {
    @Published var isRecording: Bool = false
    private var monitor: Any?
    var onCapture: ((Int, UInt32) -> Void)?
    var onCancel: (() -> Void)?

    private static let modifierKeyCodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63
    ]

    func startMonitoring() {
        stopMonitoring()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
            return nil
        }
    }

    func stopMonitoring() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isRecording = false
    }

    private func handle(event: NSEvent) {
        if event.keyCode == 53 {
            stopMonitoring()
            onCancel?()
            return
        }
        if Self.modifierKeyCodes.contains(event.keyCode) {
            return
        }
        let mods = event.modifierFlags.carbonModifiers
        let kc = Int(event.keyCode)
        stopMonitoring()
        onCapture?(kc, mods)
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settingsStore: SettingsStore) {
        NSApp.setActivationPolicy(.regular)
        let view = SettingsView(settingsStore: settingsStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clawmac Settings"
        window.contentViewController = NSHostingController(rootView: view)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        DispatchQueue.main.async {
            self.window?.makeKey()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    init() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Clawmac"
        window.contentViewController = NSHostingController(rootView: AboutView())
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        DispatchQueue.main.async {
            self.window?.makeKey()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var permissionAlertShown = Bool(false)

    var body: some View {
        Form {
            Section("Shortcut") {
                shortcutButton
                Button("Reset to Default") {
                    settingsStore.resetToDefault()
                }
                .buttonStyle(.link)

                if let error = settingsStore.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("App") {
                LabeledContent("Name", value: "Clawmac")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
                Text("AI Assistant macOS app from the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Quit Clawmac", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
        .alert("Input Monitoring Required", isPresented: $permissionAlertShown) {
            Button("Open System Settings") {
                openInputMonitoringSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clawmac needs the Input Monitoring permission to register the global shortcut. Open System Settings → Privacy & Security → Input Monitoring and enable Clawmac.")
        }
        .onChange(of: settingsStore.needsPermissionAlert) { _, newValue in
            if newValue {
                permissionAlertShown = true
                settingsStore.needsPermissionAlert = false
            }
        }
    }

    private var shortcutButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopMonitoring()
            } else {
                recorder.onCapture = { kc, mods in
                    settingsStore.setShortcut(keyCode: UInt32(kc), modifiers: mods)
                }
                recorder.onCancel = {}
                recorder.startMonitoring()
            }
        } label: {
            HStack {
                if recorder.isRecording {
                    Text("Press a key combo…")
                        .foregroundColor(.accentColor)
                    Spacer()
                    Text("Esc to cancel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(ShortcutFormatter.format(
                        keyCode: Int(settingsStore.shortcutKeyCode),
                        modifiers: settingsStore.shortcutModifiers
                    ))
                    .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("Click to record")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIconImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            Text("Clawmac")
                .font(.title)
                .fontWeight(.semibold)

            Text("Version \(appVersion) (\(appBuild))")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("AI Assistant macOS app from the menu bar.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Open on GitHub") {
                if let url = URL(string: "https://github.com/sheenazien8/clawmac/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)

            Spacer()

            Text("© 2026 sheenazien8")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 360, height: 360)
    }

    private func appIconImage() -> NSImage {
        if let url = Bundle.module.url(forResource: "OpenClawLogo", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 96, height: 96)
            return image
        }
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
            return image
        }
        return NSImage()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - App Delegate

final class ChatHostingController: NSHostingController<ChatView> {
    override func viewDidAppear() {
        super.viewDidAppear()

        guard let window = view.window else { return }
        window.makeKey()

        func attemptFocus(attempt: Int) {
            guard attempt < 5 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(attempt + 1)) { [weak self] in
                guard let self = self, let window = self.view.window, window.isVisible else { return }
                window.makeKey()
                if let textField = Self.findTextField(in: self.view) {
                    if window.makeFirstResponder(textField) {
                        print("✅ Autofocus succeeded on attempt \(attempt + 1)")
                    } else {
                        print("⚠️ makeFirstResponder returned false on attempt \(attempt + 1)")
                    }
                } else {
                    print("⚠️ NSTextField not found on attempt \(attempt + 1)")
                    if attempt < 4 {
                        attemptFocus(attempt: attempt + 1)
                    }
                }
            }
        }

        attemptFocus(attempt: 0)
    }

    private static func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField { return textField }
        for subview in view.subviews {
            if let found = findTextField(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var chatViewModel = ChatViewModel()
    var pairingManager = PairingManager()

    let settingsStore = SettingsStore.shared
    var hotKeyManager = HotKeyManager()
    var settingsWindowController: SettingsWindowController?
    var aboutWindowController: AboutWindowController?
    private var statusItemMenu: NSMenu?
    private var settingsCancellable: AnyCancellable?
    private var lastRegisteredKeyCode: UInt32 = UInt32.max
    private var lastRegisteredModifiers: UInt32 = UInt32.max

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start native bridge server
        NativeBridgeServer.shared.start()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let url = Bundle.module.url(forResource: "OpenClawLogo", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                image.accessibilityDescription = "Clawmac"
                button.image = image
            }

            setupStatusItemMenu()
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover
        let chatView = ChatView(viewModel: chatViewModel, pairingManager: pairingManager)
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 380, height: 600)
        popover?.behavior = .transient
        popover?.contentViewController = ChatHostingController(rootView: chatView)

        // Observe settings changes for live hot-key re-registration
        settingsCancellable = settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reregisterHotKeyIfNeeded()
                }
            }

        // Register the persisted (or default) hot key on launch
        reregisterHotKeyIfNeeded(force: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
    }

    private func setupStatusItemMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "Open Chat", action: #selector(openChatFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Clawmac", action: #selector(openAboutFromMenu), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Clawmac", action: #selector(quitAppFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItemMenu = menu
    }

    private func reregisterHotKeyIfNeeded(force: Bool = false) {
        let kc = settingsStore.shortcutKeyCode
        let mods = settingsStore.shortcutModifiers
        if !force, kc == lastRegisteredKeyCode, mods == lastRegisteredModifiers {
            return
        }
        let result = hotKeyManager.register(keyCode: kc, modifiers: mods) { [weak self] in
            self?.togglePopover()
        }
        lastRegisteredKeyCode = kc
        lastRegisteredModifiers = mods

        switch result {
        case .success:
            settingsStore.lastErrorMessage = nil
            settingsStore.needsPermissionAlert = false
        case .permissionDenied:
            settingsStore.lastErrorMessage = nil
            settingsStore.needsPermissionAlert = true
        case .alreadyTaken:
            settingsStore.lastErrorMessage = "Shortcut already in use by another app — try a different combo."
            settingsStore.needsPermissionAlert = false
        case .failed(let code):
            settingsStore.lastErrorMessage = "Failed to register shortcut (code \(code))."
            settingsStore.needsPermissionAlert = false
        }
    }

    @objc private func handleAppWillResignActive() {
        if popover?.isShown == true {
            chatViewModel.cancelActiveStream()
            popover?.performClose(nil)
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        if popover?.isShown == true {
            chatViewModel.cancelActiveStream()
            popover?.performClose(nil)
        }
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                chatViewModel.cancelActiveStream()
                popover?.performClose(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isOptionClick = event?.modifierFlags.contains(.option) ?? false
        if isRightClick || isOptionClick {
            showStatusItemMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusItemMenu() {
        guard let menu = statusItemMenu, let statusItem = statusItem else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: (statusItem.button?.bounds.maxY ?? 0) + 4), in: statusItem.button)
    }

    @objc private func openChatFromMenu() {
        togglePopover()
    }

    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }

    @objc private func openAboutFromMenu() {
        openAboutWindow()
    }

    @objc private func quitAppFromMenu() {
        NSApp.terminate(nil)
    }

    private func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
        }
        settingsWindowController?.showWindow(nil)
    }

    private func openAboutWindow() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
    }
}

@main
struct ClawmacMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
