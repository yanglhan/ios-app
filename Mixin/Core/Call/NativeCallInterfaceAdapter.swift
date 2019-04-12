import UIKit
import AVFoundation
import UserNotifications
import CallKit

class NativeCallInterfaceAdapter {
    
    private let callObserver = CXCallObserver()
    
    private unowned var manager: CallManager
    private var pendingIncomingUuid: UUID?
    
    private var lineIsIdle: Bool {
        return manager.call == nil && callObserver.calls.isEmpty
    }
    
    required init(manager: CallManager) {
        self.manager = manager
    }
    
    private func requestRecordPermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
                completion(granted)
            }
        case .denied:
            completion(false)
        case .granted:
            completion(true)
        }
    }
    
}

extension NativeCallInterfaceAdapter: CallInterfaceAdapter {
    
    func requestStartCall(uuid: UUID, handle: Call.Handle, completion: @escaping CallInterfaceCompletion) {
        guard WebSocketService.shared.connected else {
            completion(CallError.networkFailure)
            return
        }
        guard lineIsIdle else {
            completion(CallError.busy)
            return
        }
        requestRecordPermission { (granted) in
            if granted {
                completion(nil)
                self.manager.startCall(uuid: uuid, handle: handle, completion: { (success) in
                    if success {
                        self.manager.ringtonePlayer?.play()
                    }
                })
            } else {
                completion(CallError.microphonePermissionDenied)
            }
        }
    }
    
    func requestEndCall(uuid: UUID, completion: @escaping CallInterfaceCompletion) {
        if uuid == pendingIncomingUuid {
            pendingIncomingUuid = nil
        }
        UNUserNotificationCenter.current().removeNotifications(identifier: NotificationRequestIdentifier.call)
        manager.endCall(uuid: uuid)
        completion(nil)
    }
    
    func requestSetMute(uuid: UUID, muted: Bool, completion: @escaping CallInterfaceCompletion) {
        manager.setMute(uuid: uuid, muted: muted)
        completion(nil)
    }
    
    func reportNewIncomingCall(uuid: UUID, handle: Call.Handle, localizedCallerName: String, completion: @escaping CallInterfaceCompletion) {
        requestRecordPermission { (granted) in
            guard granted else {
                completion(CallError.microphonePermissionDenied)
                return
            }
            if self.pendingIncomingUuid == nil, let call = self.manager.pendingOffers[uuid]?.call {
                let user = call.opponentUser
                DispatchQueue.main.sync {
                    if UIApplication.shared.applicationState == .active {
                        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                        try? AVAudioSession.sharedInstance().setCategory(.playback)
                        self.manager.ringtonePlayer?.play()
                    } else {
                        UNUserNotificationCenter.current().sendCallNotification(callerName: user.fullName)
                    }
                    let view = self.manager.view
                    view.reload(user: user)
                    view.style = .incoming
                    view.show()
                }
                self.pendingIncomingUuid = uuid
                completion(nil)
            } else {
                completion(CallError.busy)
            }
        }
    }
    
    func reportCall(uuid: UUID, EndedByReason reason: Call.EndedReason) {
        if uuid == pendingIncomingUuid {
            pendingIncomingUuid = nil
        }
        UNUserNotificationCenter.current().removeNotifications(identifier: NotificationRequestIdentifier.call)
        DispatchQueue.main.sync {
            manager.view.style = .disconnecting
            manager.view.dismiss()
        }
    }
    
    func reportOutgoingCallStartedConnecting(uuid: UUID) {
        if uuid == pendingIncomingUuid {
            pendingIncomingUuid = nil
        }
    }
    
    func reportOutgoingCallConnected(uuid: UUID) {
        
    }
    
    func reportIncomingCallConnected(uuid: UUID) {
    
    }
    
}
