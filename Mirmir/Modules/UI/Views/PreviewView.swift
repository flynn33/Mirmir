import SwiftUI
import AppKit
import MetalKit

struct PreviewView: View {
    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        ZStack {
            Color.black
            VStack {
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let profile = viewModel.sourceProfile {
                    let arrow = String(describing: profile.resolution) + " → " + String(describing: viewModel.targetResolution)
                    Text(arrow)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        switch viewModel.state {
        case .idle: return "Preview"
        case .probing: return "Probing source…"
        case .ready: return "Ready to upscale"
        case .running: return "Upscaling…"
        case .finished: return "Upscale complete"
        case .failed: return "Upscale failed"
        }
    }
}

/// MTKView host kept around for the next iteration: the live frame texture is
/// not yet wired into the view model so this preview surface is currently a
/// placeholder. The class is retained so the wiring can be added without
/// reshaping the view tree.
final class MetalPreviewNSView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
