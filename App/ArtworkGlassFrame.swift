import SwiftUI
import UIKit

enum ArtworkGlassGeometry {
    static func fittedRect(image: CGSize, viewport: CGSize) -> CGRect {
        guard image.width.isFinite, image.height.isFinite, viewport.width.isFinite, viewport.height.isFinite, image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2, width: size.width, height: size.height)
    }

    static func bandWidth(for size: CGSize) -> CGFloat { min(10, max(4, min(size.width, size.height) * 0.024)) }
    static func cornerRadius(for size: CGSize) -> CGFloat { min(20, min(size.width, size.height) * 0.06) }
}

struct CanvasArtwork: View {
    let image: UIImage
    let clearProgress: CGFloat
    var imageDim = 0.0

    var body: some View {
        GeometryReader { geometry in
            let bounds = ArtworkGlassGeometry.fittedRect(image: image.size, viewport: geometry.size)
            let progress = min(1, max(0, clearProgress))
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: bounds.width, height: bounds.height)
                .overlay(Color.black.opacity(imageDim))
                .clipShape(RoundedRectangle(cornerRadius: ArtworkGlassGeometry.cornerRadius(for: bounds.size) * progress, style: .continuous))
                .overlay(ArtworkGlassFrame(size: bounds.size).opacity(progress))
                .position(x: bounds.midX, y: bounds.midY)
        }
    }
}

struct ArtworkGlassFrame: View {
    let size: CGSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let width = ArtworkGlassGeometry.bandWidth(for: size)
        let shape = RoundedRectangle(cornerRadius: ArtworkGlassGeometry.cornerRadius(for: size), style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.strokeBorder(Color(white: 0.32), lineWidth: width)
            } else {
                shape.fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .light)
                    .mask(shape.strokeBorder(lineWidth: width))
                    .opacity(0.72)
            }
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.48), location: 0), .init(color: .white.opacity(0.06), location: 0.34), .init(color: .white.opacity(0.02), location: 0.62), .init(color: Color(red: 0.82, green: 0.94, blue: 1).opacity(0.25), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: width)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.16), .white.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            shape.inset(by: width).stroke(LinearGradient(colors: [.black.opacity(0.18), .white.opacity(0.36)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
