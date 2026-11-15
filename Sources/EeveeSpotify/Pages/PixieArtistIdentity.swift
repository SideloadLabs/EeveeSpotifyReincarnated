import Foundation

// Spotify 9.1.90 stores page identity in template.creativeWork.uri. Read only those
// named fields; unrelated track/album URIs and changed model shapes are rejected.
@objc(EeveePixieArtistIdentity)
final class PixieArtistIdentity: NSObject {
    @objc static func artistURI(_ controller: AnyObject) -> String? {
        var value: Any = controller
        for name in ["template", "creativeWork", "uri"] {
            var mirror: Mirror? = Mirror(reflecting: value)
            var field: Any?
            while let current = mirror {
                if let child = current.children.first(where: { $0.label == name }) {
                    field = child.value
                    break
                }
                mirror = current.superclassMirror
            }
            guard let field else { return nil }
            value = field
        }
        let string: String?
        if let url = value as? URL { string = url.absoluteString }
        else { string = value as? String }
        guard let uri = string, uri.hasPrefix("spotify:artist:") else { return nil }
        let identifier = uri.dropFirst("spotify:artist:".count)
        guard identifier.utf8.count == 22,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return uri
    }
}
