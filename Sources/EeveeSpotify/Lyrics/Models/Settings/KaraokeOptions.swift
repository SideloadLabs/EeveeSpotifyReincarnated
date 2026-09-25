import Foundation

enum KaraokeTextAlignment: String, Codable, CaseIterable {
    case leading
    case center
    case trailing

    var displayName: String {
        switch self {
        case .leading: return "Left"
        case .center: return "Center"
        case .trailing: return "Right"
        }
    }
}

struct KaraokeOptions: Codable, Hashable {
    var textAlignment: KaraokeTextAlignment
    var reversedDirection: Bool
    var enabled: Bool
    var blurIntensity: Double

    init(
        textAlignment: KaraokeTextAlignment,
        reversedDirection: Bool,
        enabled: Bool = true,
        blurIntensity: Double = 1.5
    ) {
        self.textAlignment = textAlignment
        self.reversedDirection = reversedDirection
        self.enabled = enabled
        self.blurIntensity = blurIntensity
    }

    private enum CodingKeys: String, CodingKey {
        case textAlignment, reversedDirection, enabled, blurIntensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textAlignment = try container.decode(KaraokeTextAlignment.self, forKey: .textAlignment)
        reversedDirection = try container.decode(Bool.self, forKey: .reversedDirection)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        blurIntensity = try container.decodeIfPresent(Double.self, forKey: .blurIntensity) ?? 1.5
    }
}
