import CallKit
import AVFoundation

class CallKitCallInterfaceAdapter: NSObject {
    
    private let provider: CXProvider
    private let callController = CXCallController()
    
    private unowned var manager: CallManager
    
    private var pendingAnswerAction: CXAnswerCallAction?
    
    required init(manager: CallManager) {
        self.manager = manager
        let config = CXProviderConfiguration(localizedName: Bundle.main.displayName)
        config.ringtoneSound = "call.caf"
        config.iconTemplateImageData = R.image.call.ic_mixin()?.pngData()
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportsVideo = false
        config.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }
    
    @available(*, unavailable)
    override init() {
        fatalError()
    }
    
    private func request(action: CXAction, completion: @escaping CallInterfaceCompletion) {
        if #available(iOS 11.0, *) {
            callController.requestTransaction(with: action, completion: completion)
        } else {
            let transaction = CXTransaction(action: action)
            callController.request(transaction, completion: completion)
        }
    }
    
}

extension CallKitCallInterfaceAdapter: CallInterfaceAdapter {
    
    func requestStartCall(uuid: UUID, handle: Call.Handle, completion: @escaping CallInterfaceCompletion) {
        pendingAnswerAction = nil
        let action = CXStartCallAction(call: uuid, handle: handle.cxHandle)
        request(action: action, completion: completion)
    }
    
    func requestEndCall(uuid: UUID, completion: @escaping CallInterfaceCompletion) {
        pendingAnswerAction = nil
        let action = CXEndCallAction(call: uuid)
        request(action: action, completion: completion)
    }
    
    func requestSetMute(uuid: UUID, muted: Bool, completion: @escaping CallInterfaceCompletion) {
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        request(action: action, completion: completion)
    }
    
    func reportNewIncomingCall(uuid: UUID, handle: Call.Handle, localizedCallerName: String, completion: @escaping CallInterfaceCompletion) {
        pendingAnswerAction = nil
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
        let update = CXCallUpdate()
        update.remoteHandle = handle.cxHandle
        update.localizedCallerName = localizedCallerName
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update, completion: completion)
    }
    
    func reportCall(uuid: UUID, EndedByReason reason: Call.EndedReason) {
        pendingAnswerAction = nil
        provider.reportCall(with: uuid, endedAt: nil, reason: reason.cxEndedReason)
    }
    
    func reportOutgoingCallStartedConnecting(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
    }
    
    func reportOutgoingCallConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }
    
    func reportIncomingCallConnected(uuid: UUID) {
        guard let action = pendingAnswerAction, action.callUUID == uuid else {
            return
        }
        action.fulfill()
        pendingAnswerAction = nil
    }
    
}

extension CallKitCallInterfaceAdapter: CXProviderDelegate {
    
    func providerDidReset(_ provider: CXProvider) {
        pendingAnswerAction = nil
        manager.clean()
    }
    
    func providerDidBegin(_ provider: CXProvider) {
        
    }
    
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        if let handle = Call.Handle(cxHandle: action.handle) {
            manager.startCall(uuid: action.callUUID, handle: handle) { (success) in
                success ? action.fulfill() : action.fail()
            }
        } else {
            manager.alert(error: .invalidHandle)
            action.fail()
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        manager.answerCall(uuid: action.callUUID) { (success) in
            if success {
                self.pendingAnswerAction = action
            } else {
                action.fail()
            }
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        manager.endCall(uuid: action.callUUID)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        manager.setMute(uuid: action.callUUID, muted: action.isMuted)
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        if let call = self.manager.call, call.isOutgoing {
            self.manager.ringtonePlayer?.play()
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        
    }
    
}

fileprivate extension Call.Handle {
    
    var cxHandle: CXHandle {
        switch self {
        case .phoneNumber(let number):
            return CXHandle(type: .phoneNumber, value: number)
        case .userId(let userId):
            return CXHandle(type: .generic, value: userId)
        }
    }
    
    init?(cxHandle: CXHandle) {
        switch cxHandle.type {
        case .generic:
            self = .userId(cxHandle.value)
        case .phoneNumber, .emailAddress:
            // This is not expected to happen according to current CXProviderConfiguration
            return nil
        }
    }
    
}

fileprivate extension Call.EndedReason {
    
    var cxEndedReason: CXCallEndedReason {
        switch self {
        case .failed:
            return .failed
        case .remoteEnded:
            return .remoteEnded
        case .unanswered:
            return .unanswered
        }
    }
    
}
