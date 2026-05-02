import Foundation

public struct ActivationState: Codable, Sendable, Hashable {
    public var enabledServiceModuleIDs: Set<String>
    public var enabledUIModuleIDs: Set<String>
    public var selectedUIModuleID: String?

    public var activeUIModuleID: String? {
        get { selectedUIModuleID }
        set { selectedUIModuleID = newValue }
    }

    public init(
        enabledServiceModuleIDs: Set<String> = [],
        enabledUIModuleIDs: Set<String> = [],
        selectedUIModuleID: String? = nil
    ) {
        self.enabledServiceModuleIDs = enabledServiceModuleIDs
        self.enabledUIModuleIDs = enabledUIModuleIDs
        self.selectedUIModuleID = selectedUIModuleID
    }

    // Backward-compatible initializer retained for older call sites.
    public init(enabledServiceModuleIDs: Set<String> = [], activeUIModuleID: String? = nil) {
        self.enabledServiceModuleIDs = enabledServiceModuleIDs
        enabledUIModuleIDs = activeUIModuleID.map { [$0] } ?? []
        selectedUIModuleID = activeUIModuleID
    }

    private enum CodingKeys: String, CodingKey {
        case enabledServiceModuleIDs
        case enabledUIModuleIDs
        case selectedUIModuleID
        case activeUIModuleID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        enabledServiceModuleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledServiceModuleIDs) ?? []

        let legacyActiveUIModuleID = try container.decodeIfPresent(String.self, forKey: .activeUIModuleID)
        enabledUIModuleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledUIModuleIDs)
            ?? legacyActiveUIModuleID.map { [$0] }
            ?? []
        selectedUIModuleID = try container.decodeIfPresent(String.self, forKey: .selectedUIModuleID)
            ?? legacyActiveUIModuleID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledServiceModuleIDs, forKey: .enabledServiceModuleIDs)
        try container.encode(enabledUIModuleIDs, forKey: .enabledUIModuleIDs)
        try container.encodeIfPresent(selectedUIModuleID, forKey: .selectedUIModuleID)
        try container.encodeIfPresent(selectedUIModuleID, forKey: .activeUIModuleID)
    }
}

public protocol ActivationStore: Sendable {
    func loadState() -> ActivationState
    func saveState(_ state: ActivationState) throws
}

public final class UserDefaultsActivationStore: ActivationStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "forsetti.activation.state") {
        self.defaults = defaults
        self.key = key
    }

    public func loadState() -> ActivationState {
        guard let data = defaults.data(forKey: key),
              let state = try? decoder.decode(ActivationState.self, from: data) else {
            return ActivationState()
        }
        return state
    }

    public func saveState(_ state: ActivationState) throws {
        let data = try encoder.encode(state)
        defaults.set(data, forKey: key)
    }
}
