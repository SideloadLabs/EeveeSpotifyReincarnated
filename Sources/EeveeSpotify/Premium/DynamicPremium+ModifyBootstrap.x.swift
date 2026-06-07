import Orion

private func showHavePremiumPopUp() {
    PopUpHelper.showPopUp(
        delayed: true,
        message: "have_premium_popup".localized,
        buttonText: "OK".uiKitLocalized
    )
}

class SpotifySessionDelegateBootstrapHook: ClassHook<NSObject>, SpotifySessionDelegate {
    // This hook is the *core* of premium patching (intercepts bootstrap and mutates UCS).
    typealias Group = PremiumBootstrapGroup
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "SPTCoreURLSessionDataDelegate"
        default: return "SPTDataLoaderService"
        }
    }
    
    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
    }
    
    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard 
            let request = task.currentRequest,
            let url = request.url
        else {
            return
        }
        
        if url.isBootstrap {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }

        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
    
    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        guard
            let request = task.currentRequest,
            let url = request.url
        else {
            return
        }
        
        if error == nil && url.isBootstrap {
            guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
                orig.URLSession(session, task: task, didCompleteWithError: error)
                return
            }
            
            do {
                var bootstrapMessage = try BootstrapMessage(serializedBytes: buffer)
                
                if UserDefaults.patchType == .notSet {
                    if bootstrapMessage.attributes["type"]?.stringValue == "premium" {
                        UserDefaults.patchType = .disabled
                        showHavePremiumPopUp()
                    }
                    else {
                        UserDefaults.patchType = .requests
                        // Dispatch to main thread — calling activate() (method swizzling) from
                        // a URLSession delegate background thread while inside the method being
                        // swizzled is not thread-safe and causes a first-launch crash.
                        DispatchQueue.main.async { activatePremiumPatchingGroup() }
                    }
                    
                }
                
                if UserDefaults.patchType == .requests {
                    writeDebugLog("[BOOTSTRAP] Patching bootstrap UCS response")
                    UserDefaults.hasPatchedBootstrap = true
                    modifyRemoteConfiguration(&bootstrapMessage.ucsResponse)
                    
                    orig.URLSession(
                        session,
                        dataTask: task,
                        didReceiveData: try bootstrapMessage.serializedBytes()
                    )
                }
                else {
                    writeDebugLog("[BOOTSTRAP] Passing through unmodified bootstrap (patchType=\(UserDefaults.patchType))")
                    orig.URLSession(session, dataTask: task, didReceiveData: buffer)
                }
                
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            catch {
            }
        }
        
        orig.URLSession(session, task: task, didCompleteWithError: error)
    }
}
