import Foundation
import WebRTC
import CallKit

class CallManager {
    
    typealias PendingOffer = (call: Call, sdp: RTCSessionDescription)
    
    static let shared = CallManager()
    static let unansweredTimeoutInterval: TimeInterval = 60
    static let callEndedCategories: [MessageCategory] = [
        .WEBRTC_AUDIO_END,
        .WEBRTC_AUDIO_BUSY,
        .WEBRTC_AUDIO_CANCEL,
        .WEBRTC_AUDIO_FAILED,
        .WEBRTC_AUDIO_DECLINE
    ]
    
    let queue = DispatchQueue(label: "one.mixin.messenger.call_manager")
    let ringtonePlayer = try? AVAudioPlayer(contentsOf: R.file.callCaf()!)
    
    private let rtcClient = WebRTCClient()
    
    var interfaceAdapter: CallInterfaceAdapter {
        if usesCallKit && AVAudioSession.sharedInstance().recordPermission == .granted {
            return callKitInterfaceAdapter
        } else {
            return nativeInterfaceAdapter
        }
    }
    
    private(set) var call: Call?
    
    private(set) lazy var view: CallView = performSynchronouslyOnMainThread {
        let view = CallView(effect: UIBlurEffect(style: .dark))
        view.manager = self
        return view
    }
    
    private lazy var callKitInterfaceAdapter = CallKitCallInterfaceAdapter(manager: self)
    private lazy var nativeInterfaceAdapter = NativeCallInterfaceAdapter(manager: self)
    
    private var unansweredTimer: Timer?
    
    private var usesCallKit: Bool {
        return true
    }
    
    var pendingOffers = [UUID: PendingOffer]()
    
