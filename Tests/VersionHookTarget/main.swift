private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

let cases: [(String, VersionHookTarget)] = [
    ("8.9.8", .lastAvailableiOS14),
    ("9.0.48", .lastAvailableiOS15),
    ("9.0.10", .latest),
    ("9.1.0", .v91),
    ("9.1.90", .v91),
    ("9.2.0", .v91),
    ("9.10.4", .v91),
    ("10.0.0", .v91),
    ("?", .latest),
]

for (version, expected) in cases {
    require(
        VersionHookTarget.forSpotifyVersion(version) == expected,
        "Spotify \(version) must map to \(expected)"
    )
}

print("VersionHookTarget tests passed")
