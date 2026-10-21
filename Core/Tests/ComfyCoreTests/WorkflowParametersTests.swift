import XCTest
@testable import ComfyCore

final class WorkflowParametersTests: XCTestCase {
    private func workflow() throws -> Workflow {
        let data = Data(#"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"cat"}},"2":{"class_type":"CLIPTextEncode","inputs":{"text":"blur"}},"3":{"class_type":"KSampler","inputs":{"positive":["1",0],"negative":["2",0],"seed":18446744073709551614,"steps":20,"sampler_name":"euler"}},"4":{"class_type":"KSampler","inputs":{"positive":["1",0],"negative":["2",0],"seed":101,"steps":8,"sampler_name":"euler"}},"5":{"class_type":"VAEDecode","inputs":{"samples":["4",0]}},"6":{"class_type":"Custom","inputs":{"gain":0.5,"payload":{"arbitrary":[1,2,3]},"mode":2}},"7":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512,"batch_size":1}}}"#.utf8)
        return try WorkflowImporter.parse(data, name: "dual")
    }
    private var info: JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"CLIPTextEncode":{"input":{"required":{"text":["STRING",{"multiline":true}]}},"output":["CONDITIONING"],"output_name":["条件"]},"KSampler":{"input":{"required":{"seed":["INT",{"min":0,"max":18446744073709551615}],"steps":["INT",{"min":1,"max":100}],"sampler_name":[["euler","heun"]]}},"output":["LATENT"]},"VAEDecode":{"input":{"required":{"samples":["LATENT"]}},"output":["IMAGE"]},"Custom":{"input":{"required":{"gain":["FLOAT",{"min":0,"max":1}],"mode":[[1,2,3]],"payload":["CUSTOM"]}},"output":["IMAGE","MASK"]},"EmptyLatentImage":{"input":{"required":{"width":["INT",{"min":32,"max":16384,"step":8}],"height":["INT",{"min":32,"max":16384,"step":8}],"batch_size":["INT",{"min":1,"max":64}]}},"output":["LATENT"]}}"#.utf8))
    }
    func testEveryNodeLinksOutputsAndUnknownPayloadRemainVisible() throws {
        let workflow = WorkflowImporter.applyChoices(try workflow(), objectInfo: info)
        let nodes = WorkflowParameters.nodes(workflow)
        XCTAssertEqual(nodes.count, 7)
        let decoder = try XCTUnwrap(nodes.first { $0.id == "5" })
        XCTAssertTrue(decoder.fields.allSatisfy { $0.readOnlyReason != nil })
        XCTAssertEqual(decoder.fields.first?.connection, "节点 4 · 输出 0")
        XCTAssertEqual(decoder.outputs, ["0 · IMAGE（IMAGE）"])
        let custom = try XCTUnwrap(nodes.first { $0.id == "6" })
        XCTAssertNil(custom.fields.first { $0.spec.field == "gain" }?.readOnlyReason)
        XCTAssertNotNil(custom.fields.first { $0.spec.field == "payload" }?.readOnlyReason)
        XCTAssertEqual(custom.outputs.count, 2)
    }
    func testSharedDraftAppliesBothSamplersWithoutChangingSource() throws {
        let workflow = WorkflowImporter.applyChoices(try workflow(), objectInfo: info)
        var draft = WorkflowParameterDraft(workflow: workflow)
        draft.values["3|steps"] = .string("31")
        draft.values["4|steps"] = .string("9")
        draft.values["1|text"] = .string("lake")
        draft.values["2|text"] = .string("noise")
        let applied = try draft.applied(to: workflow)
        XCTAssertEqual(applied.lastValues["3|steps"], .integer(31))
        XCTAssertEqual(applied.lastValues["4|steps"], .integer(9))
        XCTAssertEqual(applied.lastValues["1|text"], .string("lake"))
        XCTAssertEqual(applied.lastValues["2|text"], .string("noise"))
        XCTAssertEqual(applied.graph, workflow.graph)
        XCTAssertTrue(workflow.lastValues.isEmpty)
    }
    func testInvalidDraftAndStaleApplyDoNotLoseEdits() throws {
        let workflow = WorkflowImporter.applyChoices(try workflow(), objectInfo: info)
        var draft = WorkflowParameterDraft(workflow: workflow)
        draft.values["3|steps"] = .string("101")
        XCTAssertThrowsError(try draft.applied(to: workflow))
        XCTAssertEqual(draft.values["3|steps"], .string("101"))
        draft.values["3|steps"] = .string("30")
        var other = workflow
        other.lastValues["4|steps"] = .integer(12)
        XCTAssertThrowsError(try draft.applied(to: other))
        XCTAssertTrue(workflow.lastValues.isEmpty)
    }
    func testUnknownStructuredDataReadOnlyAndTypedChoices() throws {
        let original = try workflow()
        var draft = WorkflowParameterDraft(workflow: original)
        draft.values["6|gain"] = .decimal(0.8)
        XCTAssertThrowsError(try draft.applied(to: original))
        draft.refresh(objectInfo: info, serverID: UUID())
        draft.values["6|mode"] = .string("3")
        let applied = try draft.applied(to: original)
        XCTAssertEqual(applied.lastValues["6|mode"], .integer(3))
        XCTAssertEqual(applied.graph["6"]?["inputs"]?["payload"], original.graph["6"]?["inputs"]?["payload"])
    }
    func testSeedExactBoundsAndPerNodeBatchIncrement() throws {
        var workflow = WorkflowImporter.applyChoices(try workflow(), objectInfo: info)
        workflow.seedStrategy = .perNode
        let prompts = try WorkflowBuilder.build(workflow: workflow, values: [:], batch: 2, randomSeed: true, baseSeed: 42, loraEnabled: [:])
        XCTAssertEqual(prompts[0].graph["3"]?["inputs"]?["seed"]?.text, "18446744073709551614")
        XCTAssertEqual(prompts[1].graph["3"]?["inputs"]?["seed"]?.text, "18446744073709551615")
        XCTAssertEqual(prompts[1].graph["4"]?["inputs"]?["seed"]?.text, "102")
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: workflow, values: [:], batch: 3, randomSeed: false, baseSeed: 42, loraEnabled: [:]))
        let field = try XCTUnwrap(WorkflowParameters.nodes(workflow).first { $0.id == "3" }?.fields.first { $0.spec.field == "seed" })
        XCTAssertEqual(try WorkflowParameters.normalized(.string("18446744073709551615"), parameter: field).text, "18446744073709551615")
        XCTAssertThrowsError(try WorkflowParameters.normalized(.string("18446744073709551616"), parameter: field))
        XCTAssertThrowsError(try WorkflowParameters.normalized(.string("-1"), parameter: field))
    }
    func testServerDimensionsNotSilentlyRoundedAndOldWorkflowDecodes() throws {
        let original = try workflow()
        XCTAssertThrowsError(try WorkflowParameters.validatedValues(workflow: original, values: ["7|width": .integer(0)]))
        XCTAssertEqual(try WorkflowParameters.validatedValues(workflow: original, values: ["7|width": .integer(513)])["7|width"], .integer(512))
        let workflow = WorkflowImporter.applyChoices(original, objectInfo: info)
        let prompts = try WorkflowBuilder.build(workflow: workflow, values: ["7|width": .integer(8200)], batch: 1, randomSeed: false, baseSeed: 42, loraEnabled: [:])
        XCTAssertEqual(prompts[0].graph["7"]?["inputs"]?["width"], .integer(8200))
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: workflow, values: ["7|width": .integer(16385)], batch: 1, randomSeed: false, baseSeed: 42, loraEnabled: [:]))
        let roundTrip = try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(original))
        XCTAssertNil(roundTrip.nodeSchemas)
        XCTAssertNil(roundTrip.seedStrategy)
        XCTAssertEqual(roundTrip.graph, original.graph)
    }
    func testRefreshRetainsDraftAndSchemaOnlyIncludesUsedClasses() throws {
        let original = try workflow()
        var draft = WorkflowParameterDraft(workflow: original)
        draft.values["1|text"] = .string("unsaved")
        let serverID = UUID()
        draft.refresh(objectInfo: info, serverID: serverID, serverAddress: "http://127.0.0.1:8188")
        XCTAssertEqual(draft.values["1|text"], .string("unsaved"))
        XCTAssertEqual(draft.workflow.schemaServerID, serverID)
        XCTAssertEqual(draft.workflow.schemaServerAddress, "http://127.0.0.1:8188")
        XCTAssertEqual(Set(draft.workflow.nodeSchemas?.keys.map { $0 } ?? []), Set(original.graph.values.compactMap { $0["class_type"]?.string }))
    }
    func testMissingConnectionSourceAndInvalidKnownOutputPortRejected() throws {
        var workflow = WorkflowImporter.applyChoices(try workflow(), objectInfo: info)
        var decoder = try XCTUnwrap(workflow.graph["5"]?.object)
        decoder["inputs"] = .object(["samples": .array([.string("4"), .integer(99)])])
        workflow.graph["5"] = .object(decoder)
        XCTAssertThrowsError(try WorkflowParameters.validatedValues(workflow: workflow, values: [:]))
        decoder["inputs"] = .object(["samples": .array([.string("missing"), .integer(0)])])
        workflow.graph["5"] = .object(decoder)
        XCTAssertThrowsError(try WorkflowParameters.validatedValues(workflow: workflow, values: [:]))
    }

    func testConnectionRequiresNonnegativeIntegerPort() {
        XCTAssertFalse(JSONValue.array([.string("node"), .decimal(0.5)]).isLink)
        XCTAssertFalse(JSONValue.array([.string("node"), .integer(-1)]).isLink)
        XCTAssertTrue(JSONValue.array([.string("node"), .integer(0)]).isLink)
    }
}

