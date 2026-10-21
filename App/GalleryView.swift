import SwiftUI
import AVKit
import ComfyCore

struct GalleryView: View {
    @EnvironmentObject var state: AppState
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]
    var body: some View {
        NavigationView {
            Group {
                if state.galleryAssets.isEmpty {
                    QuietEmpty(icon: "photo.on.rectangle.angled", title: "作品会留在这里", detail: "完成一次生成后，可查看原图、播放视频、保存文字，或把图片设为聊天背景。")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(state.galleryAssets) { asset in
                                NavigationLink { AssetDetailView(assetID: asset.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        AssetThumbnail(asset: asset).frame(height: 180).clipped().cornerRadius(18)
                                        Text(asset.output.kind == .text ? "文字结果" : asset.output.filename).font(.caption).lineLimit(2).foregroundColor(Palette.ink)
                                        Text(asset.createdAt, style: .date).font(.caption2).foregroundColor(.secondary)
                                    }.padding(8).background(Palette.card, in: RoundedRectangle(cornerRadius: 23))
                                }.buttonStyle(.plain).accessibilityIdentifier("gallery-asset-" + asset.id.uuidString)
                            }
                        }.padding(16)
                    }
                }
            }.background(Palette.fog).navigationTitle("作品").navigationViewStyle(.stack)
        }.navigationViewStyle(.stack)
    }
}
struct AssetThumbnail: View {
    @EnvironmentObject var state: AppState
    let asset: GalleryAsset
    var body: some View {
        ZStack {
            Palette.fog
            if let name = asset.localName, let url = state.disk?.mediaURL(name), asset.output.kind == .image, let image = MediaImages.image(url: url) {
                GeometryReader { proxy in Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped() }
            } else if asset.output.kind == .text {
                Text(asset.output.text).font(.callout).lineLimit(7).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: asset.output.kind == .video ? "play.rectangle" : "arrow.down.circle").font(.largeTitle)
                    Text(asset.localName == nil ? "等待下载" : (asset.output.kind == .video ? "视频作品" : "原文件可分享")).font(.caption)
                }.foregroundColor(Palette.accent)
            }
        }.accessibilityLabel(asset.output.kind == .text ? asset.output.text : asset.output.filename)
    }
}

struct AssetDetailView: View {
    @EnvironmentObject var state: AppState
    let assetID: UUID
    @State private var sharing = false
    @State private var deleting = false
    @State private var saving = false
    @State private var player: AVPlayer?
    @State private var artwork: ArtworkPresentation?
    @Environment(\.dismiss) private var dismiss
    private var asset: GalleryAsset? { state.visibleAssets.first { $0.id == assetID } }
    private func localURL(_ asset: GalleryAsset) -> URL? {
        guard let name = asset.localName, let url = state.disk?.mediaURL(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    var body: some View {
        Group {
            if let asset = asset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if asset.output.kind == .text {
                            Text(asset.output.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().background(Palette.fog, in: RoundedRectangle(cornerRadius: 20))
                        } else if let url = localURL(asset) {
                            if asset.output.kind == .image, let image = MediaImages.image(url: url, maxPixel: 2400) {
                                Image(uiImage: image).resizable().scaledToFit().cornerRadius(4)
                                Button("全屏看图") { artwork = ArtworkPresentation(image: image, title: state.job(asset.jobID)?.workflow.name ?? "作品", fileURL: url) }
                            } else if asset.output.kind == .video {
                                VideoPlayer(player: player).frame(minHeight: 260).cornerRadius(20)
                                Text("若系统播放器不支持此编码，请分享原文件到兼容的播放器。App 不转码，也不修改原文件。").font(.footnote).foregroundColor(.secondary)
                            } else { Text("iOS 无法预览此图片格式，仍可分享原文件。").foregroundColor(.secondary) }
                        } else {
                            Text("原文件尚未下载。请到任务列表继续核对和下载；如果服务器已清理结果，则需要重新生成。").foregroundColor(.secondary)
                        }
                        HStack {
                            Text(asset.createdAt, style: .date)
                            Spacer()
                            Text("种子 \(asset.seed)").textSelection(.enabled)
                        }.font(.caption).foregroundColor(.secondary)
                        if let job = state.job(asset.jobID) {
                            Text(job.workflow.name).font(.headline)
                            if !job.prompt(for: asset.promptID).isEmpty, asset.output.kind != .text || OutputPresentation.normalizedText(asset.output.text) != OutputPresentation.normalizedText(job.prompt(for: asset.promptID)) { Text(job.prompt(for: asset.promptID)).textSelection(.enabled) }
                            Button("收藏这段提示词") { state.saveNote(title: "", text: job.prompt(for: asset.promptID)) }
                        }
                        if asset.output.kind != .text, !state.supplementaryTextOutputs(for: asset).isEmpty {
                            DisclosureGroup("工作流文字输出") {
                                ForEach(state.supplementaryTextOutputs(for: asset)) { output in
                                    Text(output.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                                }
                            }
                        }
                        if asset.output.kind == .image, localURL(asset) != nil {
                            Button { state.setBackground(asset) } label: { Label("设为聊天背景", systemImage: "rectangle.inset.filled") }.buttonStyle(.borderedProminent)
                            Button("按原工作流随机再生成一张") { state.regenerate(asset) }
                        }
                        HStack {
                            Button { sharing = true } label: { Label("分享原文件", systemImage: "square.and.arrow.up") }.disabled(asset.output.kind != .text && localURL(asset) == nil)
                            Spacer()
                            if asset.output.kind != .text, let url = localURL(asset) {
                                Button(saving ? "保存中…" : "保存到相册") {
                                    saving = true
                                    Task {
                                        defer { saving = false }
                                        do { try await PhotoExporter.save(url: url, video: asset.output.kind == .video); state.notice = "已保存到相册" } catch { state.report(error) }
                                    }
                                }.disabled(saving)
                            }
                        }.buttonStyle(.bordered)
                        Button("删除本地作品", role: .destructive) { deleting = true }.padding(.top, 12)
                    }.padding(18)
                }
                .sheet(isPresented: $sharing) {
                    if asset.output.kind == .text { ShareSheet(items: [asset.output.text]) }
                    else if let url = localURL(asset) { ShareSheet(items: [url]) }
                }
                .confirmationDialog("仅删除本机文件，不会删除 ComfyUI 服务器上的原件。", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除作品", role: .destructive) { player?.pause(); state.removeAsset(asset); dismiss() }
                }
                .onAppear { if asset.output.kind == .video, let url = localURL(asset) { player = AVPlayer(url: url) } }
                .onDisappear { player?.pause(); player = nil }
            } else { QuietEmpty(icon: "photo", title: "作品已删除", detail: "返回作品列表查看其他结果。") }
        }.navigationTitle("作品详情").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $artwork) { presentation in ArtworkPreview(image: presentation.image, title: presentation.title, fileURL: presentation.fileURL) }
    }
}
