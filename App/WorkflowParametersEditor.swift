import SwiftUI
import UIKit
import ComfyCore

@MainActor
final class ParameterEditSession: ObservableObject {
    @Published var draft: WorkflowParameterDraft
    @Published var batch: Int
    @Published var randomSeed: Bool
    @Published var seedText: String
    @Published var allNodes = false
    @Published var selection: String?
    @Published var loading = false
    @Published var error: String?

    init(workflow: Workflow, batch: Int, randomSeed: Bool, seedText: String) {
        draft = WorkflowParameterDraft(workflow: workflow)
        self.batch = batch
        self.randomSeed = randomSeed
        self.seedText = seedText
    }
    var nodes: [WorkflowParameterNode] { WorkflowParameters.nodes(draft.workflow) }
    var groups: [ParameterNodeGroup] {
        var result: [ParameterNodeGroup] = []
        for node in nodes {
            let key: String
            let title: String
            if node.classType == "RayPromptQueue" { key = "queue"; title = "提示词队列" }
            else if node.classType.lowercased().contains("textencode") || node.fields.contains(where: { $0.spec.kind == .prompt }) { key = "prompts"; title = "提示词" }
            else if node.fields.contains(where: { [.width, .height].contains($0.spec.kind) }) { key = "canvas"; title = "画布" }
            else if node.fields.contains(where: { $0.spec.kind == .model }) { key = "models"; title = "模型与编码器" }
            else { key = "node-" + node.id; title = node.title }
            if let index = result.firstIndex(where: { $0.id == key }) { result[index].nodeIDs.append(node.id) }
            else { result.append(ParameterNodeGroup(id: key, title: title, nodeIDs: [node.id])) }
        }
        return result
    }
    var selectedNodes: [WorkflowParameterNode] {
        if allNodes { return nodes.filter { $0.id == (selection ?? nodes.first?.id) } }
        let group = groups.first { $0.id == selection } ?? groups.first
        return nodes.filter { group?.nodeIDs.contains($0.id) == true }
    }
    func value(_ parameter: WorkflowParameter) -> JSONValue { draft.values[parameter.id] ?? parameter.rawValue }
    func text(_ parameter: WorkflowParameter) -> Binding<String> {
        Binding(get: { self.value(parameter).text }, set: { self.draft.values[parameter.id] = .string($0) })
    }
}

struct ParameterNodeGroup: Identifiable {
    let id: String
    let title: String
    var nodeIDs: [String]
}

struct WorkflowParametersPage: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let workflowID: UUID
    @State private var session: ParameterEditSession?

    var body: some View {
        Group {
            if let session = session {
                ParameterEditorContent(session: session)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("应用") {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                do {
                                    try state.commitParameters(session.draft, batch: session.batch, randomSeed: session.randomSeed, seedText: session.seedText)
                                    dismiss()
                                } catch { session.error = error.localizedDescription }
                            }.disabled(session.loading).accessibilityIdentifier("apply-workflow-parameters")
                        }
                    }
            } else { ProgressView("读取工作流") }
        }
        .navigationTitle("工作流参数").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .onAppear {
            guard session == nil, let workflow = state.saved.workflows.first(where: { $0.id == workflowID }) else { return }
            let current = state.saved.selectedWorkflowID == workflow.id
            let seedSpec = workflow.editableInputs.first { $0.kind == .seed }
            let originalSeed = seedSpec.map { (workflow.lastValues[$0.id] ?? $0.defaultValue).text } ?? "1"
            session = ParameterEditSession(workflow: workflow, batch: current ? state.batch : 1, randomSeed: current ? state.randomSeed : true, seedText: current ? state.seedText : originalSeed)
        }
    }
}

