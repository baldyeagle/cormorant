import Foundation

/// A fixed reference instant (whole seconds, so it survives ISO 8601 round trips exactly).
let t0 = Date(timeIntervalSince1970: 1_790_000_000)
let hour: TimeInterval = 60 * 60

func url(_ string: String) -> URL { URL(string: string)! }

/// A fresh directory under the system temp dir. Callers remove it when done.
func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "CormorantCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
