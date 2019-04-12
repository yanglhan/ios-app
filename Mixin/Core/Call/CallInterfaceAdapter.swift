import Foundation

typealias CallInterfaceCompletion = (Error?) -> Void

protocol CallInterfaceAdapter {
    func requestStartCall(uuid: UUID, handle: Call.Handle, completion: @escaping CallInterfaceCompletion)
    func requestEndCall(uuid: UUID, completion: @escaping CallInterfaceCompletion)
    func requestSetMute(uuid: UUID, muted: Bool, completion: @escaping CallInterfaceCompletion)
    func reportNewIncomingCall(uuid: UUID, handle: Call.Handle, localizedCallerName: String, completion: @escaping CallInterfaceCompletion)
    func reportCall(uuid: UUID, EndedByReason reason: Call.EndedReason)
    func reportOutgoingCallStartedConnecting(uuid: UUID)
    func reportOutgoingCallConnected(uuid: UUID)
    func reportIncomingCallConnected(uuid: UUID)
}
