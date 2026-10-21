import XCTest
@testable import ComfyCore

final class WorkflowApplicationTests: XCTestCase {
    private static let graph = #"{"16":{"class_type":"RayPromptQueue","inputs":{"prompts":"first line\nsecond line\n---\n第二条\n---\nthird","format":"用 --- 分隔","first":1,"last":0,"base_seed":123456,"output_folder":"NAS/资产库","seed_mode":"每张随机"}},"11":{"class_type":"CLIPTextEncode","inputs":{"text":["16",0]}},"14":{"class_type":"CLIPTextEncode","inputs":{"text":""},"_meta":{"title":"负面提示词"}},"23":{"class_type":"EmptySD3LatentImage","inputs":{"width":["92",0],"height":["93",0],"batch_size":1}},"26":{"class_type":"KSamplerAdvanced","inputs":{"positive":["11",0],"negative":["14",0],"noise_seed":["16",2],"steps":30,"cfg":4,"latent_image":["23",0]},"_meta":{"title":"第一段 · Z-Image"}},"28":{"class_type":"KSamplerAdvanced","inputs":{"positive":["11",0],"noise_seed":["16",2],"steps":10,"cfg":1},"_meta":{"title":"第二段 · Krea2"}},"17":{"class_type":"SaveImage","inputs":{"filename_prefix":["16",1],"images":["28",0]}},"92":{"class_type":"PrimitiveInt","inputs":{"value":2160}},"93":{"class_type":"PrimitiveInt","inputs":{"value":3840}}}"#

    private func workflow() throws -> Workflow { try WorkflowImporter.parse(Data(Self.graph.utf8), name: "双采 4K") }