    init() {
        RTCAudioSession.sharedInstance().useManualAudio = true
        rtcClient.delegate = self
        ringtonePlayer?.numberOfLoops = -1
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(audioSessionRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}

// MARK: - Interface
extension CallManager {
    
    func handleIncomingBlazeMessageData(_ data: BlazeMessageData) {
        queue.async {
            switch data.category {
            case MessageCategory.WEBRTC_AUDIO_OFFER.rawValue:
                self.handleOffer(data: data)
            case MessageCategory.WEBRTC_ICE_CANDIDATE.rawValue:
                self.handleIceCandidate(data: data)
            default:
                self.handleCallStatusChange(data: data)
            }
        }
    }
    
    func requestStartCall(opponentUser: UserItem) {
        let uuid = UUID()
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
        } catch {
            UIApplication.trackError(#file, action: #function, userInfo: ["error": error])
        }
        interfaceAdapter.requestStartCall(uuid: uuid, handle: .userId(opponentUser.userId)) { (error) in
            if let error = error as? CallError {
                self.alert(error: error)
            } else if let error = error {
                showHud(style: .error, text: error.localizedDescription)
            }
        }
    }
    
    func requestEndCall() {
        guard let uuid = call?.uuid ?? pendingOffers.first?.key else {
            return
        }
        interfaceAdapter.requestEndCall(uuid: uuid) { (error) in
            if let error = error {
                // Don't think we would get error here
                UIApplication.trackError(#file, action: #function, userInfo: ["error": error])
                self.endCall(uuid: uuid)
            }
        }
    }
    
    func requestAnswerCall() {
        guard let uuid = pendingOffers.first?.key else {
            return
        }
        answerCall(uuid: uuid, completion: nil)
    }
    
    func requestSetMute(_ muted: Bool) {
        guard let uuid = call?.uuid else {
            return
        }
        interfaceAdapter.requestSetMute(uuid: uuid, muted: muted) { (error) in
            if let error = error {
                UIApplication.trackError(#file, action: #function, userInfo: ["error": error])
            }
        }
    }
    
    func alert(error: CallError) {
        guard let content = error.alertContent else {
            return
        }
        DispatchQueue.main.async {
            if case .microphonePermissionDenied = error {
                AppDelegate.current.window?.rootViewController?.alertSettings(content)
            } else {
                AppDelegate.current.window?.rootViewController?.alert(content)
            }
        }
    }
    
    func setOverridePortToSpeaker(_ usesSpeaker: Bool) {
        let port: AVAudioSession.PortOverride = usesSpeaker ? .speaker : .none
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(port)
    }
    
}

// MARK: - Callback
extension CallManager {
    
    func startCall(uuid: UUID, handle: Call.Handle, completion: ((Bool) -> Void)?) {
        AudioManager.shared.stop(deactivateAudioSession: false)
        queue.async {
            guard case let .userId(userId) = handle else {
                self.alert(error: .invalidHandle)
                completion?(false)
                return
            }
            guard let opponentUser = UserDAO.shared.getUser(userId: userId) else {
                self.alert(error: .invalidHandle)
                completion?(false)
                return
            }
            guard WebSocketService.shared.connected else {
                self.alert(error: .networkFailure)
                completion?(false)
                return
            }
            DispatchQueue.main.sync {
                self.view.style = .outgoing
                self.view.reload(user: opponentUser)
                self.view.show()
            }
            let call = Call(uuid: uuid, opponentUser: opponentUser, isOutgoing: true)
            let conversationId = call.conversationId
            self.call = call
            let timer = Timer(timeInterval: CallManager.unansweredTimeoutInterval,
                              target: self,
                              selector: #selector(self.unansweredTimeout),
                              userInfo: nil,
                              repeats: false)
            RunLoop.main.add(timer, forMode: .default)
            self.unansweredTimer = timer
            self.rtcClient.offer { (sdp, error) in
                guard let sdp = sdp else {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: false,
                                             reportAction: "SDP Construction",
                                             description: error.debugDescription)
                        completion?(false)
                    }
                    return
                }
                guard let content = sdp.jsonString else {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: false,
                                             reportAction: "SDP Serialization",
                                             description: sdp.debugDescription)
                        completion?(false)
                    }
                    return
                }
                let msg = Message.createWebRTCMessage(messageId: call.uuidString,
                                                      conversationId: conversationId,
                                                      category: .WEBRTC_AUDIO_OFFER,
                                                      content: content,
                                                      status: .SENDING)
                SendMessageService.shared.sendMessage(message: msg, ownerUser: opponentUser, isGroupMessage: false)
                completion?(true)
            }
        }
    }
    
