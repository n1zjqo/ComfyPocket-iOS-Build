import SwiftUI
import ComfyCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var editor: ServerProfile?
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("ComfyUI 连接"), footer: Text("手机与电脑需能互相访问。电脑启动 ComfyUI 时使用 --listen；地址应是电脑的局域网 IP，不是 localhost。支持反向代理路径前缀和 Basic Auth。")) {
                    ForEach(state.saved.servers) { server in
                        HStack {
                            Button {
                                state.saved.selectedServerID = server.id
                                state.connectionResult = ""
                                state.persistSoon()
                                Task { await state.refreshChoices() }
                            } label: {
                                HStack {
                                    Image(systemName: state.saved.selectedServerID == server.id ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
                                    VStack(alignment: .leading) { Text(server.name); Text(server.address).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { editor = server } label: { Image(systemName: "pencil").font(.system(size: 20)).frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("编辑连接")
                        }
                    }
                    Button { editor = ServerProfile() } label: { Label("添加连接", systemImage: "plus") }
                }
                Section(header: Text("聊天背景"), footer: Text("成功生成的最新图片会自动成为背景。也可在作品详情里选用旧图。毛玻璃仅覆盖文字和按钮，保留画面的完整感。")) {
                    VStack(alignment: .leading) {
                        Text("背景压暗 \(Int(state.saved.backgroundDim * 100))%")
                        Slider(value: Binding(get: { state.saved.backgroundDim }, set: { state.saved.backgroundDim = $0; state.persistSoon() }), in: 0.15...0.75)
                    }
                    Text("开启系统“降低透明度”后，聊天面板会改为不透明背景。").font(.footnote).foregroundColor(.secondary)
                }
                Section(header: Text("本机存储")) {
                    LabeledContent15(title: "作品", value: "\(state.galleryAssets.count) 件")
                    LabeledContent15(title: "媒体占用", value: ByteCountFormatter.string(fromByteCount: state.disk?.usedBytes() ?? 0, countStyle: .file))
                    LabeledContent15(title: "工作流", value: "\(state.saved.workflows.count) 份")
                    Text("文件仅保存在本机，不上传第三方服务。删除 App 会丢失本地资料，请先分享重要作品和导出工作流。").font(.footnote).foregroundColor(.secondary)
                }
                Section(header: Text("使用边界")) {
                    Text("这是一款远程 ComfyUI 客户端，模型和节点运行在你自己的服务器。聊天框用于填写工作流提示词，不是 AI 对话机器人。")
                    Text("切到后台后只提供有限收尾时间，不承诺后台常驻。服务器已接收的任务仍会执行；回到前台后核对队列、历史并下载结果。等待期间请勿清理服务器历史。")
                    Text("只导入 API 格式 JSON。自定义节点必须已安装在服务器；标准 LoRA 可开关，自定义 LoRA 节点的行为由它自身定义。")
                }.font(.footnote)
                Section(header: Text("关于")) {
                    LabeledContent15(title: "Comfy 随行", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    Text("原生 SwiftUI · 最低 iOS 15 · 无需私有权限。TrollStore 仅用于安装，不改变网络或后台限制。").font(.footnote).foregroundColor(.secondary)
                }
            }.navigationTitle("设置")
            .sheet(item: $editor) { ServerEditorView(profile: $0) }
        }.navigationViewStyle(.stack)
    }
}
struct LabeledContent15: View {
    let title: String
    let value: String
    var body: some View { HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing) } }
}

struct ServerEditorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var profile: ServerProfile
    @State private var password = ""
    @State private var loaded = false
    @State private var credentialReady = false
    @State private var editorError: String?
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("地址")) {
                    TextField("连接名称", text: $profile.name)
                    TextField("http://192.168.1.100:8188", text: $profile.address).keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true).accessibilityIdentifier("server-address")
                }
                Section(header: Text("Basic Auth（可选）"), footer: Text("密码只存入系统钥匙串。HTTP 会明文传输网络内容；跨互联网请使用 HTTPS 或可信 VPN，不要直接暴露无认证的 ComfyUI。")) {
                    TextField("用户名", text: $profile.username).textInputAutocapitalization(.never).disableAutocorrection(true)
                    SecureField("密码", text: $password)
                }
                Section(header: Text("运行中任务的取消"), footer: Text("只有确认服务器支持带 prompt_id 的定向中断后才开启。旧版 ComfyUI 可能忽略该参数，误停其他人的任务。默认只移除自己的排队项。")) {
                    Toggle("允许定向中断", isOn: Binding(get: { profile.allowInterrupt ?? false }, set: { profile.allowInterrupt = $0 }))
                }
                Section {
                    Button {
                        Task { await state.testConnection(profile, password: password) }
                    } label: { HStack { Text(state.connecting ? "正在测试…" : "保存并测试连接"); Spacer(); if state.connecting { ProgressView() } } }
                    .disabled(state.connecting || !credentialReady)
                    if !state.connectionResult.isEmpty { Text(state.connectionResult).foregroundColor(.secondary) }
                }
            }.navigationTitle("编辑连接").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(state.connecting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { do { try state.saveServer(profile, password: password); dismiss() } catch { editorError = error.localizedDescription } }.disabled(state.connecting || !credentialReady)
                }
            }
            .alert("连接未保存", isPresented: Binding(get: { editorError != nil }, set: { if !$0 { editorError = nil } })) {
                Button("知道了") { editorError = nil }
            } message: { Text(editorError ?? "") }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                state.connectionResult = ""
                do { password = try PasswordStore.read(id: profile.id); credentialReady = true } catch { editorError = error.localizedDescription }
            }
        }.navigationViewStyle(.stack)
    }
}