    func testFullDualStageFixtureRetainsEveryNonQueueLink() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DualStage4K", withExtension: "json"))
        let workflow = try WorkflowImporter.parse(Data(contentsOf: url), name: "完整双采拓扑")
        XCTAssertEqual(workflow.graph.count, 26)
        XCTAssertEqual(workflow.mainPrompt?.id, "16|prompts")
        let built = try WorkflowBuilder.build(workflow: workflow, values: ["92|value": .integer(1080), "26|steps": .integer(24)], batch: 1, randomSeed: false, baseSeed: 42, loraEnabled: [:])
        XCTAssertEqual(built[0].graph.object?.count, 25)
        XCTAssertEqual(built[0].graph["92"]?["inputs"]?["value"], .integer(1072))
        XCTAssertEqual(built[0].graph["26"]?["inputs"]?["steps"], .integer(24))
        XCTAssertEqual(built[0].graph["9"]?["inputs"]?["text"], .string("测试提示词一"))
        XCTAssertEqual(built[0].graph["11"]?["inputs"]?["text"], .string("测试提示词一"))
        XCTAssertEqual(built[0].graph["13"]?["inputs"]?["anything"], .string("测试提示词一"))
        for (identifier, node) in workflow.graph where identifier != "16" {
            for (field, value) in node["inputs"]?.object ?? [:] where value.isLink && value.array?.first?.string != "16" {
                XCTAssertEqual(built[0].graph[identifier]?["inputs"]?[field], value)
            }
        }
    }

    func testUpstreamPromptDimensionsAndStageGrouping() throws {
        let workflow = try workflow()
        XCTAssertEqual(workflow.mainPrompt?.id, "16|prompts")
        XCTAssertEqual(workflow.inputs.first { $0.id == "92|value" }?.kind, .width)
        XCTAssertEqual(workflow.inputs.first { $0.id == "93|value" }?.kind, .height)
        XCTAssertEqual(workflow.inputs.first { $0.id == "14|text" }?.label, "负向提示词")
        let first = try XCTUnwrap(workflow.inputs.first { $0.id == "26|steps" })
        let second = try XCTUnwrap(workflow.inputs.first { $0.id == "28|steps" })
        XCTAssertNotEqual(workflow.applicationField(first).group, workflow.applicationField(second).group)
        XCTAssertTrue(workflow.applicationField(first).featured)
        XCTAssertLessThan(try XCTUnwrap(workflow.orderedNodeIDs.firstIndex(of: "92")), try XCTUnwrap(workflow.orderedNodeIDs.firstIndex(of: "23")))
    }

    func testSingleQueueMaterializesAllThreeOutputsAndPreservesSource() throws {
        let workflow = try workflow()
        let built = try WorkflowBuilder.build(workflow: workflow, values: ["92|value": .integer(1024)], batch: 1, randomSeed: false, baseSeed: 42, loraEnabled: [:])
        XCTAssertEqual(built.count, 1)
        XCTAssertNil(built[0].graph["16"])
        XCTAssertEqual(built[0].graph["11"]?["inputs"]?["text"], .string("first line\nsecond line"))
        XCTAssertEqual(built[0].graph["26"]?["inputs"]?["noise_seed"], .unsigned(42))
        XCTAssertEqual(built[0].graph["28"]?["inputs"]?["noise_seed"], .unsigned(42))
        XCTAssertEqual(built[0].graph["17"]?["inputs"]?["filename_prefix"], .string("NAS/资产库/ComfyPocket_0001_42"))
        XCTAssertEqual(built[0].graph["92"]?["inputs"]?["value"], .integer(1024))
        XCTAssertEqual(built[0].graph["23"]?["inputs"]?["width"], .array([.string("92"), .integer(0)]))
        XCTAssertEqual(built[0].graph["28"]?["inputs"]?["steps"], .integer(10))
        XCTAssertNotNil(workflow.graph["16"])
    }

    func testQueueRangeRepeatsAndPromptMetadata() throws {
        var workflow = try workflow()
        workflow.queueMode = .all
        let values: [String: JSONValue] = ["16|first": .integer(2), "16|last": .integer(3)]
        let built = try WorkflowBuilder.build(workflow: workflow, values: values, batch: 2, randomSeed: false, baseSeed: 9, loraEnabled: [:])
        XCTAssertEqual(built.map { $0.seed }, [9, 10, 11, 12])
        XCTAssertEqual(built.map { $0.promptText ?? "" }, ["第二条", "第二条", "third", "third"])
        XCTAssertEqual(built.map { $0.index }, [1, 2, 3, 4])
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: workflow, values: values, batch: 2, randomSeed: false, baseSeed: UInt64.max - 1, loraEnabled: [:]))
    }

    func testQueueInvalidRangeUnknownFormatAndUnsafeFolderRejected() throws {
        let workflow = try workflow()
        for values: [String: JSONValue] in [["16|first": .integer(0)], ["16|last": .integer(99)], ["16|first": .integer(3), "16|last": .integer(1)], ["16|format": .string("unknown")], ["16|output_folder": .string("../escape")], ["16|prompts": .string("\n---\n")]] {
            XCTAssertThrowsError(try RayQueue.selection(workflow: workflow, values: values))
        }
        var many = workflow
        many.queueMode = .all
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: many, values: ["16|prompts": .string(Array(repeating: "one", count: 65).joined(separator: "\n---\n"))], batch: 1, randomSeed: false, baseSeed: 1, loraEnabled: [:]))
    }

    func testApplicationConfigurationAndOldSnapshotMigration() throws {
        var workflow = try workflow()
        workflow.applicationFields = ["26|steps": ApplicationField(title: "初步采样", group: "第一阶段", help: "控制细节", featured: true, order: -10000)]
        workflow.mainPromptID = "16|prompts"
        workflow.queueMode = .all
        workflow.lastValues["26|steps"] = .integer(24)
        let data = try JSONEncoder().encode(workflow)
        let restored = try JSONDecoder().decode(Workflow.self, from: data)
        XCTAssertEqual(restored, workflow)
        XCTAssertEqual(restored.applicationInputs.first?.id, "26|steps")
        var old = try JSONDecoder().decode(JSONValue.self, from: data).object!
        old.removeValue(forKey: "applicationFields")
        old.removeValue(forKey: "mainPromptID")
        old.removeValue(forKey: "queueMode")
        let legacy = try JSONDecoder().decode(Workflow.self, from: JSONValue.object(old).encoded())
        let migrated = try WorkflowImporter.reanalyze(legacy)
        XCTAssertEqual(migrated.id, workflow.id)
        XCTAssertEqual(migrated.lastValues["26|steps"], .integer(24))
        XCTAssertEqual(migrated.mainPrompt?.id, "16|prompts")
    }

    func testUnknownQueueOutputRejected() throws {
        var workflow = try workflow()
        workflow.graph["500"] = .object(["class_type": .string("Unknown"), "inputs": .object(["value": .array([.string("16"), .integer(3)])])])
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: workflow, values: [:], batch: 1, randomSeed: false, baseSeed: 1, loraEnabled: [:]))
    }

    func testReanalysisPreservesServerChoiceWidgets() throws {
        let graph = #"{"1":{"class_type":"SamplerSelector","inputs":{"sampler_name":"euler"}}}"#
        var workflow = try WorkflowImporter.parse(Data(graph.utf8), name: "选项")
        workflow.inputs[0].choices = ["euler", "heun"]
        workflow.inputs[0].kind = .choice
        let restored = try WorkflowImporter.reanalyze(workflow)
        XCTAssertEqual(restored.inputs[0].kind, .choice)
        XCTAssertEqual(restored.inputs[0].choices, ["euler", "heun"])
    }
}
