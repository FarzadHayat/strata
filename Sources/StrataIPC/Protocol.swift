import Foundation
import StrataCore

/// Messages exchanged between the root daemon and the user's GUI over a Unix socket, one JSON object per line.
public enum IPC {
    /// Per-user socket: owned by that user, mode 0600, so only they can talk to their daemon.
    public static func socketPath(uid: uid_t) -> String { "/var/run/strata/\(uid).sock" }
    public static let socketDirectory = "/var/run/strata"

    /// GUI → daemon.
    public enum Request: Codable, Sendable, Equatable {
        /// Ask for a full `status` message.
        case status
        /// Re-read the config file now.
        case reload
        /// Report the next physical key press as a `learned` event (for the editor's "press a key").
        case learn
        /// Stop learning without a key.
        case cancelLearn
        /// The GUI's view of the TCC state (the daemon cannot prompt, but it can display what the GUI found).
        case permissions(PermissionSnapshot)
    }

    /// Daemon → GUI.
    public enum Event: Codable, Sendable, Equatable {
        case status(Status)
        case layer(active: [String])
        case learned(key: String, page: UInt16, usage: UInt16)
        case log(String)
    }

    public struct PermissionSnapshot: Codable, Sendable, Equatable {
        public var inputMonitoring: String
        public var accessibility: Bool
        public init(inputMonitoring: String, accessibility: Bool) {
            self.inputMonitoring = inputMonitoring
            self.accessibility = accessibility
        }
    }

    public struct DeviceStatus: Codable, Sendable, Equatable, Identifiable {
        public var id: UInt64
        public var name: String
        public var seized: Bool
        public var note: String?
        public init(id: UInt64, name: String, seized: Bool, note: String?) {
            self.id = id; self.name = name; self.seized = seized; self.note = note
        }
    }

    public struct ConfigStatus: Codable, Sendable, Equatable {
        public var path: String
        public var loaded: Bool
        public var layers: [String]
        public var errors: [String]
        public var warnings: [String]
        public var lastLoad: Date?
        public init(path: String, loaded: Bool, layers: [String], errors: [String], warnings: [String], lastLoad: Date?) {
            self.path = path; self.loaded = loaded; self.layers = layers; self.errors = errors; self.warnings = warnings; self.lastLoad = lastLoad
        }
    }

    public struct Status: Codable, Sendable, Equatable {
        public var version: String
        public var daemonPID: Int32
        public var uptime: TimeInterval
        /// What the daemon itself observes (this is what decides whether seizing works).
        public var permissions: PermissionSnapshot
        /// What the GUI process last reported, if any (same bundle, so normally identical once TCC settles).
        public var guiPermissions: PermissionSnapshot?
        public var driverActivated: Bool
        public var vhidConnected: Bool
        public var vhidReady: Bool
        public var vhidError: String?
        public var devices: [DeviceStatus]
        public var config: ConfigStatus
        public var activeLayers: [String]
        public var paused: Bool
        public init(version: String, daemonPID: Int32, uptime: TimeInterval, permissions: PermissionSnapshot,
                    guiPermissions: PermissionSnapshot? = nil, driverActivated: Bool, vhidConnected: Bool, vhidReady: Bool, vhidError: String?,
                    devices: [DeviceStatus], config: ConfigStatus, activeLayers: [String], paused: Bool) {
            self.version = version; self.daemonPID = daemonPID; self.uptime = uptime; self.permissions = permissions
            self.guiPermissions = guiPermissions; self.driverActivated = driverActivated; self.vhidConnected = vhidConnected; self.vhidReady = vhidReady
            self.vhidError = vhidError; self.devices = devices; self.config = config; self.activeLayers = activeLayers
            self.paused = paused
        }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try decoder.decode(type, from: line)
    }
}