struct ParameterEditorContent: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: ParameterEditSession
    private var workflow: Workflow { session.draft.workflow }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workflow.name).font(.headline).fixedSize(horizontal: false, vertical: true).lineLimit(2)
                    Text("修改保留为草稿，应用后用于下一次生成。连线只读。")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("流程视图", selection: $session.allNodes) {
                        Text("简化流程").tag(false)
                        Text("全部节点 · \(session.nodes.count)").tag(true)
                    }.pickerStyle(.segmented).onChange(of: session.allNodes) { _ in session.selection = nil }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if session.allNodes {
                            ForEach(session.nodes) { node in
                                selector(id: node.id, title: node.title, detail: "节点 \(node.id) · \(node.classType)", first: session.nodes.first?.id)
                            }
                        } else {
                            ForEach(session.groups) { group in
                                selector(id: group.id, title: group.title, detail: "节点 " + group.nodeIDs.joined(separator: "、"), first: session.groups.first?.id)
                            }
                        }
                    }
                }.frame(height: min(geometry.size.height * 0.27, 210)).background(Palette.fog)
                Divider()
                Form {
                    ForEach(session.selectedNodes) { node in
                        Section(header: Text(node.title + " · #" + node.id), footer: Text(node.classType)) {
                            ForEach(node.fields) { parameter in
                                ParameterDraftField(parameter: parameter, session: session)
                            }
                            if node.fields.allSatisfy({ $0.readOnlyReason != nil }) {
                                Text("此节点没有可手填的标量参数；输入来源和输出端口如下，原图保持不变。")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                            if !node.outputs.isEmpty {
                                DisclosureGroup("输出端口（非可选参数）") {
                                    ForEach(Array(node.outputs.enumerated()), id: \.offset) { output in Text(output.element).font(.caption).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                    if !workflow.loraNodes.isEmpty {
                        Section(header: Text("LoRA")) {
                            ForEach(workflow.loraNodes.map { $0.id }, id: \.self) { identifier in
                                Toggle(workflow.loraNodes.first { $0.id == identifier }?.title ?? identifier, isOn: Binding(get: { workflow.loraEnabled[identifier] ?? true }, set: { session.draft.workflow.loraEnabled[identifier] = $0 }))
                            }
                        }
                    }
                    Section(header: Text("手机端执行策略"), footer: Text("统一种子：随机或固定，同一任务各阶段共用，每个任务递增。保留各节点种子：分别使用节点整数值并随任务递增，不受上方随机开关影响。Ray 队列仅支持统一种子。")) {
                        Picker("种子策略", selection: Binding(get: { workflow.seedStrategy ?? .synchronized }, set: { session.draft.workflow.seedStrategy = $0 })) {
                            ForEach(WorkflowSeedStrategy.allCases, id: \.self) { strategy in Text(strategy.title).tag(strategy) }
                        }
                        if state.saved.selectedWorkflowID == workflow.id {
                            Stepper("每条生成 \(session.batch) 份", value: $session.batch, in: 1...8)
                            if workflow.seedStrategy != .perNode {
                                Toggle("随机种子", isOn: $session.randomSeed)
                                if !session.randomSeed { TextField("统一种子", text: $session.seedText).keyboardType(.numberPad).frame(minHeight: 44).accessibilityIdentifier("unified-seed") }
                            }
                        }
                        if workflow.hasRayQueue {
                            Picker("队列执行方式", selection: Binding(get: { workflow.queueMode ?? .single }, set: { session.draft.workflow.queueMode = $0 })) {
                                ForEach(QueueExecutionMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                            }
                            Text("Ray 在手机端展开成独立 API 图；不运行网页扩展。最多提交 64 个任务。")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    Section(footer: Text(workflow.nodeSchemas == nil ? "尚无服务器能力：已知节点使用兼容编辑器（尺寸 64–8192，按 16 对齐），未知节点原样保留只读。联网刷新后获取自定义标量字段、模型选项和真实上下限。" : "约束来自所选服务器。结构化类型、强制连接、缺少描述的字段保持只读；未导入的可选字段不自动添加。尺寸遵循服务器约束，不再自动向下对齐。")) {
                        Button {
                            session.loading = true
                            Task {
                                defer { session.loading = false }
                                do {
                                    let capabilities = try await state.parameterCapabilities()
                                    session.draft.refresh(objectInfo: capabilities.info, serverID: capabilities.serverID, serverAddress: capabilities.serverAddress)
                                } catch { session.error = error.localizedDescription }
                            }
                        } label: {
                            HStack { Text("从服务器刷新节点能力"); Spacer(); if session.loading { ProgressView() } }
                        }.disabled(session.loading)
                    }
                }
            }.background(Palette.fog)
        }
        .alert("参数未应用", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("继续编辑", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    private func selector(id: String, title: String, detail: String, first: String?) -> some View {
        let selected = (session.selection ?? first) == id
        return Button { session.selection = id } label: {
            HStack(spacing: 12) {
                Rectangle().fill(selected ? Palette.accent : Color.clear).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "circle.inset.filled" : "circle").foregroundColor(selected ? Palette.accent : .secondary)
            }.padding(.horizontal, 16).padding(.vertical, 7).frame(minHeight: 44)
                .background(selected ? Palette.accent.opacity(0.08) : Color.clear)
        }.buttonStyle(.plain).accessibilityIdentifier("parameter-node-" + id)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ParameterDraftField: View {
    let parameter: WorkflowParameter
    @ObservedObject var session: ParameterEditSession
    private var spec: InputSpec { parameter.spec }
    private var title: String { session.draft.workflow.applicationField(spec).title }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            if let reason = parameter.readOnlyReason {
                if let connection = parameter.connection { Label(connection, systemImage: "link").font(.callout).textSelection(.enabled) }
                else if parameter.rawValue.object == nil && parameter.rawValue.array == nil { Text(parameter.rawValue.text).font(.callout).textSelection(.enabled) }
                Text(reason).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let priorValue = session.draft.values[parameter.id], priorValue != parameter.rawValue {
                    Button("清除旧覆盖，保留原图值") { session.draft.values[parameter.id] = nil }.font(.footnote)
                }
            } else if spec.kind == .seed && session.draft.workflow.seedStrategy != .perNode {
                Text("原节点种子：" + session.value(parameter).text).font(.callout).textSelection(.enabled)
                Text("当前使用统一种子。若要分别编辑各阶段种子，请在下方切换为“保留各节点种子”。").font(.caption).foregroundColor(.secondary)
            } else if [.image, .video].contains(spec.kind) {
                Text("在生成页选择或更换素材。当前：" + session.value(parameter).text).font(.footnote).foregroundColor(.secondary)
            } else if spec.kind == .boolean {
                Toggle(title, isOn: Binding(get: { session.value(parameter).bool ?? false }, set: { session.draft.values[parameter.id] = .bool($0) })).labelsHidden().accessibilityLabel(title)
            } else if !parameter.options.isEmpty {
                Picker(title, selection: session.text(parameter)) {
                    let current = session.value(parameter).text
                    if !parameter.options.contains(where: { $0.text == current }) { Text(current + "（不在服务器列表）").tag(current) }
                    ForEach(parameter.options.map { $0.text }, id: \.self) { option in Text(option).tag(option) }
                }.pickerStyle(.menu).accessibilityIdentifier("field-" + parameter.id)
            } else if spec.kind == .prompt {
                TextEditor(text: session.text(parameter)).frame(minHeight: 88, maxHeight: 140).font(.body)
                    .accessibilityLabel(title).accessibilityIdentifier("field-" + parameter.id)
            } else {
                TextField(title, text: session.text(parameter)).textInputAutocapitalization(.never).disableAutocorrection(true)
                    .keyboardType([.integer, .decimal, .seed, .width, .height].contains(spec.kind) ? .numbersAndPunctuation : .default)
                    .frame(minHeight: 44).accessibilityIdentifier("field-" + parameter.id)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("#" + spec.nodeID + " · " + spec.field)
                if let minimum = parameter.configuration?["min"] { Text("最小 " + minimum.text) }
                if let maximum = parameter.configuration?["max"] { Text("最大 " + maximum.text) }
            }.font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(.vertical, 5)
    }
}