    func answerCall(uuid: UUID, completion: ((Bool) -> Void)?) {
        queue.async {
            guard let (call, sdp) = self.pendingOffers[uuid] else {
                return
            }
            self.pendingOffers.removeValue(forKey: uuid)
            self.call = call // TODO: Fail other pending calls
            self.ringtonePlayer?.stop()
            self.rtcClient.set(remoteSdp: sdp) { (error) in
                if let error = error {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: true,
                                             reportAction: "Set remote Sdp",
                                             description: error.localizedDescription)
                        completion?(false)
                    }
                } else {
                    self.rtcClient.answer(completion: { (sdp, error) in
                        self.queue.async {
                            if let sdp = sdp, let content = sdp.jsonString {
                                let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                                      category: .WEBRTC_AUDIO_ANSWER,
                                                                      content: content,
                                                                      status: .SENDING,
                                                                      quoteMessageId: call.uuidString)
                                SendMessageService.shared.sendMessage(message: msg,
                                                                      ownerUser: call.opponentUser,
                                                                      isGroupMessage: false)
                                DispatchQueue.main.sync {
                                    self.view.style = .connecting
                                    self.view.reload(user: call.opponentUser)
                                    self.view.show()
                                }
                                completion?(true)
                            } else {
                                self.failCurrentCall(sendFailedMessageToRemote: true,
                                                     reportAction: "Answer construction",
                                                     description: error.debugDescription)
                                completion?(false)
                            }
                        }
                    })
                }
            }
        }
    }
    
    func endCall(uuid: UUID) {
        queue.async {
            
            func sendEndMessage(call: Call, reason: MessageCategory) {
                let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                      category: reason,
                                                      status: .SENDING,
                                                      quoteMessageId: call.uuidString)
                SendMessageService.shared.sendWebRTCMessage(message: msg, recipientId: call.opponentUser.userId)
                self.insertCallCompletedMessage(call: call,
                                                isUserInitiated: true,
                                                category: reason)
            }
            
            if let call = self.call, call.uuid == uuid {
                self.invalidateUnansweredTimeoutTimerAndSetNil()
                DispatchQueue.main.sync {
                    self.view.style = .disconnecting
                }
                self.ringtonePlayer?.stop()
                self.rtcClient.close()
                let category: MessageCategory
                if call.connectedDate != nil {
                    category = .WEBRTC_AUDIO_END
                } else if call.isOutgoing {
                    category = .WEBRTC_AUDIO_CANCEL
                } else {
                    category = .WEBRTC_AUDIO_DECLINE
                }
                sendEndMessage(call: call, reason: category)
                self.call = nil
                self.rtcClient.isMuted = false
                DispatchQueue.main.sync {
                    self.view.dismiss()
                }
            } else if let call = self.pendingOffers[uuid]?.call {
                sendEndMessage(call: call, reason: .WEBRTC_AUDIO_DECLINE)
                self.pendingOffers.removeValue(forKey: uuid)
                if self.pendingOffers.isEmpty {
                    self.ringtonePlayer?.stop()
                    if self.call == nil {
                        DispatchQueue.main.sync {
                            self.view.dismiss()
                        }
                    }
                }
            } else {
                DispatchQueue.main.sync {
                    self.view.style = .disconnecting
                    self.view.dismiss()
                }
                self.rtcClient.isMuted = false
            }
        }
    }
    
    func setMute(uuid: UUID, muted: Bool) {
        guard uuid == call?.uuid else {
            return
        }
        rtcClient.isMuted = muted
    }
    
    func clean() {
        rtcClient.close()
        rtcClient.isMuted = false
        call = nil
        pendingOffers.removeAll()
        ringtonePlayer?.stop()
        invalidateUnansweredTimeoutTimerAndSetNil()
        performSynchronouslyOnMainThread {
            view.dismiss()
        }
    }
    
}

// MARK: - Blaze message data handlers
extension CallManager {
    
    private func handleOffer(data: BlazeMessageData) {
        
        func declineOffer(data: BlazeMessageData, reason category: MessageCategory) {
            let offer = Message.createWebRTCMessage(data: data, category: category, status: .DELIVERED)
            MessageDAO.shared.insertMessage(message: offer, messageSource: "")
            let reply = Message.createWebRTCMessage(quote: data, category: category, status: .SENDING)
            SendMessageService.shared.sendWebRTCMessage(message: reply, recipientId: data.getSenderId())
            if let uuid = UUID(uuidString: data.messageId) {
                pendingOffers.removeValue(forKey: uuid)
            }
        }
        
        do {
            guard let uuid = UUID(uuidString: data.messageId) else {
                throw CallError.invalidUUID(uuid: data.messageId)
            }
            guard let sdpString = data.data.base64Decoded(), let sdp = RTCSessionDescription(jsonString: sdpString) else {
                throw CallError.invalidSdp(sdp: data.data)
            }
            guard let user = UserDAO.shared.getUser(userId: data.userId) else {
                // TODO: What if user isn't in our db?
                throw CallError.missingUser(userId: data.userId)
            }
            
            AudioManager.shared.stop(deactivateAudioSession: false)
            let call = Call(uuid: uuid, opponentUser: user, isOutgoing: false)
            self.pendingOffers[uuid] = (call, sdp)
            
            var reportingError: Error?
            let semaphore = DispatchSemaphore(value: 0)
            self.interfaceAdapter.reportNewIncomingCall(uuid: uuid, handle: .userId(user.userId), localizedCallerName: user.fullName) { (error) in
                reportingError = error
                semaphore.signal()
            }
            semaphore.wait()
            
            if let error = reportingError {
                throw error
            }
        } catch CallError.busy {
            declineOffer(data: data, reason: .WEBRTC_AUDIO_BUSY)
        } catch CallError.microphonePermissionDenied {
            declineOffer(data: data, reason: .WEBRTC_AUDIO_DECLINE)
            self.alert(error: .microphonePermissionDenied)
        } catch {
            declineOffer(data: data, reason: .WEBRTC_AUDIO_FAILED)
        }
    }
    
