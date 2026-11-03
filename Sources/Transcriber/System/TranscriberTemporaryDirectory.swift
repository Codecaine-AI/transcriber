import Foundation
import TranscriberCore

enum TranscriberTemporaryDirectory {
    static let url: URL = {
        guard TranscriberBuild.current.isDevelopment,
              let root = ProcessInfo.processInfo.environment["TRANSCRIBER_CLIENT_DATA_DIR"], !root.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory
    }()
}
