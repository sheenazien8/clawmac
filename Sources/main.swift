import Cocoa
import SwiftUI
import Speech
import AVFoundation
import Network

// MARK: - Models
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var isProcessing: Bool
    
    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date(), isProcessing: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isProcessing = isProcessing
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

// MARK: - Native Bridge Server (Swift)
class NativeBridgeServer: ObservableObject {
    @MainActor
    static let shared = NativeBridgeServer()
    
    @Published var isRunning = false
    @Published var approvedClients: [MacOSClient] = []
    @Published var pendingPairings: [MacOSClient] = []
    
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
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
        
        DispatchQueue.main.async { [weak self] in
            self?.routeRequest(method: method, path: path, body: body, connection: connection)
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
        
        // Validate client
        if let clientId = clientId {
            guard approvedClients.contains(where: { $0.clientId == clientId }) else {
                sendResponse(connection, status: 403, body: ["error": "Client not approved"])
                return
            }
        }
        
        // Forward to Clawmac CLI
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
        
        do {
            try task.run()
            task.waitUntilExit()
            
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
        } catch {
            print("❌ Clawmac execution error: \(error)")
            completion(nil)
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
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
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
        
        let processingMessage = Message(role: .assistant, content: "", isProcessing: true)
        messages.append(processingMessage)
        
        // Send to local bridge
        let url = URL(string: "http://localhost:3456/api/macos/chat")!
        var body: [String: Any] = ["message": messageText]
        if let clientId = clientId {
            body["clientId"] = clientId
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            print("❌ Failed to serialize body")
            self.messages.removeLast()
            self.messages.append(Message(role: .assistant, content: "Failed to create request"))
            self.isLoading = false
            return
        }
        request.httpBody = httpBody
        
        print("📤 ChatViewModel.sendMessage - Sending to: \(url)")
        print("📤 Headers: Content-Type=application/json")
        print("📤 Body: \(body)")
        print("📤 Body size: \(httpBody.count) bytes")
        
        // Use ephemeral session to avoid caching issues
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                print("📥 ChatViewModel.sendMessage - Response received")
                print("📥 error: \(String(describing: error))")
                print("📥 HTTP response: \(String(describing: response))")
                print("📥 data: \(data != nil ? "\(data!.count) bytes" : "nil")")
                
                if let lastMessage = self.messages.last, lastMessage.isProcessing {
                    self.messages.removeLast()
                }
                
                if let error = error {
                    print("❌ Network error: \(error.localizedDescription)")
                    self.messages.append(Message(role: .assistant, content: "Error: \(error.localizedDescription)"))
                    self.isLoading = false
                    return
                }
                
                guard let data = data else {
                    print("❌ No data received")
                    self.messages.append(Message(role: .assistant, content: "No data"))
                    self.isLoading = false
                    return
                }
                
                // Try to parse JSON
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let rawString = String(data: data, encoding: .utf8) ?? "invalid"
                    print("❌ Failed to parse JSON. Raw: \(rawString.prefix(200))")
                    self.messages.append(Message(role: .assistant, content: "Invalid JSON response"))
                    self.isLoading = false
                    return
                }
                
                guard let responseJsonString = json["response"] as? String else {
                    print("❌ No 'response' field in JSON: \(json.keys)")
                    self.messages.append(Message(role: .assistant, content: "No response field"))
                    self.isLoading = false
                    return
                }
                
                print("📥 response field length: \(responseJsonString.count)")
                
                // Parse the nested JSON response from Clawmac CLI
                let finalText: String
                if let responseData = responseJsonString.data(using: .utf8),
                   let responseJson = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let result = responseJson["result"] as? [String: Any],
                   let payloads = result["payloads"] as? [[String: Any]],
                   let firstPayload = payloads.first,
                   let text = firstPayload["text"] as? String {
                    finalText = text
                    print("✅ Parsed text: \(text)")
                } else {
                    // Fallback: just show the raw response
                    finalText = responseJsonString.prefix(500) + "..."
                    print("⚠️ Fallback to raw response")
                }
                
                self.messages.append(Message(role: .assistant, content: finalText))
                self.isLoading = false
            }
        }.resume()
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
                    Image(systemName: "message.fill")
                        .foregroundColor(pairingManager.isPaired ? .blue : .orange)
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
                        MessageBubble(message: message)
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
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            if message.isProcessing {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
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
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundColor(message.role == .user ? .white : .primary)
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
            
            if message.role == .assistant {
                Spacer()
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

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var chatViewModel = ChatViewModel()
    var pairingManager = PairingManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start native bridge server
        NativeBridgeServer.shared.start()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use a distinctive AI-themed SF Symbol
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Clawmac")
            
            if let img = image?.withSymbolConfiguration(config) {
                img.isTemplate = true  // Follow system appearance
                button.image = img
            }
            
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // Create popover
        let chatView = ChatView(viewModel: chatViewModel, pairingManager: pairingManager)
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 380, height: 600)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: chatView)
    }
    
    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
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
