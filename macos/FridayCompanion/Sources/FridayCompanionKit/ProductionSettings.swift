import Foundation

/// P2-PROD-BOOTSTRAP §B3 — versioned, NON-SECRET production
/// configuration. Never holds a credential value (see `CredentialStore`
/// for that) — only provider/model identifiers, locale, and feature
/// flags, all of which are safe to read/write as plain JSON.
public struct ProductionSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var conversationProvider: String
    public var conversationModel: String
    public var conversationEndpoint: String?
    public var voiceProvider: String
    public var voiceModel: String
    public var voiceID: String
    public var locale: String
    public var launchAtLoginEnabled: Bool
    public var wakeListeningEnabledByDefault: Bool
    public var runtimeMode: RuntimeMode

    public enum RuntimeMode: String, Codable, Sendable {
        case production
        case development
    }

    public init(
        schemaVersion: Int = ProductionSettings.currentSchemaVersion,
        conversationProvider: String = "unspecified",
        conversationModel: String = "unspecified",
        conversationEndpoint: String? = nil,
        voiceProvider: String = "unspecified",
        voiceModel: String = "unspecified",
        voiceID: String = "unspecified",
        locale: String = "en-US",
        launchAtLoginEnabled: Bool = false,
        wakeListeningEnabledByDefault: Bool = true,
        runtimeMode: RuntimeMode = .production
    ) {
        self.schemaVersion = schemaVersion
        self.conversationProvider = conversationProvider
        self.conversationModel = conversationModel
        self.conversationEndpoint = conversationEndpoint
        self.voiceProvider = voiceProvider
        self.voiceModel = voiceModel
        self.voiceID = voiceID
        self.locale = locale
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.wakeListeningEnabledByDefault = wakeListeningEnabledByDefault
        self.runtimeMode = runtimeMode
    }

    /// Safe, zero-configuration defaults — what a fresh install (or a
    /// recovered-from-corruption install) gets. Never a value that would
    /// make the app APPEAR configured when it isn't (`voiceProvider:
    /// "unspecified"` deliberately fails `PremiumVoiceProviderConfig`'s
    /// own `isConfigured` gate exactly like the true absence of config
    /// does today).
    public static let safeDefault = ProductionSettings()
}

public enum ProductionSettingsError: Error, Sendable, Equatable {
    case corrupt(String)
    case unsupportedFutureSchemaVersion(Int)
}

/// P2-PROD-BOOTSTRAP §B3 — atomic-write, corrupt-recovering,
/// schema-migrating settings store. Defaults to
/// `~/Library/Application Support/FRIDAY/settings.json` — deliberately a
/// DIFFERENT directory tree than `CompanionConfiguration`'s
/// `~/Library/Application Support/FridayCompanion/` (binary paths/
/// sockets), matching that type's own existing precedent of keeping
/// distinct concerns in distinct locations.
public struct ProductionSettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = ProductionSettingsStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("FRIDAY", isDirectory: true).appendingPathComponent("settings.json")
    }

    /// Loads settings, migrating older schema versions forward and
    /// recovering to `safeDefault` (never crashing, never throwing to a
    /// caller that just wants "give me SOMETHING usable") if the file is
    /// missing or corrupt. The one case that DOES throw is a schema
    /// version from the FUTURE (a newer app version wrote it, this
    /// older code doesn't know how to migrate it) — silently guessing
    /// at a newer schema's meaning would be worse than a clear error.
    public func load() throws -> ProductionSettings {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return .safeDefault
        }
        let decoder = JSONDecoder()
        // Reuses the SAME `JSONValue` type `RPCFrameClient` already
        // defines (this module) to sniff `schemaVersion` out of
        // possibly-malformed/future-shaped JSON before committing to
        // decoding the whole thing as `ProductionSettings`.
        guard let raw = try? decoder.decode(JSONValue.self, from: data),
              let versionNumber = raw["schemaVersion"]?.numberValue else {
            // Corrupt / unparseable — recover to safe defaults rather
            // than crash or leave the app unusable.
            return .safeDefault
        }
        let version = Int(versionNumber)
        if version > ProductionSettings.currentSchemaVersion {
            throw ProductionSettingsError.unsupportedFutureSchemaVersion(version)
        }
        let migrated = migrate(data, fromVersion: version)
        guard let settings = try? decoder.decode(ProductionSettings.self, from: migrated) else {
            return .safeDefault
        }
        return settings
    }

    /// Migrates raw JSON bytes forward from `fromVersion` to
    /// `ProductionSettings.currentSchemaVersion`. Currently a no-op
    /// (schema version 1 is the only version that has ever existed) —
    /// structured so a real migration only needs to add a `case` here,
    /// never touch `load()`'s control flow.
    private func migrate(_ data: Data, fromVersion: Int) -> Data {
        switch fromVersion {
        case ProductionSettings.currentSchemaVersion:
            return data
        default:
            // No migration path defined yet for this (older) version —
            // decoding will fall through to safe defaults in `load()`
            // if the shape doesn't match `ProductionSettings` as-is.
            return data
        }
    }

    /// Atomic write: encodes to a temp file in the SAME directory, then
    /// `replaceItemAt` — the settings file is never observed in a
    /// partially-written state by a concurrent reader.
    public func save(_ settings: ProductionSettings) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        let tempURL = dir.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
