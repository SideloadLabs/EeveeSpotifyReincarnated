import Foundation

extension UserDefaults {
    @UserDefault(
        key: "sponsorBlockOptions",
        defaultValue: SponsorBlockOptions(
            enabled: false,
            logOnly: false,
            showOverlay: true,
            showToast: false,
            respectManualSeek: false,
            serverURL: "https://sponsor.ajay.app",
            minSegmentDuration: 1.0,
            categories: SponsorBlockOptions.defaultCategories,
            colors: SponsorBlockOptions.defaultColors,
            verboseLogging: false,
            showSkipFeedbackButtons: true,
            toastDuration: 2.2,
            autoSkipMySubmissions: true
        )
    )
    static var sponsorBlockOptions
}