    private func handleIceCandidate(data: BlazeMessageData) {
        guard let call = call, data.quoteMessageId == call.uuidString else {
            return
        }
        guard let candidatesString = data.data.base64Decoded() else {
            return
        }
        let candidates = [RTCIceCandidate](jsonString: candidatesString)
        candidates.forEach(rtcClient.add)
    }
    
    private func handleCallStatusChange(data: BlazeMessageData) {
        guard let uuid = UUID(uuidString: data.quoteMessageId) else {
            return
        }
        if let call = call, uuid == call.uuid, call.isOutgoing, data.category == MessageCategory.WEBRTC_AUDIO_ANSWER.rawValue, let sdpString = data.data.base64Decoded(), let sdp = RTCSessionDescription(jsonString: sdpString) {
            invalidateUnansweredTimeoutTimerAndSetNil()
            interfaceAdapter.reportOutgoingCallStartedConnecting(uuid: call.uuid)
            ringtonePlayer?.stop()
            DispatchQueue.main.sync {
                view.style = .connecting
            }
            rtcClient.set(remoteSdp: sdp) { (error) in
                if let error = error {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: true,
                                             reportAction: "Set remote answer",
                                             description: error.localizedDescription)
                        self.interfaceAdapter.reportCall(uuid: call.uuid, EndedByReason: .failed)
                    }
                }
            }
        } else if let category = MessageCategory(rawValue: data.category), CallManager.callEndedCategories.contains(category) {
            
            func insertMessageAndReport(call: Call) {
                insertCallCompletedMessage(call: call, isUserInitiated: false, category: category)
                interfaceAdapter.reportCall(uuid: call.uuid, EndedByReason: .remoteEnded)
            }
            
            if let call = call {
                DispatchQueue.main.sync {
                    view.style = .disconnecting
                }
                insertMessageAndReport(call: call)
                clean()
            } else if let call = pendingOffers[uuid]?.call {
                ringtonePlayer?.stop()
                insertMessageAndReport(call: call)
                pendingOffers.removeValue(forKey: uuid)
            }
        }
    }
    
    private func insertCallCompletedMessage(call: Call, isUserInitiated: Bool, category: MessageCategory?) {
        let timeIntervalSinceNow = call.connectedDate?.timeIntervalSinceNow ?? 0
        let duration = abs(timeIntervalSinceNow * millisecondsPerSecond)
        let category = category ?? .WEBRTC_AUDIO_FAILED
        let shouldMarkMessageRead = call.isOutgoing
            || category == .WEBRTC_AUDIO_END
            || (category == .WEBRTC_AUDIO_DECLINE && isUserInitiated)
        let status: MessageStatus = shouldMarkMessageRead ? .READ : .DELIVERED
        let msg = Message.createWebRTCMessage(messageId: call.uuidString,
                                              conversationId: call.conversationId,
                                              userId: call.raisedByUserId,
                                              category: category,
                                              mediaDuration: Int64(duration),
                                              status: status)
        MessageDAO.shared.insertMessage(message: msg, messageSource: "")
    }
    
}

// MARK: - WebRTCClientDelegate
extension CallManager: WebRTCClientDelegate {
    
    func webRTCClient(_ client: WebRTCClient, didGenerateLocalCandidate candidate: RTCIceCandidate) {
        guard call != nil else {
            return
        }
        sendCandidates([candidate])
    }
    
