import SwiftUI
import UIKit

enum Palette {
    static let fog = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.12, blue: 0.115, alpha: 1) : UIColor(red: 0.929, green: 0.953, blue: 0.937, alpha: 1)
    })
    static let lake = Color(red: 0.122, green: 0.255, blue: 0.247)
    static let mist = Color(red: 0.976, green: 1, blue: 0.976)
    static let ink = Color.primary
    static let card = Color(UIColor.secondarySystemGroupedBackground)
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.64, green: 0.82, blue: 0.75, alpha: 1) : UIColor(red: 0.22, green: 0.408, blue: 0.365, alpha: 1)
    })
    static let actionFill = Color(red: 0.22, green: 0.408, blue: 0.365)
    static let muted = Color(red: 0.322, green: 0.431, blue: 0.412)
}
struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 24
    var light = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .foregroundColor(light ? Palette.lake : .white)
            .padding(padding)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill((light ? Palette.mist : Color(red: 0.07, green: 0.14, blue: 0.13))) }
                else { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial).overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill((light ? Palette.mist.opacity(0.4) : Color.black.opacity(0.18)))) }
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.65))
            .environment(\.colorScheme, light ? .light : .dark)
    }
}

struct EmptyArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.fog
                Ellipse().fill(Color(red: 0.73, green: 0.83, blue: 0.79)).frame(width: proxy.size.width * 1.4, height: proxy.size.height * 0.65).rotationEffect(.degrees(-30)).offset(x: -proxy.size.width * 0.3, y: -proxy.size.height * 0.15)
                Ellipse().fill(Color(red: 0.54, green: 0.68, blue: 0.64)).frame(width: proxy.size.width * 1.8, height: proxy.size.height * 0.7).rotationEffect(.degrees(-25)).offset(x: proxy.size.width * 0.3, y: proxy.size.height * 0.35)
            }
        }
        .accessibilityHidden(true)
    }
}

struct QuietEmpty: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundColor(Palette.accent)
                    Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.body).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
                }.padding(28).frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}
