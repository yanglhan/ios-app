import Foundation

struct SignalKeyResponse: Codable {

    let identityKey: String
    let signedPreKey: SignedPreKeyRequest
    let preKey: OneTimePreKey
    let registrationId: UInt32
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case identityKey = "identity_key"
        case signedPreKey = "signed_pre_key"
        case preKey = "one_time_pre_key"
        case registrationId = "registration_id"
        case userId = "user_id"
    }
}


extension SignalKeyResponse {
    func getPreKeyPublic() -> Data {
        return Data(base64Encoded: preKey.pub_key)!
    }

    func getIdentityPublic() -> Data {
        return Data(base64Encoded: identityKey)!
    }

    func getSignedPreKeyPublic() -> Data {
        return Data(base64Encoded: signedPreKey.pub_key)!
    }

    func getSignedSignature() -> Data {
        return Data(base64Encoded: signedPreKey.signature)!
    }
}
