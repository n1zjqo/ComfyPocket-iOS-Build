import XCTest
import SwiftUI
import ComfyCore
@testable import ComfyPocket

final class LayoutSnapshotTests: XCTestCase {
    @MainActor
    func testDarkAndLargestTextLayouts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyPocket-layout-" + UUID().uuidString, isDirectory: true)
        let state = AppState(store: try DiskStore(rootURL: directory))
        defer {
            state.saveTask?.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let graph = #"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"云层中的小岛，晨光，细腻的水面倒影"}},"2":{"class_type":"LoadImage","inputs":{"image":"reference.png"}},"3":{"class_type":"VHS_LoadVideo","inputs":{"video":"reference.mp4"}},"4":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":768,"batch_size":1}}}"#
        let workflow = try WorkflowImporter.parse(Data(graph.utf8), name: "人像与参考素材工作流")
        let server = ServerProfile()
        state.saved.servers = [server]
        state.saved.selectedServerID = server.id
        state.saved.workflows = [workflow]
        state.saved.selectedWorkflowID = workflow.id
        try await capture(AnyView(RootView()), state: state, category: .large, name: "Dark — image composer with both media inputs")
        try await capture(AnyView(RootView()), state: state, category: .accessibilityExtraExtraExtraLarge, name: "Largest text — composer with both media inputs")
        try await capture(AnyView(ParametersView()), state: state, category: .accessibilityExtraExtraExtraLarge, name: "Largest text — generation parameters")
        try await capture(AnyView(SettingsView()), state: state, category: .accessibilityExtraExtraExtraLarge, name: "Largest text — dark settings")
        try await capture(AnyView(WorkflowsView()), state: state, category: .accessibilityExtraExtraExtraLarge, name: "Largest text — dark workflows")
        try await capture(AnyView(GalleryView()), state: state, category: .accessibilityExtraExtraExtraLarge, name: "Largest text — dark empty gallery")
    }

