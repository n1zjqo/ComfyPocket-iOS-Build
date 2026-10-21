import SwiftUI
import ComfyCore

struct WorkflowApplicationSections: View {
    let workflowID: UUID
    var body: some View {
        Section(header: Text("工作流应用"), footer: Text("参数编辑使用独立草稿；应用后生效，取消不覆盖。连线只读，原始 API 图完整保留。")) {
            NavigationLink(destination: WorkflowParametersPage(workflowID: workflowID)) { Label("工作流参数", systemImage: "slider.horizontal.3") }
            NavigationLink(destination: WorkflowOverviewView(workflowID: workflowID)) { Label("查看流程概览", systemImage: "point.3.connected.trianglepath.dotted") }
            NavigationLink(destination: ApplicationEditorView(workflowID: workflowID)) { Label("配置应用表单", systemImage: "pencil.and.outline") }
        }
    }
}

struct ApplicationEditorView: View {
    @EnvironmentObject var state: AppState
    let workflowID: UUID
    private var workflow: Workflow? { state.saved.workflows.first { $0.id == workflowID } }
    var body: some View {
        List {
            Section(footer: Text("编辑名称、分组和说明；右上角“编辑”可排序。不放在常用区的字段仍可从高级参数访问。")) {
                if let workflow = workflow {
                    ForEach(workflow.applicationInputs) { spec in
                        NavigationLink(destination: ApplicationFieldEditor(workflowID: workflowID, spec: spec)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workflow.applicationField(spec).title)
                                Text("\(workflow.applicationField(spec).group) · 节点 \(spec.nodeID) · \(spec.field)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }.onMove { from, to in state.moveApplicationFields(workflowID: workflowID, from: from, to: to) }
                }
            }
        }.navigationTitle("配置应用表单").navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
    }
}

struct ApplicationFieldEditor: View {
    @EnvironmentObject var state: AppState
    let workflowID: UUID
    let spec: InputSpec
    private var workflow: Workflow? { state.saved.workflows.first { $0.id == workflowID } }
    private func text(_ keyPath: WritableKeyPath<ApplicationField, String>) -> Binding<String> {
        Binding(get: { workflow?.applicationField(spec)[keyPath: keyPath] ?? "" }, set: { value in state.configureField(spec, workflowID: workflowID) { $0[keyPath: keyPath] = value } })
    }
    var body: some View {
        Form {
            Section(header: Text("页面展示")) {
                TextField("显示名称", text: text(\.title))
                TextField("分组名称", text: text(\.group))
                TextField("填写说明", text: text(\.help))
                Toggle("放在常用区", isOn: Binding(get: { workflow?.applicationField(spec).featured ?? true }, set: { value in state.configureField(spec, workflowID: workflowID) { $0.featured = value } }))
            }
            if spec.defaultValue.string != nil, ![.image, .video].contains(spec.kind) {
                Section(header: Text("文字输入方式"), footer: Text("主提示词会同步到生成页聊天输入框；其余文字仍可在应用表单编辑。")) {
                    Picker("组件", selection: Binding(get: { workflow?.applicationField(spec).kind ?? spec.kind }, set: { value in state.configureField(spec, workflowID: workflowID) { $0.kind = value } })) {
                        Text("单行文字").tag(InputKind.text)
                        Text("多行提示词").tag(InputKind.prompt)
                        if !spec.choices.isEmpty { Text("服务器选项").tag(spec.kind == .model ? InputKind.model : InputKind.choice) }
                    }
                    Button(workflow?.mainPrompt?.id == spec.id ? "当前主提示词" : "作为生成页主提示词") {
                        guard let index = state.saved.workflows.firstIndex(where: { $0.id == workflowID }) else { return }
                        state.configureField(spec, workflowID: workflowID) { $0.kind = .prompt }
                        state.saved.workflows[index].mainPromptID = spec.id
                        state.persistSoon()
                    }
                }
            }
            Section(header: Text("原始绑定（只读）")) {
                Text("节点 \(spec.nodeID) · \(spec.classType)")
                Text("字段：\(spec.field)").textSelection(.enabled)
                Text("原始默认值：\(String(spec.defaultValue.text.prefix(300)))").font(.footnote)
            }
        }.navigationTitle("字段设置").navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkflowOverviewView: View {
    @EnvironmentObject var state: AppState
    let workflowID: UUID
    private var workflow: Workflow? { state.saved.workflows.first { $0.id == workflowID } }
    var body: some View {
        List {
            Section(footer: Text("按依赖顺序展示节点与输入来源。这里只读展示，不编辑连线；标量参数在应用表单修改。")) {
                if let workflow = workflow { Text(workflow.name).font(.headline).fixedSize(horizontal: false, vertical: true) }
            }
            if let workflow = workflow {
                ForEach(workflow.orderedNodeIDs, id: \.self) { identifier in
                    DisclosureGroup {
                        Text(workflow.graph[identifier]?["class_type"]?.string ?? "").font(.caption).foregroundColor(.secondary)
                        ForEach((workflow.graph[identifier]?["inputs"]?.object?.keys.sorted()) ?? [], id: \.self) { field in
                            if let value = workflow.graph[identifier]?["inputs"]?[field] {
                                if value.isLink, let source = value.array?.first?.string {
                                    Text("\(field) ← \(workflow.graph[source]?["_meta"]?["title"]?.string ?? source) #\(source) · 输出 \(value.array?[1].text ?? "")").font(.footnote).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    let current = workflow.lastValues[identifier + "|" + field] ?? value
                                    Text("\(field)：\(String(current.text.prefix(120)))").font(.footnote).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workflow.graph[identifier]?["_meta"]?["title"]?.string ?? workflow.graph[identifier]?["class_type"]?.string ?? identifier).fixedSize(horizontal: false, vertical: true)
                            Text("节点 \(identifier)").font(.caption).foregroundColor(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }.navigationTitle("流程概览").navigationBarTitleDisplayMode(.inline)
    }
}
