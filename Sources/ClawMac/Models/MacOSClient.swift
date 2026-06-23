import Foundation

struct MacOSClient: Codable {
    let clientId: String
    let clientName: String
    let sessionKey: String
    var approved: Bool
    var pairingCode: String?
    var pairingExpiresAt: Date?
    let createdAt: Date
}
