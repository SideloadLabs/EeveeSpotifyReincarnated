import Foundation

enum SponsorBlockAction: String, Codable, CaseIterable, Equatable {
    case disabled
    case showOnly
    case manualSkip
    case autoSkip
}

struct SponsorBlockOptions: Codable, Equatable {
    var enabled: Bool
    var logOnly: Bool
    var showOverlay: Bool
    var showToast: Bool
    var respectManualSeek: Bool
    var serverURL: String
    var minSegmentDuration: Double
    var categories: [String: SponsorBlockAction]
    var colors: [String: String]
    var verboseLogging: Bool
    var showSkipFeedbackButtons: Bool
    var toastDuration: Double
    var autoSkipMySubmissions: Bool

    static let defaultCategories: [String: SponsorBlockAction] = [
        "sponsor":          .autoSkip,
        "selfpromo":        .autoSkip,
        "interaction":      .autoSkip,
        "intro":            .disabled,
        "outro":            .disabled,
        "preview":          .disabled,
        "hook":             .disabled,
        "filler":           .disabled,
        "exclusive_access": .disabled,
    ]

    static let defaultColors: [String: String] = [
        "sponsor":          "#00d400",
        "selfpromo":        "#ffff00",
        "interaction":      "#cc00ff",
        "intro":            "#00ffff",
        "outro":            "#0202ed",
        "preview":          "#008fd6",
        "hook":             "#009088",
        "filler":           "#7300ff",
        "exclusive_access": "#008a5c",
    ]

    static let allCategoryOrder: [String] = [
        "sponsor", "selfpromo", "interaction",
        "intro", "outro", "preview", "hook", "filler",
        "exclusive_access",
    ]

    func action(for category: String) -> SponsorBlockAction {
        categories[category] ?? .disabled
    }

    func enabledCategoriesArray() -> [String] {
        SponsorBlockOptions.allCategoryOrder.filter { action(for: $0) != .disabled }
    }

    func color(for category: String) -> String {
        colors[category] ?? SponsorBlockOptions.defaultColors[category] ?? "#888888"
    }

    init(enabled: Bool,
         logOnly: Bool,
         showOverlay: Bool,
         showToast: Bool,
         respectManualSeek: Bool,
         serverURL: String,
         minSegmentDuration: Double,
         categories: [String: SponsorBlockAction],
         colors: [String: String],
         verboseLogging: Bool = false,
         showSkipFeedbackButtons: Bool = true,
         toastDuration: Double = 2.2,
         autoSkipMySubmissions: Bool = true) {
        self.enabled = enabled
        self.logOnly = logOnly
        self.showOverlay = showOverlay
        self.showToast = showToast
        self.respectManualSeek = respectManualSeek
        self.serverURL = serverURL
        self.minSegmentDuration = minSegmentDuration
        self.categories = categories
        self.colors = colors
        self.verboseLogging = verboseLogging
        self.showSkipFeedbackButtons = showSkipFeedbackButtons
        self.toastDuration = toastDuration
        self.autoSkipMySubmissions = autoSkipMySubmissions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled            = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        logOnly            = (try? c.decode(Bool.self, forKey: .logOnly)) ?? false
        showOverlay        = (try? c.decode(Bool.self, forKey: .showOverlay)) ?? true
        showToast          = (try? c.decode(Bool.self, forKey: .showToast)) ?? false
        respectManualSeek  = (try? c.decode(Bool.self, forKey: .respectManualSeek)) ?? false
        serverURL          = (try? c.decode(String.self, forKey: .serverURL)) ?? "https://sponsor.ajay.app"
        minSegmentDuration = (try? c.decode(Double.self, forKey: .minSegmentDuration)) ?? 1.0
        colors             = (try? c.decode([String: String].self, forKey: .colors)) ?? SponsorBlockOptions.defaultColors
        verboseLogging     = (try? c.decode(Bool.self, forKey: .verboseLogging)) ?? false
        showSkipFeedbackButtons = (try? c.decode(Bool.self, forKey: .showSkipFeedbackButtons)) ?? true
        toastDuration  = (try? c.decode(Double.self, forKey: .toastDuration)) ?? 2.2
        autoSkipMySubmissions = (try? c.decode(Bool.self, forKey: .autoSkipMySubmissions)) ?? true

        if let actionMap = try? c.decode([String: SponsorBlockAction].self, forKey: .categories) {
            categories = actionMap
        } else if let boolMap = try? c.decode([String: Bool].self, forKey: .categories) {
            categories = boolMap.mapValues { $0 ? .autoSkip : .disabled }
        } else {
            categories = SponsorBlockOptions.defaultCategories
        }
    }
}
