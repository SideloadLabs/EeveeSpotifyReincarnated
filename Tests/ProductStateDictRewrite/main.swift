private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

let cases: [(String, Bool)] = [
    ("8.9.8", false),
    ("9.0.48", false),
    ("9.0.10", false),
    ("9.1.0", false),
    ("9.1.88", false),
    ("9.2.0", true),
    ("9.2", true),
    ("9.10.4", true),
    ("10.0.0", true),
    ("?", true),
    ("", true),
]

for (version, expected) in cases {
    require(
        VersionHookTarget.requiresProductStateDictRewrite(version) == expected,
        "Spotify \(version) product-state dict rewrite must be \(expected)"
    )
}

print("ProductStateDictRewrite tests passed")
