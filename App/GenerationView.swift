import SwiftUI
import UIKit
import ComfyCore

struct GenerationView: View {
    @EnvironmentObject var state: AppState

    let settingsAction: () -> Void
    let importAction: () -> Void
    let isActive: Bool
    @State private var parameters = false
    @State private var queue = false
    @State private var notes = false
    @State private var picker: InputSpec?
    @State private var pickerWorkflowID: UUID?
    @State private var promptFocused = false
    @State private var promptHeight: CGFloat = 44
    @State private var confirmQueue = false
    @EnvironmentObject private var canvas: CanvasClearState
    @State private var artwork: ArtworkPresentation?
    @State private var resultAsset: GalleryAsset?
    @State private var chatVisible = ProcessInfo.processInfo.arguments.contains("--conversation-demo")

    private var plannedTaskCount: Int {
        guard let workflow = state.selectedWorkflow else { return state.batch }
        return ((try? RayQueue.selection(workflow: workflow, values: workflow.lastValues))?.prompts.count ?? 1) * state.batch
    }
    private var promptSpec: InputSpec? { state.selectedWorkflow?.mainPrompt }
    private var conversationJobs: [GenerationJob] { state.saved.jobs.filter { $0.workflow.id == state.saved.selectedWorkflowID } }
    private var latestJob: GenerationJob? { conversationJobs.last }
    private var latestReplyKey: String {
        let assets = state.visibleAssets.filter { $0.jobID == latestJob?.id }
        return assets.map { $0.id.uuidString + ($0.localName ?? "") }.joined(separator: ":")
    }

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                GeometryReader { background in
                    ZStack {
                        Palette.fog
                        if let image = state.backgroundImage {
                            FuyuArtworkCanvas(image: image, clearProgress: canvas.progress, imageDim: state.saved.backgroundDim * (chatVisible ? 1 : 0) * (1 - canvas.progress))
                                .frame(width: background.size.width, height: background.size.height)
                        } else { EmptyArtwork() }
                    }.frame(width: background.size.width, height: background.size.height)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(canvas.isCleared ? "清屏画面，左滑恢复聊天" : "生成结果背景，右滑清屏")
                        .accessibilityIdentifier("generation-artwork")
                        .accessibilityAction(named: Text(canvas.isCleared ? "恢复聊天" : "清屏看图")) { canvas.setCleared(!canvas.isCleared) }
                        .onTapGesture { promptFocused = false }
                }.ignoresSafeArea()
                VStack(spacing: 0) {
                    header.padding(.horizontal, 18).padding(.top, 10)
                    if state.backgroundImage != nil && !chatVisible {
                        Spacer(minLength: 0)
                    } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .trailing, spacing: 14) {
                                if state.selectedServer == nil || state.selectedWorkflow == nil { welcome.padding(.top, 32) }
                                else if !conversationJobs.isEmpty {
                                    ForEach(conversationJobs) { job in
                                        jobMessages(job).id(job.id)
                                    }
                                } else {
                                    GlassPanel { VStack(alignment: .leading, spacing: 8) { Text("让作品留在眼前").font(.title2.weight(.semibold)); Text("写下提示词，图片会回复在聊天里，也会成为这里的背景。右滑清屏，左滑恢复聊天。").font(.body).foregroundColor(.white.opacity(0.85)) } }.padding(.top, 40)
                                }
                            }.frame(maxWidth: 640).padding(.horizontal, 18).padding(.bottom, 18).frame(maxWidth: .infinity)
                        }
                        .onAppear { if let identity = latestJob?.id { reader.scrollTo(identity, anchor: .bottom) } }
                        .onChange(of: latestJob?.id) { identity in if let identity = identity { reader.scrollTo(identity, anchor: .bottom) } }
                        .onChange(of: latestReplyKey) { _ in if let identity = latestJob?.id { reader.scrollTo(identity, anchor: .bottom) } }
                    }
                    }
                    galleryActions.padding(.horizontal, 20)
                    composer.padding(.horizontal, 16).padding(.bottom, 10)
                }
                .offset(x: max(viewport.size.width, canvas.viewportWidth) * canvas.progress)
                .allowsHitTesting(!canvas.isCleared)
                .accessibilityHidden(canvas.isCleared)
            }
            .background(CanvasSwipeBridge(canvas: canvas, enabled: isActive && !parameters && !queue && !notes && !confirmQueue && picker == nil && artwork == nil && resultAsset == nil))
            .background(Palette.fog)
            .foregroundColor(Palette.lake)
            .environment(\.colorScheme, .light)

        }

        .onChange(of: state.saved.selectedWorkflowID) { _ in promptFocused = false; chatVisible = false }
        .onChange(of: latestJob?.id) { _ in chatVisible = true }
        .onChange(of: canvas.isDragging) { dragging in if dragging { promptFocused = false } }
        .onChange(of: canvas.isCleared) { cleared in if cleared { promptFocused = false } }
        .accessibilityAction(.escape) { canvas.setCleared(false) }
        .fullScreenCover(item: $artwork) { presentation in ArtworkPreview(image: presentation.image, title: presentation.title, fileURL: presentation.fileURL) }
        .sheet(item: $resultAsset) { asset in
            NavigationView {
                AssetDetailView(assetID: asset.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { resultAsset = nil } } }
            }.navigationViewStyle(.stack)
        }
        .sheet(isPresented: $parameters) { ParametersView() }
        .sheet(isPresented: $queue) { JobsView() }
        .sheet(isPresented: $notes) { PromptLibraryView(select: { text in if let spec = promptSpec { state.setValue(spec, text: text) } }) }
        .sheet(item: $picker) { spec in
            MediaPicker(video: spec.kind == .video) { result in
                picker = nil
                switch result {
                case .success(let url):
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard state.saved.selectedWorkflowID == pickerWorkflowID else { state.error = "工作流已切换，请重新选择参考素材。"; return }
                    do { try state.stageAttachment(from: url, specID: spec.id) } catch { state.report(error) }
                case .failure(let error): if !(error is CancellationError) { state.report(error) }
                }
            }
        }
    }

    private func jobMessages(_ job: GenerationJob) -> some View {
        VStack(alignment: .trailing, spacing: 14) {
            if !job.prompt.isEmpty {
                GlassPanel(padding: 14) { Text(job.prompt).font(.body).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxWidth: 290).padding(.top, 24)
            }
            GlassPanel(padding: 15) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: job.phase == .success ? "checkmark.circle" : "circle.dotted")
                        Text(job.phase.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        if job.totalCount > 1 { Text("\(job.finishedCount)/\(job.totalCount)").monospacedDigit().font(.caption) }
                    }
                    if job.totalSteps > 0 && job.phase == .running {
                        ProgressView(value: Double(min(job.step, job.totalSteps)), total: Double(job.totalSteps)).tint(.white)
                        Text("采样 \(job.step) / \(job.totalSteps)").font(.caption).monospacedDigit()
                    }
                    if !job.message.isEmpty { Text(job.message).font(.footnote).fixedSize(horizontal: false, vertical: true) }
                    if [.waiting, .attention].contains(job.phase) { Button("继续核对任务") { state.resume(job.id) }.font(.subheadline.weight(.semibold)) }
                    if !job.phase.isTerminal { Button("取消任务", role: .destructive) { state.cancel(job.id) }.font(.footnote) }
                    if job.phase == .success { Text(state.visibleAssets.contains { $0.jobID == job.id && $0.id == state.saved.backgroundAssetID } ? "图片已回复在下方，也已成为背景。右滑清屏看图，左滑恢复聊天；点图片可保存或分享。" : "任务已完成。点“作品”查看结果；若没有作品，请检查工作流是否包含保存或展示输出的节点。").font(.footnote).foregroundColor(.white.opacity(0.8)) }
                }
            }.frame(maxWidth: 300, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(state.galleryAssets.filter { $0.jobID == job.id }.sorted { $0.createdAt < $1.createdAt }) { asset in
                ConversationResultBubble(asset: asset) { promptFocused = false; resultAsset = asset }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                if state.saved.workflows.isEmpty { Button("导入工作流", action: importAction) }
                ForEach(state.saved.workflows) { workflow in Button(workflow.name) { state.selectWorkflow(workflow.id) } }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.backgroundImage == nil ? "浮屿 · 私人画廊" : "当前作品").font(.caption).foregroundColor(Palette.muted)
                    HStack(spacing: 8) {
                        Text(state.selectedWorkflow?.name ?? "让灵感浮现")
                            .font(.custom("STSongti-SC-Regular", size: 25, relativeTo: .title2)).lineLimit(2).multilineTextAlignment(.leading)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Button { queue = true } label: {
                GlassPanel(padding: 0, cornerRadius: 22, light: true) {
                    HStack(spacing: 4) { Image(systemName: "tray"); if !state.activeJobs.isEmpty { Text("\(state.activeJobs.count)").font(.caption).monospacedDigit() } }.frame(minWidth: 44, minHeight: 44)
                }
            }.accessibilityLabel("查看任务队列")
        }.foregroundColor(Palette.lake)
    }

    private var galleryActions: some View {
        HStack(spacing: 12) {
            Button { parameters = true } label: { Label("工作流参数", systemImage: "slider.horizontal.3").font(.subheadline) }
                .accessibilityLabel("参数").accessibilityHint("打开工作流参数，支持草稿与全部节点")
            Spacer(minLength: 0)
            if state.backgroundImage != nil {
                Button { promptFocused = false; chatVisible.toggle() } label: {
                    Image(systemName: chatVisible ? "photo" : "bubble.left.and.bubble.right").frame(width: 44, height: 44)
                }.accessibilityLabel(chatVisible ? "回到画廊" : "查看对话")
                Button(action: showArtwork) { Label("全屏看图", systemImage: "arrow.up.left.and.arrow.down.right").font(.subheadline).lineLimit(2).frame(minHeight: 44) }.accessibilityLabel("全屏看图")
            }
        }.frame(minHeight: 44).foregroundColor(Palette.lake)
    }

    private var welcome: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "sparkles").font(.system(size: 30, weight: .light))
                Text("你的工作流，\n随手就能用。").font(.system(.largeTitle, design: .rounded).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("连接自己的 ComfyUI，导入 API 工作流。模型在电脑上运行，作品在这里呈现。").font(.body).lineSpacing(4)
                Button(action: state.selectedServer == nil ? settingsAction : importAction) {
                    Text(state.selectedServer == nil ? "连接 ComfyUI" : "导入工作流").font(.headline).padding(.horizontal, 18).frame(minHeight: 46).background(Color.white, in: Capsule()).foregroundColor(Color.black)
                }
                Text("支持 iOS 15。切到后台后，电脑仍可继续生成；回到 App 时检查结果。").font(.footnote).foregroundColor(.white.opacity(0.8))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func showArtwork() {
        promptFocused = false
        let images = state.visibleAssets.filter { $0.output.kind == .image && $0.localName != nil }
        let candidates = images.filter { $0.id == state.saved.backgroundAssetID } + images.filter { $0.id != state.saved.backgroundAssetID }
        for asset in candidates {
            if let name = asset.localName, let url = state.disk?.mediaURL(name), let image = MediaImages.image(url: url, maxPixel: 4096) {
                artwork = ArtworkPresentation(image: image, title: state.job(asset.jobID)?.workflow.name ?? "作品", fileURL: url)
                return
            }
        }
    }

    private func finishPromptEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        promptFocused = false
    }

    private func sendPrompt() {
        finishPromptEditing()
        if state.enqueue(clearPrompt: true) {
            promptFocused = false
            promptHeight = 44
        }
    }

    private var composer: some View {
        GlassPanel(padding: 8, cornerRadius: 28, light: true) {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { notes = true } label: { Label("提示词库", systemImage: "text.book.closed") }
                    ForEach((state.selectedWorkflow?.inputs ?? []).filter { [.image, .video].contains($0.kind) }) { spec in
                        Button { pickerWorkflowID = state.saved.selectedWorkflowID; picker = spec } label: {
                            Label(state.draftUploads[spec.id] == nil ? "选择\(spec.label)" : "更换\(spec.label)", systemImage: spec.kind == .video ? "video.badge.plus" : "photo.badge.plus")
                        }
                    }
                    if state.backgroundImage != nil {
                        Button(action: showArtwork) { Label("全屏查看生成图", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                    Button { canvas.setCleared(true) } label: { Label("右滑清屏", systemImage: "arrow.right.to.line") }
                    if promptFocused {
                        Button { promptFocused = false } label: { Label("收起键盘", systemImage: "keyboard.chevron.compact.down") }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 21, weight: .regular)).frame(width: 44, height: 44)
                }.accessibilityLabel("输入工具").accessibilityHint("素材、提示词库与清屏操作")
                if let spec = promptSpec {
                    PromptTextView(text: Binding(get: { state.value(spec).text }, set: { state.setValue(spec, text: $0) }), focused: $promptFocused, maximumLines: promptFocused ? 4 : 2, light: true, heightChanged: { promptHeight = $0 })
                        .frame(height: promptHeight).id(state.saved.selectedWorkflowID)
                        .overlay(alignment: .topLeading) {
                            if state.value(spec).text.isEmpty {
                                Text("描述你想生成的画面…").font(.body).foregroundColor(Palette.muted.opacity(0.8)).padding(.top, 10)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                } else {
                    Text(state.selectedWorkflow == nil ? "先连接并导入工作流" : "无需提示词，可直接生成")
                        .font(.subheadline).foregroundColor(Palette.muted).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Button {
                    finishPromptEditing()
                    if state.selectedWorkflow?.hasRayQueue == true && plannedTaskCount > 1 { confirmQueue = true }
                    else { sendPrompt() }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 21, weight: .semibold)).frame(width: 44, height: 44).background(Palette.actionFill, in: Circle()).foregroundColor(.white)
                }.disabled(state.selectedWorkflow == nil || state.selectedServer == nil || !state.storageReady).opacity(state.selectedWorkflow == nil ? 0.5 : 1).accessibilityLabel("生成 \(plannedTaskCount) 份")
                    .confirmationDialog("确认提交 \(plannedTaskCount) 个独立任务？", isPresented: $confirmQueue, titleVisibility: .visible) {
                        Button("提交 \(plannedTaskCount) 个任务") { sendPrompt() }
                        Button("取消", role: .cancel) {}
                    } message: { Text("按应用参数中选定的队列范围和每条份数执行，计算在你的服务器上进行。") }
            }
        }.shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }
}
