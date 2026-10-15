import Foundation

/// Stable Core Audio identity and display metadata, never a transient hardware ID.
public struct AudioInputDevice: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let uid: String
    public let name: String
    public let transport: AudioInputTransport
    public var id: String { uid }

    public init(uid: String, name: String, transport: AudioInputTransport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey { case uid, name, transport }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let uid = try values.decode(String.self, forKey: .uid)
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .uid, in: values, debugDescription: "An input device needs a stable UID.")
        }
        self.init(uid: uid, name: (try? values.decode(String.self, forKey: .name)) ?? "Microphone",
                  transport: (try? values.decode(AudioInputTransport.self, forKey: .transport)) ?? .other)
    }
}

public enum AudioInputTransport: String, Codable, CaseIterable, Sendable {
    case builtIn, usb, bluetooth, virtual, aggregate, other

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .other
    }
}

public struct MicrophoneProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var priority: [AudioInputDevice]

    public static let defaultProfile = MicrophoneProfile(id: "default", name: "Default")

    public init(id: String = UUID().uuidString, name: String, priority: [AudioInputDevice] = []) {
        self.id = id
        self.name = name
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey { case id, name, priority }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? values.decode(String.self, forKey: .id)) ?? "",
                  name: (try? values.decode(String.self, forKey: .name)) ?? "",
                  priority: (try? values.decode(LossyArray<AudioInputDevice>.self, forKey: .priority))?.values ?? [])
    }
}

public enum MicrophoneSelection: Equatable, Hashable, Codable, Sendable {
    case automatic
    case systemDefault
    case fixed(AudioInputDevice)

    private enum CodingKeys: String, CodingKey { case mode, device }

    public init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self),
              let mode = try? values.decode(String.self, forKey: .mode) else {
            self = .automatic
            return
        }
        switch mode {
        case "systemDefault": self = .systemDefault
        case "fixed":
            if let device = try? values.decode(AudioInputDevice.self, forKey: .device) {
                self = .fixed(device)
            } else {
                self = .automatic
            }
        default: self = .automatic
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try values.encode("automatic", forKey: .mode)
        case .systemDefault: try values.encode("systemDefault", forKey: .mode)
        case .fixed(let device):
            try values.encode("fixed", forKey: .mode)
            try values.encode(device, forKey: .device)
        }
    }
}

/// Fork: which captured channels feed transcription for one input device. The
/// original recording always keeps every channel; this shapes only inference audio.
public enum InferenceChannelSelection: Equatable, Hashable, Codable, Sendable {
    /// Transcriber's own mix of every channel.
    case allChannels
    /// Zero-based capture channels, averaged equally when more than one.
    case channels([Int])

    /// Generous sanity bound for saved indices; each take validates against the device.
    public static let channelIndexLimit = 256

    /// Sorted unique in-range indices, or nil when nothing usable remains.
    public var normalized: Self? {
        guard case .channels(let indices) = self else { return self }
        let valid = Set(indices.filter { (0..<Self.channelIndexLimit).contains($0) }).sorted()
        return valid.isEmpty ? nil : .channels(valid)
    }

    private enum CodingKeys: String, CodingKey { case mode, channelIndices }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .mode) {
        case "all": self = .allChannels
        case "channels":
            guard let selection = Self.channels(try values.decode([Int].self, forKey: .channelIndices)).normalized else {
                throw DecodingError.dataCorruptedError(forKey: .channelIndices, in: values,
                                                       debugDescription: "Provide at least one channel index.")
            }
            self = selection
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: values, debugDescription: "Use all or channels.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allChannels: try values.encode("all", forKey: .mode)
        case .channels(let indices):
            try values.encode("channels", forKey: .mode)
            try values.encode(indices, forKey: .channelIndices)
        }
    }
}

/// Fork: the inference-channel inputs frozen when a take starts.
public struct InferenceChannelRequest: Equatable, Sendable {
    public let device: AudioInputDevice
    public let selection: InferenceChannelSelection?

    public init(device: AudioInputDevice, selection: InferenceChannelSelection?) {
        self.device = device
        self.selection = selection
    }

    /// Zero-based channels to mix into inference audio, or nil for Transcriber's own mix
    /// (Apple's converter for one or two channels, an equal average above that).
    /// A saved choice wins while the device still has those channels. Otherwise a
    /// known interface uses its documented microphone channel, and any other
    /// device keeps Transcriber's mix rather than guessing a channel.
    public func channels(channelCount: Int) -> [Int]? {
        guard channelCount > 0 else { return nil }
        switch selection?.normalized {
        case .allChannels: return nil
        case .channels(let indices) where indices.allSatisfy({ $0 < channelCount }): return indices
        case .channels, nil: break
        }
        return Self.knownMicrophoneChannels.first { known in
            known.channelCount == channelCount
                && (device.name.localizedCaseInsensitiveContains(known.name)
                    || device.uid.localizedCaseInsensitiveContains(known.name))
        }?.channels
    }

    // Focusrite documents the Solo 4th Gen inputs as 1 instrument/line, 2 XLR
    // microphone, 3-4 loopback. Its HAL UID also carries the model name.
    private static let knownMicrophoneChannels: [(name: String, channelCount: Int, channels: [Int])] = [
        ("Scarlett Solo 4th Gen", 4, [1]),
    ]
}

public struct MicrophonePreferences: Codable, Equatable, Sendable {
    public var profiles: [MicrophoneProfile]
    public var activeProfileID: String
    public var selection: MicrophoneSelection
    /// Fork: inference-channel choice keyed by stable device UID, never by profile,
    /// because fallback can resolve a profile to a different device.
    public var inferenceChannels: [String: InferenceChannelSelection]

