import Foundation

// Seed the production Eevee header cache with a request object only. No request is sent.
@_cdecl("SAPSeedEeveeTestHeaders")
public func seedEeveeTestHeaders() {
    var request = URLRequest(url: URL(string: "https://spclient.wg.spotify.com/test-only")!)
    request.setValue("Bearer TEST_ONLY_NOT_REAL", forHTTPHeaderField: "Authorization")
    request.setValue("do not forward", forHTTPHeaderField: "X-Private-Noise")
    SpriteAuthentication.capture(request, session: nil)
}
