import SwiftUI
import UIKit

enum FuyuArtworkGeometry {
    static func exhibitionRect(viewport: CGSize) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let portrait = viewport.height >= viewport.width
        let top = portrait ? max(128, viewport.height * 0.18) : 18
        let bottom = portrait ? max(176, viewport.height * 0.25) : 18
        let inset = portrait ? 28.0 : max(100, viewport.width * 0.22)
        return CGRect(x: inset, y: top, width: max(1, viewport.width - inset * 2), height: max(1, viewport.height - top - bottom))
    }
}

struct FuyuArtworkCanvas: View {
    let image: UIImage
    let clearProgress: CGFloat
    var imageDim = 0.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            let box = FuyuArtworkGeometry.exhibitionRect(viewport: geometry.size)
            ZStack {
                Palette.fog
                if !reduceTransparency {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().blur(radius: 28, opaque: true).overlay(Palette.fog.opacity(0.64))
                }
                CanvasArtwork(image: image, clearProgress: clearProgress, imageDim: imageDim)
                    .frame(width: box.width, height: box.height)
                    .shadow(color: Palette.lake.opacity(0.16), radius: 18, x: 0, y: 12)
                    .position(x: box.midX, y: box.midY)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

