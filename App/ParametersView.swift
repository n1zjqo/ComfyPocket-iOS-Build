import SwiftUI
import ComfyCore

struct ParametersView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            Group {
                if let workflow = state.selectedWorkflow {
                    WorkflowParametersPage(workflowID: workflow.id)
                } else {
                    Text("先在工作流页面导入一份 API JSON。")
                        .navigationTitle("工作流参数").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                }
            }
        }.navigationViewStyle(.stack).tint(Palette.accent)
    }
}


struct JobsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("手机切后台后可能暂停查询，电脑仍可继续生成。继续核对不会盲目重新提交。")) {
                    ForEach(state.saved.jobs.sorted { $0.createdAt > $1.createdAt }) { job in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Text(job.workflow.name).font(.headline); Spacer(); Text(job.phase.title).font(.caption).foregroundColor(.secondary) }
                            Text(job.prompt).font(.subheadline).lineLimit(3)
                            Text("\(job.server.name) · \(job.finishedCount)/\(job.totalCount)").font(.caption).foregroundColor(.secondary)
                            if !job.message.isEmpty { Text(job.message).font(.footnote).foregroundColor(.secondary) }
                            HStack(spacing: 24) {
                                if [.waiting, .attention].contains(job.phase) { Button("继续核对") { state.resume(job.id) }.buttonStyle(.borderless) }
                                if ![.success, .cancelled].contains(job.phase) { Button("取消", role: .destructive) { state.cancel(job.id) }.buttonStyle(.borderless) }
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            .overlay { if state.saved.jobs.isEmpty { QuietEmpty(icon: "tray", title: "还没有任务", detail: "提交一次生成后，可以在这里检查进度和恢复未完成任务。") } }
            .navigationTitle("任务")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }
}
