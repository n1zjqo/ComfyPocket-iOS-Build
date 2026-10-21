#if DEBUG
import Foundation
import ComfyCore
import UIKit

enum WorkflowApplicationFixture {
    static func artwork() -> UIImage {
        let size = CGSize(width: 216, height: 384)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.18, green: 0.28, blue: 0.42, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.43, green: 0.68, blue: 0.72, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 216, height: 128))
            UIColor(red: 0.88, green: 0.65, blue: 0.45, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 256, width: 216, height: 128))
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(4)
            context.cgContext.stroke(CGRect(x: 4, y: 4, width: 208, height: 376))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.white]
            ("TOP · 测试画布" as NSString).draw(at: CGPoint(x: 16, y: 20), withAttributes: attributes)
            ("BOTTOM · 完整边界" as NSString).draw(at: CGPoint(x: 16, y: 342), withAttributes: attributes)
        }
    }

    @MainActor
    static func installConversation(in state: AppState) throws {
        guard let store = state.disk, var workflow = state.selectedWorkflow, let server = state.selectedServer, let prompt = workflow.mainPrompt else { throw ComfyError.invalid("测试会话缺少工作流或连接。") }
        let name = "conversation-ui-fixture.png"
        guard let data = artwork().pngData() else { throw ComfyError.invalid("测试画布编码失败。") }
        try data.write(to: store.mediaURL(name))
        let submitted = "代码绘制的测试画布，不是模型生成结果"
        workflow.lastValues[prompt.id] = .string(submitted)
        var job = GenerationJob(server: server, workflow: workflow, values: workflow.lastValues)
        job.prompts = try WorkflowBuilder.build(workflow: workflow, values: job.values, batch: 1, randomSeed: false, baseSeed: 42, loraEnabled: [:])
        guard let built = job.prompts.first else { throw ComfyError.invalid("测试会话没有任务。") }
        let promptID = "conversation-fixture"
        job.records = [PromptRecord(index: built.index, promptID: promptID, attempted: true, completed: true)]
        job.phase = .success
        let outputs: JSONValue = .object([
            "image": .object(["images": .array([.object(["filename": .string(name), "type": .string("output")])])]),
            "echo": .object(["text": .string(submitted), "string": .string(submitted)]),
            "negative": .object(["text": .string("负向提示词：模糊，低质量")])
        ])
        let assets = OutputParser.parse(promptID: promptID, outputs: outputs).map { output in
            GalleryAsset(jobID: job.id, remoteKey: output.id, promptID: promptID, output: output, seed: 42, localName: output.kind == .image ? name : nil)
        }
        state.saved.jobs = [job]
        state.saved.assets = assets
        state.saved.backgroundAssetID = assets.first { $0.output.kind == .image }?.id
        if let index = state.saved.workflows.firstIndex(where: { $0.id == workflow.id }) { state.saved.workflows[index].lastValues[prompt.id] = .string("") }
    }

    static func make() throws -> Workflow {
        let graph = #"{"16":{"class_type":"RayPromptQueue","inputs":{"prompts":"雾中的山谷，清晨的自然光\n---\n海边的灯塔，晴朗的天空","format":"用 --- 分隔","first":1,"last":0,"base_seed":123456,"output_folder":"ComfyPocketTests","seed_mode":"每张随机"},"_meta":{"title":"提示词队列"}},"11":{"class_type":"CLIPTextEncode","inputs":{"text":["16",0]}},"14":{"class_type":"CLIPTextEncode","inputs":{"text":"模糊，低质量"},"_meta":{"title":"负面提示词"}},"23":{"class_type":"EmptySD3LatentImage","inputs":{"width":["92",0],"height":["93",0],"batch_size":1}},"26":{"class_type":"KSamplerAdvanced","inputs":{"positive":["11",0],"negative":["14",0],"noise_seed":["16",2],"steps":30,"cfg":4,"sampler_name":"euler","scheduler":"simple","start_at_step":0,"end_at_step":30,"latent_image":["23",0]},"_meta":{"title":"第一段 · Z-Image"}},"28":{"class_type":"KSamplerAdvanced","inputs":{"positive":["11",0],"noise_seed":["16",2],"steps":10,"cfg":1,"start_at_step":6,"end_at_step":1000},"_meta":{"title":"第二段 · Krea2 细化"}},"17":{"class_type":"SaveImage","inputs":{"filename_prefix":["16",1],"images":["28",0]}},"92":{"class_type":"PrimitiveInt","inputs":{"value":2160}},"93":{"class_type":"PrimitiveInt","inputs":{"value":3840}}}"#
        return try WorkflowImporter.parse(Data(graph.utf8), name: "双采文生图 · 4K 应用")
    }
}
#endif
