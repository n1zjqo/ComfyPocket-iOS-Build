import SwiftUI
import UIKit
import ComfyCore

struct ConversationResultBubble: View {
    @EnvironmentObject var state: AppState
    let asset: GalleryAsset
    let open: () -> Void

    private var image: UIImage? {
        guard asset.output.kind == .image, let name = asset.localName, let url = state.disk?.mediaURL(name) else { return nil }
        return MediaImages.image(url: url, maxPixel: 800)
    }
    private var title: String {
        switch asset.output.kind {
        case .image: return "查看生成图片"
        case .video: return "查看生成视频"
        case .text: return "查看文字结果"
        }
    }

    var body: some View {
        Button(action: open) {
            GlassPanel(padding: 6, cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    if let image = image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                            .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if asset.output.kind == .text {
                        Text(asset.output.text).font(.body).lineLimit(8).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: asset.output.kind == .video ? "play.rectangle" : "photo").font(.largeTitle)
                            Text(asset.localName == nil ? "等待下载结果…" : "点开查看或分享原文件").font(.footnote)
                        }.frame(maxWidth: .infinity, minHeight: 160)
                    }
                    HStack(spacing: 6) {
                        Text(title).font(.footnote.weight(.medium))
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.caption)
                    }.padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
        }.buttonStyle(.plain).frame(maxWidth: 280, alignment: .leading)
            .accessibilityLabel(title).accessibilityHint("打开作品详情，可保存、分享或收藏提示词")
            .accessibilityIdentifier("conversation-result-" + asset.id.uuidString)
    }
}