    public init(profiles: [MicrophoneProfile] = [.defaultProfile], activeProfileID: String? = nil,
                selection: MicrophoneSelection = .automatic,
                inferenceChannels: [String: InferenceChannelSelection] = [:]) {
        self.inferenceChannels = inferenceChannels.reduce(into: [:]) { result, entry in
            guard !entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let selection = entry.value.normalized else { return }
            result[entry.key] = selection
        }
        var profileIDs = Set<String>()
        let validProfiles = profiles.compactMap { profile -> MicrophoneProfile? in
            guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profileIDs.insert(profile.id).inserted else { return nil }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return MicrophoneProfile(id: profile.id, name: name.isEmpty ? "Default" : name,
                                     priority: Self.uniqueDevices(profile.priority))
        }
        self.profiles = validProfiles.isEmpty ? [.defaultProfile] : validProfiles
        self.activeProfileID = self.profiles.first(where: { $0.id == activeProfileID })?.id ?? self.profiles[0].id
        if case .fixed(let device) = selection {
            self.selection = Self.uniqueDevices([device]).first.map(MicrophoneSelection.fixed) ?? .automatic
        } else {
            self.selection = selection
        }
    }

    public var activeProfile: MicrophoneProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? .defaultProfile
    }

    /// Apply after preference edits; disconnected favorites remain in their original order.
    public func normalized() -> Self {
        Self(profiles: profiles, activeProfileID: activeProfileID, selection: selection,
             inferenceChannels: inferenceChannels)
    }

    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID, selection, inferenceChannels }

    public init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        self.init(profiles: (try? values.decode(LossyArray<MicrophoneProfile>.self, forKey: .profiles))?.values ?? [],
                  activeProfileID: try? values.decode(String.self, forKey: .activeProfileID),
                  selection: (try? values.decode(MicrophoneSelection.self, forKey: .selection)) ?? .automatic,
                  inferenceChannels: (try? values.decode(LossyDictionary<InferenceChannelSelection>.self,
                                                         forKey: .inferenceChannels))?.values ?? [:])
    }

    // Fork: omit an empty channel map so existing config files stay unchanged.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(profiles, forKey: .profiles)
        try values.encode(activeProfileID, forKey: .activeProfileID)
        try values.encode(selection, forKey: .selection)
        if !inferenceChannels.isEmpty { try values.encode(inferenceChannels, forKey: .inferenceChannels) }
    }

    fileprivate static func uniqueDevices(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        var uids = Set<String>()
        return devices.compactMap { device in
            guard !device.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  uids.insert(device.uid).inserted else { return nil }
            let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return AudioInputDevice(uid: device.uid, name: name.isEmpty ? "Microphone" : name,
                                    transport: device.transport)
        }
    }
}

public enum MicrophoneResolutionReason: Equatable, Sendable {
    case priority
    case fixed
    case systemDefault
    /// The chosen device was absent, or the system had no available default input.
    case fallback(requested: AudioInputDevice?)
    case unavailable
}

public struct MicrophoneResolution: Equatable, Sendable {
    public let device: AudioInputDevice?
    public let reason: MicrophoneResolutionReason
}

/// Resolves only the next recording's input. Never edits preferences or the OS default.
public enum MicrophoneSelectionPolicy {
    public static func resolve(preferences: MicrophonePreferences, available: [AudioInputDevice],
                               systemDefaultUID: String?) -> MicrophoneResolution {
        let preferences = preferences.normalized()
        let available = MicrophonePreferences.uniqueDevices(available)
        let systemDefault = available.first(where: { $0.uid == systemDefaultUID })
        // Core Audio enumeration order is not a persistent preference.
        let fallback = systemDefault ?? available.min(by: { $0.uid < $1.uid })
        guard let fallback else { return MicrophoneResolution(device: nil, reason: .unavailable) }

        switch preferences.selection {
        case .automatic:
            for preferred in preferences.activeProfile.priority {
                if let device = available.first(where: { $0.uid == preferred.uid }) {
                    return MicrophoneResolution(device: device, reason: .priority)
                }
            }
            return MicrophoneResolution(device: fallback, reason: systemDefault == nil ? .fallback(requested: nil) : .systemDefault)
        case .systemDefault:
            return MicrophoneResolution(device: fallback, reason: systemDefault == nil ? .fallback(requested: nil) : .systemDefault)
        case .fixed(let requested):
            if let device = available.first(where: { $0.uid == requested.uid }) {
                return MicrophoneResolution(device: device, reason: .fixed)
            }
            return MicrophoneResolution(device: fallback, reason: .fallback(requested: requested))
        }
    }
}

/// Salvage valid saved entries instead of losing every preference to one malformed record.
private struct LossyArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var items = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !items.isAtEnd {
            let item = try items.superDecoder()
            if let value = try? Element(from: item) { decoded.append(value) }
        }
        values = decoded
    }
}

/// Fork: the keyed counterpart of LossyArray, for UID-keyed settings.
private struct LossyDictionary<Value: Decodable>: Decodable {
    let values: [String: Value]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let entries = try decoder.container(keyedBy: Key.self)
        var decoded: [String: Value] = [:]
        for key in entries.allKeys {
            if let value = try? entries.decode(Value.self, forKey: key) { decoded[key.stringValue] = value }
        }
        values = decoded
    }
}