    @MainActor
    func testWorkflowApplicationEditingPersistenceAndLayouts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyPocket-app-form-" + UUID().uuidString, isDirectory: true)
        let store = try DiskStore(rootURL: directory)
        let state = AppState(store: store)
        defer { state.saveTask?.cancel(); try? FileManager.default.removeItem(at: directory) }
        let workflow = try WorkflowApplicationFixture.make()
        let other = try WorkflowImporter.parse(Data(#"{"1":{"class_type":"PrimitiveInt","inputs":{"value":1}}}"#.utf8), name: "另一个工作流")
        state.saved.workflows = [workflow, other]
        state.selectWorkflow(other.id)
        let width = try XCTUnwrap(workflow.editableInputs.first { $0.kind == .width })
        state.setValue(width, text: "1024", workflowID: workflow.id)
        XCTAssertNil(state.selectedWorkflow?.lastValues[width.id])
        state.configureField(width, workflowID: workflow.id) { $0.title = "成片宽度"; $0.group = "画幅"; $0.order = -1 }
        state.selectWorkflow(workflow.id)
        XCTAssertEqual(state.seedText, "123456")
        XCTAssertEqual(state.value(width), .integer(1024))
        try state.persist()
        let restored = AppState(store: store)
        XCTAssertEqual(restored.selectedWorkflow?.applicationFields?[width.id]?.title, "成片宽度")
        XCTAssertEqual(restored.selectedWorkflow?.mainPrompt?.id, "16|prompts")
        let prompts = try WorkflowBuilder.build(workflow: try XCTUnwrap(restored.selectedWorkflow), values: restored.selectedWorkflow?.lastValues ?? [:], batch: 1, randomSeed: false, baseSeed: 42, loraEnabled: [:])
        XCTAssertEqual(prompts[0].graph["92"]?["inputs"]?["value"], .integer(1024))
        XCTAssertNil(prompts[0].graph["16"])
        try await capture(AnyView(ParametersView()), state: state, category: .large, name: "Workflow application — editable grouped form")
        try await capture(AnyView(ParametersView()), state: state, category: .accessibilityExtraExtraExtraLarge, name: "Workflow application — largest text")
        try await capture(AnyView(NavigationView { WorkflowOverviewView(workflowID: workflow.id) }.navigationViewStyle(.stack)), state: state, category: .large, name: "Workflow application — dependency overview")
        try await capture(AnyView(NavigationView { ApplicationEditorView(workflowID: workflow.id) }.navigationViewStyle(.stack)), state: state, category: .large, name: "Workflow application — field configuration")
    }

    @MainActor
    func testPromptTextViewEditingAndFocus() async throws {
        let fixture = PromptEditorFixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        let controller = UIHostingController(rootView: PromptEditorHost(fixture: fixture))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        let editor = try XCTUnwrap(findEditor(in: controller.view))
        XCTAssertFalse(editor.isOpaque)
        XCTAssertEqual(editor.backgroundColor?.cgColor.alpha ?? 1, 0)
        XCTAssertGreaterThan(editor.font?.pointSize ?? 0, 34)
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(fixture.focused)
        editor.insertText("中文提示词，保留标点\nsecond line")
        XCTAssertEqual(fixture.text, "中文提示词，保留标点\nsecond line")
        fixture.focused = false
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(editor.isFirstResponder)
        fixture.text = "从词库填入的新提示词"
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(editor.text, fixture.text)
    }

    @MainActor
    func testArtworkFitZoomAndRotation() {
        let image = UIImage(systemName: "photo")!
        let view = ArtworkScrollView(image: image, tapped: {})
        view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.minimumZoomScale, 0)
        XCTAssertEqual(view.zoomScale, view.minimumZoomScale, accuracy: 0.001)
        XCTAssertLessThanOrEqual(view.artworkView.frame.width, 375.1)
        XCTAssertLessThanOrEqual(view.artworkView.frame.height, 812.1)
        view.setZoomScale(view.minimumZoomScale * 3, animated: false)
        XCTAssertEqual(view.zoomScale, view.minimumZoomScale * 3, accuracy: 0.001)
        view.frame = CGRect(x: 0, y: 0, width: 812, height: 375)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, view.minimumZoomScale, accuracy: 0.001)
        XCTAssertLessThanOrEqual(view.artworkView.frame.width, 812.1)
        XCTAssertLessThanOrEqual(view.artworkView.frame.height, 375.1)
    }

    func testArtworkGlassFrameGeometry() {
        let portrait = ArtworkGlassGeometry.fittedRect(image: CGSize(width: 900, height: 1600), viewport: CGSize(width: 375, height: 812))
        XCTAssertEqual(portrait.width, 375, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 666.6667, accuracy: 0.001)
        XCTAssertEqual(portrait.midX, 187.5, accuracy: 0.001)
        XCTAssertEqual(portrait.midY, 406, accuracy: 0.001)
        let landscape = ArtworkGlassGeometry.fittedRect(image: CGSize(width: 900, height: 1600), viewport: CGSize(width: 812, height: 375))
        XCTAssertEqual(landscape.width, 210.9375, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 375, accuracy: 0.001)
        XCTAssertEqual(landscape.midX, 406, accuracy: 0.001)
        XCTAssertEqual(landscape.midY, 187.5, accuracy: 0.001)
        XCTAssertEqual(ArtworkGlassGeometry.fittedRect(image: .zero, viewport: CGSize(width: 375, height: 812)), .zero)
        XCTAssertEqual(ArtworkGlassGeometry.fittedRect(image: CGSize(width: 900, height: 1600), viewport: .zero), .zero)
        XCTAssertLessThanOrEqual(ArtworkGlassGeometry.bandWidth(for: portrait.size), 10)
        XCTAssertGreaterThanOrEqual(ArtworkGlassGeometry.bandWidth(for: landscape.size), 4)
        XCTAssertEqual(ArtworkGlassGeometry.cornerRadius(for: portrait.size), 20)
    }

    @MainActor
    func testArtworkGlassFrameSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyPocket-glass-" + UUID().uuidString, isDirectory: true)
        let state = AppState(store: try DiskStore(rootURL: directory))
        defer { state.saveTask?.cancel(); try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { context in
            let colors = [UIColor(red: 0.08, green: 0.18, blue: 0.24, alpha: 1).cgColor, UIColor(red: 0.30, green: 0.62, blue: 0.62, alpha: 1).cgColor, UIColor(red: 0.83, green: 0.58, blue: 0.34, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.6, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 900), options: [])
            context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
            context.cgContext.setLineWidth(3)
            for index in 0..<24 {
                context.cgContext.move(to: CGPoint(x: CGFloat(index) * 28, y: 0))
                context.cgContext.addLine(to: CGPoint(x: CGFloat(index) * 28 - 160, y: 900))
            }
            context.cgContext.strokePath()
        }
        try await capture(AnyView(CanvasArtwork(image: image, clearProgress: 1).background(Color.black)), state: state, category: .large, name: "Crystal frame — synthetic gradient, clear center and narrow frosted edges")
    }

    @MainActor
    func testPromptEditorCompactAndFocusedHeight() async throws {
        let editor = SizingPromptTextView()
        editor.font = .systemFont(ofSize: 17)
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        editor.frame = CGRect(x: 0, y: 0, width: 220, height: 44)
        editor.maximumLines = 2
        editor.text = String(repeating: "A long prompt with enough words to occupy many lines. ", count: 20)
        var height: CGFloat = 0
        editor.heightChanged = { height = $0 }
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(height, 44)
        XCTAssertLessThanOrEqual(height, 58)
        let compactHeight = height
        editor.maximumLines = 4
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(height, compactHeight)
        XCTAssertLessThanOrEqual(height, 99)
        editor.text = "Short prompt"
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(height, 44)
    }

    func testCanvasSwipeDirectionThresholdAndCancellation() {
        XCTAssertTrue(CanvasSwipeDecision.canBegin(velocity: CGPoint(x: 200, y: 30), cleared: false))
        XCTAssertTrue(CanvasSwipeDecision.canBegin(velocity: CGPoint(x: -200, y: 30), cleared: true))
        XCTAssertFalse(CanvasSwipeDecision.canBegin(velocity: CGPoint(x: 30, y: 200), cleared: false))
        XCTAssertFalse(CanvasSwipeDecision.canBegin(velocity: CGPoint(x: -200, y: 0), cleared: false))
        XCTAssertFalse(CanvasSwipeDecision.canBegin(velocity: CGPoint(x: 200, y: 0), cleared: true))
        XCTAssertEqual(CanvasSwipeDecision.progress(translation: 150, width: 375, cleared: false), 0.4, accuracy: 0.001)
        XCTAssertEqual(CanvasSwipeDecision.progress(translation: -150, width: 375, cleared: true), 0.6, accuracy: 0.001)
        XCTAssertEqual(CanvasSwipeDecision.progress(translation: 800, width: 375, cleared: false), 1)
        XCTAssertEqual(CanvasSwipeDecision.progress(translation: -800, width: 375, cleared: true), 0)
        XCTAssertFalse(CanvasSwipeDecision.destination(progress: 0.2, velocity: 0, width: 375, cleared: false, cancelled: false))
        XCTAssertTrue(CanvasSwipeDecision.destination(progress: 0.4, velocity: 0, width: 375, cleared: false, cancelled: false))
        XCTAssertTrue(CanvasSwipeDecision.destination(progress: 0.1, velocity: 900, width: 375, cleared: false, cancelled: false))
        XCTAssertFalse(CanvasSwipeDecision.destination(progress: 0.6, velocity: 0, width: 375, cleared: true, cancelled: false))
        XCTAssertFalse(CanvasSwipeDecision.destination(progress: 0.9, velocity: 0, width: 375, cleared: false, cancelled: true))
        XCTAssertTrue(CanvasSwipeDecision.destination(progress: 0.1, velocity: 0, width: 375, cleared: true, cancelled: true))
    }

    @MainActor
    func testCanvasClearStateRestoresAndCancels() {
        let canvas = CanvasClearState()
        canvas.updateViewport(width: 812)
        XCTAssertEqual(canvas.viewportWidth, 812)
        canvas.updateViewport(width: 0)
        XCTAssertEqual(canvas.viewportWidth, 812)
        canvas.updateViewport(width: 375)
        XCTAssertEqual(canvas.viewportWidth, 375)
        canvas.begin()
        canvas.drag(translation: 180, width: 375)
        XCTAssertTrue(canvas.isDragging)
        XCTAssertFalse(canvas.isCleared)
        XCTAssertEqual(canvas.progress, 0.48, accuracy: 0.001)
        canvas.finish(velocity: 0, width: 375, cancelled: true)
        XCTAssertFalse(canvas.isCleared)
        XCTAssertEqual(canvas.progress, 0)
        canvas.setCleared(true)
        canvas.begin()
        canvas.drag(translation: -180, width: 375)
        canvas.finish(velocity: 0, width: 375, cancelled: false)
        XCTAssertFalse(canvas.isCleared)
        XCTAssertFalse(canvas.isDragging)
        XCTAssertEqual(canvas.progress, 0)
    }

    @MainActor
    func testAccentAndActionContrast() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertGreaterThanOrEqual(contrast(UIColor(Palette.accent).resolvedColor(with: dark), UIColor(Palette.fog).resolvedColor(with: dark)), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(UIColor(Palette.accent).resolvedColor(with: light), .white), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(UIColor(Palette.actionFill).resolvedColor(with: dark), .white), 4.5)
    }

    private func contrast(_ foreground: UIColor, _ background: UIColor) -> Double {
        let first = luminance(foreground)
        let second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let components = [red, green, blue].map { component -> Double in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }

    @MainActor
    private func findEditor(in view: UIView) -> UITextView? {
        if let editor = view as? UITextView { return editor }
        for child in view.subviews {
            if let editor = findEditor(in: child) { return editor }
        }
        return nil
    }

    @MainActor
    private func capture(_ view: AnyView, state: AppState, category: ContentSizeCategory, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view.environmentObject(state).environment(\.sizeCategory, category).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, 375)
        XCTAssertEqual(image.size.height, 812)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class PromptEditorFixture: ObservableObject {
    @Published var text = ""
    @Published var focused = false
}

private struct PromptEditorHost: View {
    @ObservedObject var fixture: PromptEditorFixture
    var body: some View {
        PromptTextView(text: $fixture.text, focused: $fixture.focused)
            .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
            .frame(height: 105)
    }
}
