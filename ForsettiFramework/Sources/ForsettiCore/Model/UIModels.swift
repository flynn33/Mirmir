import Foundation

public struct UIContributions: Codable, Hashable, Sendable {
    public let themeMask: ThemeMask?
    public let toolbarItems: [ToolbarItemDescriptor]
    public let viewInjections: [ViewInjectionDescriptor]
    public let overlaySchema: OverlaySchema?

    public init(
        themeMask: ThemeMask? = nil,
        toolbarItems: [ToolbarItemDescriptor] = [],
        viewInjections: [ViewInjectionDescriptor] = [],
        overlaySchema: OverlaySchema? = nil
    ) {
        self.themeMask = themeMask
        self.toolbarItems = toolbarItems
        self.viewInjections = viewInjections
        self.overlaySchema = overlaySchema
    }

    public static let empty = UIContributions()
}

public struct OverlaySchema: Codable, Hashable, Sendable {
    public let schemaID: String
    public let pointers: [NavigationPointer]
    public let routes: [OverlayRoute]

    public init(schemaID: String, pointers: [NavigationPointer], routes: [OverlayRoute]) {
        self.schemaID = schemaID
        self.pointers = pointers
        self.routes = routes
    }
}

public struct NavigationPointer: Codable, Hashable, Sendable {
    public let pointerID: String
    public let label: String
    public let target: BaseDestinationRef
    public let presentation: OverlayPresentation

    public init(
        pointerID: String,
        label: String,
        target: BaseDestinationRef,
        presentation: OverlayPresentation
    ) {
        self.pointerID = pointerID
        self.label = label
        self.target = target
        self.presentation = presentation
    }
}

public enum OverlayPresentation: String, Codable, Hashable, Sendable {
    case sheet
    case popover
    case inline
    case push
}

public struct BaseDestinationRef: Codable, Hashable, Sendable {
    public let destinationID: String
    public let parameters: [String: String]?

    public init(destinationID: String, parameters: [String: String]? = nil) {
        self.destinationID = destinationID
        self.parameters = parameters
    }
}

public struct OverlayRoute: Codable, Hashable, Sendable {
    public let routeID: String
    public let path: String
    public let destination: OverlayDestination

    public init(routeID: String, path: String, destination: OverlayDestination) {
        self.routeID = routeID
        self.path = path
        self.destination = destination
    }
}

public enum OverlayDestination: Codable, Hashable, Sendable {
    case base(destinationID: String, parameters: [String: String]?)
    case moduleOverlay(viewID: String, slot: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case destinationID
        case parameters
        case viewID
        case slot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "base":
            self = .base(
                destinationID: try container.decode(String.self, forKey: .destinationID),
                parameters: try container.decodeIfPresent([String: String].self, forKey: .parameters)
            )
        case "moduleOverlay":
            self = .moduleOverlay(
                viewID: try container.decode(String.self, forKey: .viewID),
                slot: try container.decode(String.self, forKey: .slot)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown overlay destination type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .base(destinationID, parameters):
            try container.encode("base", forKey: .type)
            try container.encode(destinationID, forKey: .destinationID)
            try container.encodeIfPresent(parameters, forKey: .parameters)
        case let .moduleOverlay(viewID, slot):
            try container.encode("moduleOverlay", forKey: .type)
            try container.encode(viewID, forKey: .viewID)
            try container.encode(slot, forKey: .slot)
        }
    }
}

public struct ThemeMask: Codable, Hashable, Sendable {
    public let themeID: String
    public let tokens: [ThemeToken]

    public init(themeID: String, tokens: [ThemeToken]) {
        self.themeID = themeID
        self.tokens = tokens
    }
}

public struct ThemeToken: Codable, Hashable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct ToolbarItemDescriptor: Codable, Hashable, Sendable {
    public let itemID: String
    public let title: String
    public let systemImageName: String?
    public let action: ToolbarAction

    public init(itemID: String, title: String, systemImageName: String? = nil, action: ToolbarAction) {
        self.itemID = itemID
        self.title = title
        self.systemImageName = systemImageName
        self.action = action
    }
}

public enum ToolbarAction: Codable, Hashable, Sendable {
    case navigate(pointerID: String)
    case openOverlay(routeID: String)
    case publishEvent(type: String, payload: [String: String]?)

    private enum CodingKeys: String, CodingKey {
        case type
        case pointerID
        case routeID
        case eventType
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "navigate":
            self = .navigate(pointerID: try container.decode(String.self, forKey: .pointerID))
        case "openOverlay":
            self = .openOverlay(routeID: try container.decode(String.self, forKey: .routeID))
        case "publishEvent":
            self = .publishEvent(
                type: try container.decode(String.self, forKey: .eventType),
                payload: try container.decodeIfPresent([String: String].self, forKey: .payload)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown toolbar action type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .navigate(pointerID):
            try container.encode("navigate", forKey: .type)
            try container.encode(pointerID, forKey: .pointerID)
        case let .openOverlay(routeID):
            try container.encode("openOverlay", forKey: .type)
            try container.encode(routeID, forKey: .routeID)
        case let .publishEvent(eventType, payload):
            try container.encode("publishEvent", forKey: .type)
            try container.encode(eventType, forKey: .eventType)
            try container.encodeIfPresent(payload, forKey: .payload)
        }
    }
}

public struct ViewInjectionDescriptor: Codable, Hashable, Sendable {
    public let injectionID: String
    public let slot: String
    public let viewID: String
    public let priority: Int

    public init(injectionID: String, slot: String, viewID: String, priority: Int) {
        self.injectionID = injectionID
        self.slot = slot
        self.viewID = viewID
        self.priority = priority
    }
}
