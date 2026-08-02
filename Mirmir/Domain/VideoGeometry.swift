import CoreGraphics
import Foundation

struct VideoPixelAspectRatio: Equatable, Sendable {
    let horizontalSpacing: Int
    let verticalSpacing: Int
}

enum VideoOrientation: String, Equatable, Sendable {
    case landscape = "Landscape"
    case portrait = "Portrait"
    case square = "Square"
    case unknown = "Unknown"
}

struct VideoGeometry: Equatable, Sendable {
    let encodedSize: CGSize?
    let naturalSize: CGSize
    let presentationSize: CGSize
    let displaySize: CGSize
    let preferredTransform: CGAffineTransform
    let cleanAperture: CGRect?
    let pixelAspectRatio: VideoPixelAspectRatio?

    var orientation: VideoOrientation {
        guard displaySize.width.isFinite,
              displaySize.height.isFinite,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return .unknown
        }

        if abs(displaySize.width - displaySize.height) < 0.5 {
            return .square
        }
        return displaySize.width > displaySize.height ? .landscape : .portrait
    }

    static func displaySize(
        presentationSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let transformedBounds = CGRect(
            origin: .zero,
            size: presentationSize
        )
        .applying(preferredTransform)
        .standardized

        return CGSize(
            width: transformedBounds.width,
            height: transformedBounds.height
        )
    }
}
