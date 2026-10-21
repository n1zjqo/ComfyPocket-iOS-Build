import SwiftUI
import UniformTypeIdentifiers
import ComfyCore

struct WorkflowsView: View {
    @EnvironmentObject var state: AppState
    @State private var importing = false
    @State private var notes = false
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("已导入"), footer: Text("导入 ComfyUI 的 Export (API) JSON。不会在手机上改节点或连线。正在执行的任务使用自己的工作流快照。")) {
                    ForEach(state.saved.workflows) { workflow in
                        NavigationLink(destination: WorkflowDetailView(workflowID: workflow.id)) {
                            HStack(spacing: 14) {
                                Image(systemName: workflow.outputLabel == "视频" ? "video" : workflow.outputLabel == "文本" ? "text.alignleft" : "square.stack.3d.up").font(.system(size: 20)).foregroundColor(Palette.accent).frame(width: 28)
                                VStack(alignment: .leading, spacing: 5) { Text(workflow.name).font(.headline); Text("\(workflow.outputLabel) · \(workflow.graph.count) 个节点 · \(workflow.inputs.count) 个参数").font(.caption).foregroundColor(.secondary) }
                                Spacer()
                                if state.saved.selectedWorkflowID == workflow.id { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundColor(Palette.accent).accessibilityLabel("当前工作流") }
                            }.padding(.vertical, 7)
                        }
                    }.onDelete { indices in
                        let ids = Set(indices.map { state.saved.workflows[$0].id })
                        state.saved.workflows.removeAll { ids.contains($0.id) }
                        if let selected = state.saved.selectedWorkflowID, ids.contains(selected) { state.saved.selectedWorkflowID = state.saved.workflows.first?.id }
                        state.persistSoon()
                    }
                    Button { importing = true } label: { Label("导入 API 工作流", systemImage: "plus") }.frame(minHeight: 44)
                }
                Section { Button { notes = true } label: { Label("提示词库", systemImage: "text.book.closed") } }
            }
            .navigationTitle("工作流")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入 API 工作流") } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { Task { await state.importWorkflow(from: url) } }
                case .failure(let error): state.report(error)
                }
            }
            .sheet(isPresented: $notes) { PromptLibraryView() }
        }.navigationViewStyle(.stack)
    }
}
struct WorkflowDetailView: View {
    @EnvironmentObject var state: AppState
    let workflowID: UUID
    @State private var sharing = false
    @State private var shareURL: URL?
    var workflow: Workflow? { state.saved.workflows.first { $0.id == workflowID } }
    var body: some View {
        Form {
            if let workflow = workflow {
                Section("名称") {
                    TextField("工作流名称", text: Binding(get: { self.workflow?.name ?? "" }, set: { name in
                        guard let index = state.saved.workflows.firstIndex(where: { $0.id == workflowID }) else { return }
                        state.saved.workflows[index].name = name
                        state.persistSoon()
                    }))
                }
                Section {
                    Button(state.saved.selectedWorkflowID == workflowID ? "当前正在使用" : "设为当前工作流") { state.selectWorkflow(workflowID) }
                    Button("导出原始 API 图") {
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-" + workflowID.uuidString + ".json")
                            try JSONValue.object(workflow.graph).encoded().write(to: url, options: .atomic)
                            shareURL = url
                            sharing = true
                        } catch { state.report(error) }
                    }
                }
                WorkflowApplicationSections(workflowID: workflowID)
            }
        }
        .navigationTitle("工作流详情").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $sharing) { if let url = shareURL { ShareSheet(items: [url]) } }
    }
}

struct PromptLibraryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var select: ((String) -> Void)? = nil
    @State private var adding = false
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        NavigationView {
            List {
                if !state.saved.notes.isEmpty, let select = select {
                    Button("随机用一条") { if let note = state.saved.notes.randomElement() { select(note.text); dismiss() } }
                }
                ForEach(state.saved.notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.title).font(.headline)
                        Text(note.text).font(.subheadline).lineLimit(4).textSelection(.enabled)
                        if let select = select { Button("填入提示词") { select(note.text); dismiss() }.buttonStyle(.borderless) }
                    }.padding(.vertical, 5)
                }.onDelete { offsets in state.saved.notes.remove(atOffsets: offsets); state.persistSoon() }
            }
            .overlay { if state.saved.notes.isEmpty { QuietEmpty(icon: "text.book.closed", title: "留下常用的表达", detail: "添加提示词，或在作品详情中保存生成参数。词条只存在你的设备里。") } }
            .navigationTitle("提示词库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加提示词") }
            }
            .sheet(isPresented: $adding) {
                NavigationView {
                    Form { TextField("名称（可选）", text: $title); TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel("提示词内容") }
                        .navigationTitle("添加提示词").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("保存") { state.saveNote(title: title, text: text); title = ""; text = ""; adding = false }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        }
                }.navigationViewStyle(.stack)
            }
        }.navigationViewStyle(.stack)
    }
}
