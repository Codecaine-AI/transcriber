import Foundation

/// Bundle metadata is the single source of truth for app and storage identity.
public enum TranscriberBuild: Equatable, Sendable {
    case release, development

    // Unbundled Swift runs stay isolated from the installed app's preferences.
    public static let current: Self = Bundle.main.object(forInfoDictionaryKey: "TranscriberDevelopmentBuild") as? Bool == false
        ? .release : .development

    // A packaged app reports the name and identifier in its own Info.plist, so a
    // rebranded bundle keeps its own settings directory and Keychain service.
    public var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? (self == .development ? "Transcriber Dev" : "Transcriber")
    }
    public var isDevelopment: Bool { self == .development }
    public var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? (self == .development ? "ai.codecaine.transcriber.dev" : "ai.codecaine.transcriber")
    }
    public var credentialService: String { bundleIdentifier + ".server" }
    public var windowAutosaveName: String { self == .development ? "TranscriberDevMainWindow" : "TranscriberMainWindow" }
    public var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(displayName, isDirectory: true)
    }
}
