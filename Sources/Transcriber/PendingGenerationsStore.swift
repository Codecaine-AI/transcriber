import Foundation

/// One sealed take whose delivery this Mac still owes the user. Frame counts
/// exist only so a finish that failed (for example a full server disk) can be
/// retried; no transcript text, token, or destination is ever stored here.
struct PendingGenerationEntry: Codable, Equatable {
    var id: UUID
    var endpoint: String
    var inferenceFrames: Int64
    var originalFrames: Int64?
    var sealedAt: Date
}

/// Persists pending generation IDs so a result that completes while the app is
/// closed can be offered for copy on relaunch. Absent or unreadable file means
/// no pending takes.
/// Fork: the file lives in its own folder, because ConfigurationWatcher watches
/// the client data directory itself.
struct PendingGenerationsStore {
    let url: URL

    init(root: URL) {
        let folder = root.appendingPathComponent("Pending Generations", isDirectory: true)
        url = folder.appendingPathComponent("pending-generations.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func load() -> [PendingGenerationEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingGenerationEntry].self, from: data)) ?? []
    }

    @discardableResult
    func save(_ entries: [PendingGenerationEntry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