    func webRTCClientDidConnected(_ client: WebRTCClient) {
        queue.async {
            guard let call = self.call else {
                return
            }
            call.connectedDate = Date()
            if call.isOutgoing {
                self.interfaceAdapter.reportOutgoingCallConnected(uuid: call.uuid)
            } else {
                self.interfaceAdapter.reportIncomingCallConnected(uuid: call.uuid)
            }
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            DispatchQueue.main.sync {
                self.view.style = .connected
            }
        }
    }
    
    func webRTCClientDidFailed(_ client: WebRTCClient) {
        queue.async {
            self.failCurrentCall(sendFailedMessageToRemote: true,
                                 reportAction: "RTC Client fail",
                                 description: "")
        }
    }
    
}

// MARK: - Private works
extension CallManager {
    
    @objc private func unansweredTimeout() {
        guard let call = call else {
            return
        }
        view.dismiss()
        rtcClient.close()
        rtcClient.isMuted = false
        queue.async {
            self.ringtonePlayer?.stop()
            let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                  category: .WEBRTC_AUDIO_CANCEL,
                                                  status: .SENDING,
                                                  quoteMessageId: call.uuidString)
            SendMessageService.shared.sendWebRTCMessage(message: msg, recipientId: call.opponentUser.userId)
            self.insertCallCompletedMessage(call: call, isUserInitiated: false, category: .WEBRTC_AUDIO_CANCEL)
            self.call = nil
            self.interfaceAdapter.reportCall(uuid: call.uuid, EndedByReason: .unanswered)
        }
    }
    
    @objc private func audioSessionRouteChange(_ notification: Notification) {
        let old = (notification.userInfo![AVAudioSessionRouteChangePreviousRouteKey] as! AVAudioSessionRouteDescription).outputs
        let new = AVAudioSession.sharedInstance().currentRoute.outputs
        let reasonValue = notification.userInfo![AVAudioSessionRouteChangeReasonKey] as! UInt
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)!
        let reasonString: String
        switch reason {
        case .unknown:
            reasonString = "unknown"
        case .newDeviceAvailable:
            reasonString = "newDeviceAvailable"
        case .oldDeviceUnavailable:
            reasonString = "oldDeviceUnavailable"
        case .categoryChange:
            reasonString = "categoryChange"
        case .override:
            reasonString = "override"
        case .wakeFromSleep:
            reasonString = "wakeFromSleep"
        case .noSuitableRouteForCategory:
            reasonString = "noSuitableRouteForCategory"
        case .routeConfigurationChange:
            reasonString = "routeConfigurationChange"
        }
        print("reason: \(reasonString)")
        print("old: \(old)")
        print("new: \(new)\n")
    }
    
    private func failCurrentCall(sendFailedMessageToRemote: Bool, reportAction action: String, description: String) {
        guard let call = call else {
            return
        }
        if sendFailedMessageToRemote {
            let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                  category: .WEBRTC_AUDIO_FAILED,
                                                  status: .SENDING,
                                                  quoteMessageId: call.uuidString)
            SendMessageService.shared.sendMessage(message: msg,
                                                  ownerUser: call.opponentUser,
                                                  isGroupMessage: false)
        }
        let failedMessage = Message.createWebRTCMessage(messageId: call.uuidString,
                                                        conversationId: call.conversationId,
                                                        category: .WEBRTC_AUDIO_FAILED,
                                                        status: .DELIVERED)
        MessageDAO.shared.insertMessage(message: failedMessage, messageSource: "")
        clean()
        UIApplication.trackError("CallManager", action: action, userInfo: ["error": description])
    }
    
    private func sendCandidates(_ candidates: [RTCIceCandidate]) {
        guard let call = call, let content = candidates.jsonString else {
            return
        }
        let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                              category: .WEBRTC_ICE_CANDIDATE,
                                              content: content,
                                              status: .SENDING,
                                              quoteMessageId: call.uuidString)
        SendMessageService.shared.sendMessage(message: msg,
                                              ownerUser: call.opponentUser,
                                              isGroupMessage: false)
    }
    
    private func invalidateUnansweredTimeoutTimerAndSetNil() {
        unansweredTimer?.invalidate()
        unansweredTimer = nil
    }
    
}
