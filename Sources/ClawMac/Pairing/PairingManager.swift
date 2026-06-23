import Foundation
import Combine

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
