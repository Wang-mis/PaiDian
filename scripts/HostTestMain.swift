import Foundation

@main struct HostTestMain {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do {
            if let index = CommandLine.arguments.firstIndex(of:"--live-source"), CommandLine.arguments.indices.contains(index + 1) { try await LiveValidation.run(path:CommandLine.arguments[index + 1]) }
            else if CommandLine.arguments.contains("--live-artwork") { try await ArtworkValidation.live() }
            else { try await CoreValidation.run(); try await PlaybackValidation.run() }
        }
        catch { print("FAIL \(error.localizedDescription)"); exit(1) }
    }
}
