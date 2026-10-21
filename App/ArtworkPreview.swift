import SwiftUI
import UIKit

struct ArtworkPresentation: Identifiable {
    let id = UUID()
    let image: UIImage
    var title = "作品"
    var fileURL: URL?
}

struct ArtworkPreview: View {
    let image: UIImage
    var title = "作品"
    var fileURL: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var controlsVisible = true
    @State private var zoomRequest = 0
    @State private var sharing = false
    @State private var saving = false
    @State private var message: String?

    private var backdrop: UIImage { fileURL.flatMap { MediaImages.image(url: $0, maxPixel: 400) } ?? image }
    var body: some View {
        ZStack {
            Palette.lake.ignoresSafeArea()
            if !reduceTransparency {
                GeometryReader { geometry in
                    Image(uiImage: backdrop).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .blur(radius: 30, opaque: true).overlay(Color.black.opacity(0.58))
                }.ignoresSafeArea()
            }
            ZoomableArtwork(image: image, zoomRequest: zoomRequest) { controlsVisible.toggle() }
                .ignoresSafeArea()
                .accessibilityLabel("生成图全屏预览，可双指缩放、拖动，双击放大或还原")
                .accessibilityIdentifier("artwork-fullscreen")
        }
        .overlay(alignment: .top) {
            if controlsVisible {
                HStack(spacing: 14) {
                    Text(title).font(.custom("STSongti-SC-Regular", size: 21, relativeTo: .title3))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).shadow(color: .black.opacity(0.5), radius: 4)
                    Button { dismiss() } label: {
                        GlassPanel(padding: 0, cornerRadius: 22) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    }.accessibilityLabel("关闭全屏预览")
                }.foregroundColor(.white).padding(18)
            }
        }
        .overlay(alignment: .bottom) {
            if controlsVisible {
                GlassPanel(padding: 6, cornerRadius: 28) {
                    HStack(spacing: 14) {
                        Button { zoomRequest += 1 } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("放大或还原")
                        Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.disabled(fileURL == nil).accessibilityLabel("分享原文件")
                        Button {
                            guard let url = fileURL else { return }
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await PhotoExporter.save(url: url, video: false); message = "已保存到系统相册。" }
                                catch { message = error.localizedDescription }
                            }
                        } label: {
                            Group { if saving { ProgressView() } else { Image(systemName: "square.and.arrow.down") } }.frame(width: 44, height: 44)
                        }.disabled(fileURL == nil || saving).accessibilityLabel("保存到相册")
                    }
                }.fixedSize(horizontal: true, vertical: false).padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.dark).statusBar(hidden: true)
        .accessibilityAction(named: Text("关闭全屏预览")) { dismiss() }
        .accessibilityAction(named: Text("显示看图工具")) { controlsVisible = true }
        .sheet(isPresented: $sharing) { if let url = fileURL { ShareSheet(items: [url]) } }
        .alert("保存结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}

struct ZoomableArtwork: UIViewRepresentable {
    let image: UIImage
    var zoomRequest = 0
    let tapped: () -> Void

    func makeUIView(context: Context) -> ArtworkScrollView {
        ArtworkScrollView(image: image, tapped: tapped)
    }

    func updateUIView(_ view: ArtworkScrollView, context: Context) {
        view.tapped = tapped
        if view.zoomRequest != zoomRequest { view.zoomRequest = zoomRequest; view.toggleZoomAtCenter() }
    }
}

final class ArtworkScrollView: UIScrollView, UIScrollViewDelegate {
    let artworkView = UIImageView()
    var tapped: () -> Void
    var zoomRequest = 0
    private var viewport = CGSize.zero

    init(image: UIImage, tapped: @escaping () -> Void) {
        self.tapped = tapped
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        artworkView.image = image
        artworkView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(artworkView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let image = artworkView.image else { return }
        if viewport != bounds.size {
            viewport = bounds.size
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fit
            maximumZoomScale = fit * 6
            zoomScale = fit
            contentSize = artworkView.frame.size
        }
        centerArtwork()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { artworkView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerArtwork() }

    private func centerArtwork() {
        let horizontal = max(0, (bounds.width - artworkView.frame.width) / 2)
        let vertical = max(0, (bounds.height - artworkView.frame.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    func toggleZoomAtCenter() {
        let target = zoomScale > minimumZoomScale * 1.01 ? minimumZoomScale : min(maximumZoomScale, minimumZoomScale * 3)
        setZoomScale(target, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func toggleControls() { tapped() }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 { setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let target = minimumZoomScale * 3
            let point = gesture.location(in: artworkView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
