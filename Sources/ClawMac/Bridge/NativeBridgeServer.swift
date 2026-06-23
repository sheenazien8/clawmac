import Foundation
import Network
import Combine

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

                if let request = String(data: receivedData, encoding: .utf8) {
                    if request.contains("\r\n\r\n") {
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
                                self.handleHTTPRequest(request, on: connection)
                                return
                            }
                        } else {
                            self.handleHTTPRequest(request, on: connection)
                            return
                        }
                    }
                }

                if isComplete || error != nil {
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

        if request.hasPrefix("{") {
            print("📨 Detected raw JSON body - parsing directly")
            if let data = request.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
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

        guard let index = pendingPairings.firstIndex(where: { $0.pairingCode == pairingCode }) else {
            sendResponse(connection, status: 404, body: ["error": "Invalid or expired pairing code"])
            return
        }

        let client = pendingPairings.remove(at: index)

        if let expiresAt = client.pairingExpiresAt, Date() > expiresAt {
            savePairingData()
            sendResponse(connection, status: 400, body: ["error": "Pairing code expired"])
            return
        }

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

        if let clientId = clientId {
            guard approvedClients.contains(where: { $0.clientId == clientId }) else {
                sendResponse(connection, status: 403, body: ["error": "Client not approved"])
                return
            }
        }

        print("📤 Direct chat handler - Forwarding to Clawmac")

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
