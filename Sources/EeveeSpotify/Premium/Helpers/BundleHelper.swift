import Foundation
import SwiftUI
import EeveeSpotifyC

class BundleHelper {
    private let bundleName = "EeveeSpotify"
    
    // Make properties optional to prevent init crash
    private var bundle: Bundle?
    private var enBundle: Bundle?
    
    static let shared = BundleHelper()
    
    private init() {
        // Try locating in main bundle first
        if let path = Bundle.main.path(forResource: bundleName, ofType: "bundle"),
           let b = Bundle(path: path) {
            self.bundle = b
            NSLog("[EeveeSpotify] Loaded bundle from main bundle: \(path)")
        } 
        // If not found, try locating in file system (jailbreak path)
        else {
            let jbPath = EeveeJBRootPath("/Library/Application Support/\(bundleName).bundle")
            if let b = Bundle(path: jbPath) {
                self.bundle = b
                NSLog("[EeveeSpotify] Loaded bundle from filesystem: \(jbPath)")
            } else {
                NSLog("[EeveeSpotify] ERROR: Could not find EeveeSpotify.bundle!")
                self.bundle = nil
            }
        }
        
        // Load English localization if available
        if let b = self.bundle, let enPath = b.path(forResource: "en", ofType: "lproj"),
           let enB = Bundle(path: enPath) {
            self.enBundle = enB
        } else {
            NSLog("[EeveeSpotify] WARNING: Could not load en.lproj from bundle")
            self.enBundle = nil
        }
    }
    
    func uiImage(_ name: String) -> UIImage? {
        guard let bundle = self.bundle else { return nil }
        
        if let path = bundle.path(forResource: name, ofType: "png") {
            return UIImage(contentsOfFile: path)
        }
        return nil
    }
    
    func localizedString(_ key: String) -> String {
        guard let bundle = self.bundle else { return key }

        let value = bundle.localizedString(forKey: key, value: "No translation", table: nil)
        
        if value != "No translation" {
            return value
        }
        
        return enBundle?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }
    
    func resolveConfiguration() throws -> ResolveConfiguration {
        guard let bundle = self.bundle,
              let url = bundle.url(forResource: "resolveconfiguration", withExtension: "bnk") else {
            throw NSError(domain: "EeveeSpotify", code: 404, userInfo: [NSLocalizedDescriptionKey: "Configuration not found"])
        }
        
        return try ResolveConfiguration(
            serializedBytes: try Data(contentsOf: url)
        )
    }
}
