import Foundation

enum CallError: Error {
    
    case busy
    case invalidUUID(uuid: String)
    case invalidSdp(sdp: String?)
    case missingUser(userId: String)
    case networkFailure
    case microphonePermissionDenied
    case invalidHandle
    
    var alertContent: String? {
        switch self {
        case .busy:
            return Localized.CALL_HINT_ON_ANOTHER_CALL
        case .networkFailure:
            return Localized.CALL_NO_NETWORK
        case .microphonePermissionDenied:
            return Localized.CALL_NO_MICROPHONE_PERMISSION
        default:
            return nil
        }
    }
    
}

class Call {
    
    enum Handle {
        case phoneNumber(String)
        case userId(String)
    }
    
    enum EndedReason {
        case failed
        case remoteEnded
        case unanswered
    }
    
    let uuid: UUID
    let opponentUser: UserItem
    let isOutgoing: Bool
    
    var connectedDate: Date?
    
    private(set) lazy var uuidString = uuid.uuidString.lowercased() // Message Id from offer message
    private(set) lazy var conversationId = ConversationDAO.shared.makeConversationId(userId: AccountAPI.shared.accountUserId, ownerUserId: opponentUser.userId)
    private(set) lazy var raisedByUserId = isOutgoing ? AccountAPI.shared.accountUserId : opponentUser.userId
    
    init(uuid: UUID, opponentUser: UserItem, isOutgoing: Bool) {
        self.uuid = uuid
        self.opponentUser = opponentUser
        self.isOutgoing = isOutgoing
    }
    
}
