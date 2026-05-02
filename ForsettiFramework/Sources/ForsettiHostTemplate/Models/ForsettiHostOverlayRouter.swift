import Combine
import Foundation
import ForsettiCore

public enum ForsettiHostRouteStatus: String, Sendable {
    case schemaUnavailable
    case missingPointer
    case missingRoute
    case invalidBaseDestination
    case invalidSlot
    case pointerResolved
    case routeResolved
}

public struct ForsettiHostRouteOutcome: Sendable, Equatable {
    public let status: ForsettiHostRouteStatus
    public let referenceID: String
    public let message: String

    public init(status: ForsettiHostRouteStatus, referenceID: String, message: String) {
        self.status = status
        self.referenceID = referenceID
        self.message = message
    }
}

@MainActor
public final class ForsettiHostOverlayRouter: OverlayRouting, ObservableObject, @unchecked Sendable {
    @Published public private(set) var lastOutcome: ForsettiHostRouteOutcome?

    private let uiSurfaceManager: UISurfaceManager
    private let baseDestinationIDs: Set<String>
    private let slotIDs: Set<String>

    public init(
        uiSurfaceManager: UISurfaceManager,
        baseDestinationIDs: [String] = BaseDestinationCatalog.all,
        slotIDs: [String] = SlotCatalog.all
    ) {
        self.uiSurfaceManager = uiSurfaceManager
        self.baseDestinationIDs = Set(baseDestinationIDs)
        self.slotIDs = Set(slotIDs)
    }

    public func openPointer(_ pointerID: String) {
        guard let schema = uiSurfaceManager.overlaySchema else {
            lastOutcome = ForsettiHostRouteOutcome(
                status: .schemaUnavailable,
                referenceID: pointerID,
                message: "No overlay schema is active."
            )
            return
        }

        guard let pointer = schema.pointers.first(where: { $0.pointerID == pointerID }) else {
            lastOutcome = ForsettiHostRouteOutcome(
                status: .missingPointer,
                referenceID: pointerID,
                message: "Pointer '\(pointerID)' was not found in the active overlay schema."
            )
            return
        }

        guard baseDestinationIDs.contains(pointer.target.destinationID) else {
            lastOutcome = ForsettiHostRouteOutcome(
                status: .invalidBaseDestination,
                referenceID: pointerID,
                message: "Pointer '\(pointerID)' targets unsupported destination '\(pointer.target.destinationID)'."
            )
            return
        }

        lastOutcome = ForsettiHostRouteOutcome(
            status: .pointerResolved,
            referenceID: pointerID,
            message: "Pointer '\(pointerID)' resolved to base destination '\(pointer.target.destinationID)'."
        )
    }

    public func openRoute(_ routeID: String) {
        guard let schema = uiSurfaceManager.overlaySchema else {
            lastOutcome = ForsettiHostRouteOutcome(
                status: .schemaUnavailable,
                referenceID: routeID,
                message: "No overlay schema is active."
            )
            return
        }

        guard let route = schema.routes.first(where: { $0.routeID == routeID }) else {
            lastOutcome = ForsettiHostRouteOutcome(
                status: .missingRoute,
                referenceID: routeID,
                message: "Route '\(routeID)' was not found in the active overlay schema."
            )
            return
        }

        switch route.destination {
        case let .base(destinationID, _):
            guard baseDestinationIDs.contains(destinationID) else {
                lastOutcome = ForsettiHostRouteOutcome(
                    status: .invalidBaseDestination,
                    referenceID: routeID,
                    message: "Route '\(routeID)' targets unsupported destination '\(destinationID)'."
                )
                return
            }

            lastOutcome = ForsettiHostRouteOutcome(
                status: .routeResolved,
                referenceID: routeID,
                message: "Route '\(routeID)' resolved to base destination '\(destinationID)'."
            )
        case let .moduleOverlay(_, slot):
            guard slotIDs.contains(slot) else {
                lastOutcome = ForsettiHostRouteOutcome(
                    status: .invalidSlot,
                    referenceID: routeID,
                    message: "Route '\(routeID)' targets unsupported slot '\(slot)'."
                )
                return
            }

            lastOutcome = ForsettiHostRouteOutcome(
                status: .routeResolved,
                referenceID: routeID,
                message: "Route '\(routeID)' resolved to overlay slot '\(slot)'."
            )
        }
    }
}
