import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fixture = root.appendingPathComponent("Tests/PixieStartupLogging")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pixie-startup-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func run(_ command: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "Startup logging check failed: \(command)")
}

let binary = temporary.appendingPathComponent("probe").path
run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "Foundation",
    "-I", fixture.appendingPathComponent("include").path,
    "-I", root.appendingPathComponent("Sources/EeveeSpotifyC/include").path,
    "-Ddlsym=SAPTestDlsym", "-D_dyld_image_count=SAPTestImageCount", "-D_dyld_get_image_name=SAPTestImageName",
    root.appendingPathComponent("Sources/EeveeSpotifyC/PixieArtistDownloads.m").path,
    fixture.appendingPathComponent("probe.m").path, "-o", binary])
run(binary, [temporary.path])
