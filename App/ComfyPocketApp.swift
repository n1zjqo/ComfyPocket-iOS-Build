import SwiftUI

@main
@MainActor
struct ComfyPocketApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    init() { UITextView.appearance().backgroundColor = .clear }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { state.enteredForeground() }
                    else if phase == .background { state.enteredBackground() }
                }
        }
    }
}
struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0
    @StateObject private var canvas = CanvasClearState()
    var body: some View {
        TabView(selection: $tab) {
            GenerationView(settingsAction: { tab = 3 }, importAction: { tab = 1 }, isActive: tab == 0)
                .tabItem { Label("生成", systemImage: "sparkles") }.tag(0)
            WorkflowsView().tabItem { Label("工作流", systemImage: "square.stack.3d.up") }.tag(1)
            GalleryView().tabItem { Label("作品", systemImage: "square.grid.2x2") }.tag(2)
            SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .environmentObject(canvas)
        .statusBar(hidden: tab == 0 && canvas.isCleared)
        .onChange(of: tab) { _ in canvas.setCleared(false) }
        .accentColor(Palette.accent)
        .alert("需要处理", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("知道了") { state.error = nil }
        } message: { Text(state.error ?? "") }
        .overlay(alignment: .top) {
            if let notice = state.notice, !canvas.isCleared {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(notice).font(.subheadline)
                    Button { state.notice = nil } label: { Image(systemName: "xmark").padding(8) }.accessibilityLabel("关闭提示")
                }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 18).padding(.top, 8)
            }
        }
        .onChange(of: state.notice) { value in
            guard value != nil else { return }
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if state.notice == value { state.notice = nil } }
        }
    }
}
