import XCTest
@testable import ComfyCore

final class ComfyCoreTests: XCTestCase {
    private func decode(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    private func workflow() throws -> Workflow {
        try WorkflowImporter.parse(Data(Self.graph.utf8), name: "示例.json")
    }
    private static let graph = """
    {
      "1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"model.safetensors"}},
      "2":{"class_type":"CLIPTextEncode","inputs":{"text":"cat","clip":["1",1]}},
      "3":{"class_type":"CLIPTextEncode","inputs":{"text":"blur","clip":["1",1]}},
      "4":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512,"batch_size":4}},
      "5":{"class_type":"KSampler","inputs":{"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0],"seed":18446744073709551615,"steps":20,"cfg":7.5,"sampler_name":"euler","scheduler":"normal","denoise":1}},
      "6":{"class_type":"LoraLoader","inputs":{"model":["1",0],"clip":["1",1],"lora_name":"detail.safetensors","strength_model":0.7,"strength_clip":0.6}},
      "7":{"class_type":"SaveImage","inputs":{"images":["5",0],"filename_prefix":"result"}}
    }
    """

    func testUnsignedIntegerRoundTrip() throws {
        let data = Data("{\"seed\":18446744073709551615,\"large\":9007199254740993}".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value["seed"], .unsigned(UInt64.max))
        XCTAssertEqual(value["large"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: value.encoded()), value)
    }
    func testImportDetectsShortPromptsAndNegativeConnection() throws {
        let flow = try workflow()
        XCTAssertEqual(flow.name, "示例")
        XCTAssertEqual(flow.inputs.first { $0.id == "2|text" }?.kind, .prompt)
        XCTAssertEqual(flow.inputs.first { $0.id == "3|text" }?.label, "负向提示词")
        XCTAssertFalse(flow.inputs.contains { $0.field == "clip" })
        XCTAssertFalse(flow.inputs.contains { $0.nodeID == "4" && $0.field == "batch_size" })
        XCTAssertEqual(flow.loraNodes.map { $0.id }, ["6"])
    }
    func testRejectsEditorAndIncompleteGraphs() {
        for json in ["{\"nodes\":[],\"links\":[]}", "{\"1\":{\"inputs\":{}}}", "{}", "[]"] {
            XCTAssertThrowsError(try WorkflowImporter.parse(Data(json.utf8), name: "bad"))
        }
    }
    func testWrappedPromptImport() throws {
        let value = try decode(Self.graph)
        let flow = try WorkflowImporter.parse(JSONValue.object(["prompt": value]).encoded(), name: "wrapped")
        XCTAssertEqual(flow.graph.count, 7)
    }
    func testImageAndVideoSlotsImport() throws {
        let json = "{\"1\":{\"class_type\":\"LoadImage\",\"inputs\":{\"image\":\"a.png\"}},\"2\":{\"class_type\":\"VHS_LoadVideo\",\"inputs\":{\"video\":\"a.mp4\"}}}"
        let flow = try WorkflowImporter.parse(Data(json.utf8), name: "media")
        XCTAssertEqual(flow.inputs.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(flow.inputs.filter { $0.kind == .video }.count, 1)
    }
    func testRejectsMultipleIndependentImageSlots() {
        let json = "{\"1\":{\"class_type\":\"LoadImage\",\"inputs\":{\"image\":\"a.png\"}},\"2\":{\"class_type\":\"LoadImage\",\"inputs\":{\"image\":\"b.png\"}}}"
        XCTAssertThrowsError(try WorkflowImporter.parse(Data(json.utf8), name: "media"))
    }
    func testChoicesFromRequiredAndOptionalFields() throws {
        let info = try decode("{\"KSampler\":{\"input\":{\"required\":{\"sampler_name\":[[\"euler\",\"dpmpp_2m\"]]},\"optional\":{\"scheduler\":[[\"normal\",\"karras\"]]}}}}")
        let flow = WorkflowImporter.applyChoices(try workflow(), objectInfo: info)
        XCTAssertEqual(flow.inputs.first { $0.id == "5|sampler_name" }?.choices, ["euler", "dpmpp_2m"])
        XCTAssertEqual(flow.inputs.first { $0.id == "5|scheduler" }?.kind, .choice)
    }
    func testBuildDoesNotMutateSnapshotOrLinks() throws {
        let original = try workflow()
        let prompts = try WorkflowBuilder.build(workflow: original, values: ["2|text": .string("new"), "4|width": .integer(519)], batch: 2, randomSeed: false, baseSeed: 42, loraEnabled: ["6": false])
        XCTAssertEqual(prompts.map { $0.seed }, [42, 43])
        XCTAssertEqual(prompts[0].index, 1)
        XCTAssertEqual(prompts[0].graph["2"]?["inputs"]?["text"], .string("new"))
        XCTAssertEqual(prompts[0].graph["4"]?["inputs"]?["width"], .integer(512))
        XCTAssertEqual(prompts[0].graph["4"]?["inputs"]?["batch_size"], .integer(1))
        XCTAssertEqual(prompts[0].graph["2"]?["inputs"]?["clip"], original.graph["2"]?["inputs"]?["clip"])
        XCTAssertEqual(prompts[0].graph["6"]?["inputs"]?["strength_model"], .decimal(0))
        XCTAssertEqual(original.graph["2"]?["inputs"]?["text"], .string("cat"))
    }
    func testIntegerParameterDoesNotRoundThroughDouble() throws {
        let flow = try workflow()
        let result = try WorkflowBuilder.build(workflow: flow, values: ["5|steps": .integer(9_007_199_254_740_993)], batch: 1, randomSeed: false, baseSeed: 1, loraEnabled: [:])
        XCTAssertEqual(result[0].graph["5"]?["inputs"]?["steps"], .integer(9_007_199_254_740_993))
    }
    func testSeedOverflowAndInvalidParametersRejected() throws {
        let flow = try workflow()
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: flow, values: [:], batch: 2, randomSeed: false, baseSeed: UInt64.max, loraEnabled: [:]))
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: flow, values: [:], batch: 9, randomSeed: true, baseSeed: 1, loraEnabled: [:]))
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: flow, values: ["4|width": .integer(0)], batch: 1, randomSeed: false, baseSeed: 1, loraEnabled: [:]))
        XCTAssertThrowsError(try WorkflowBuilder.build(workflow: flow, values: ["5|steps": .string("3.4")], batch: 1, randomSeed: false, baseSeed: 1, loraEnabled: [:]))
    }
    func testMaximumSeedAllowedForOneImage() throws {
        let result = try WorkflowBuilder.build(workflow: workflow(), values: [:], batch: 1, randomSeed: false, baseSeed: UInt64.max, loraEnabled: [:])
        XCTAssertEqual(result[0].seed, UInt64.max)
        XCTAssertEqual(result[0].graph["5"]?["inputs"]?["seed"], .unsigned(UInt64.max))
    }
    func testMultipleSameTypeOutputsKeepDistinctIdentities() throws {
        let value = try decode("{\"10\":{\"images\":[{\"filename\":\"a.png\"}]},\"11\":{\"images\":[{\"filename\":\"b.png\"},{\"filename\":\"a.png\"}]}}")
        let result = OutputParser.parse(promptID: "p", outputs: value)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map { $0.id }).count, 2)
        XCTAssertNotEqual(result[0].id, OutputParser.parse(promptID: "other", outputs: value)[0].id)
    }
    func testVideoAndTextOutputs() throws {
        let value = try decode("{\"1\":{\"gifs\":[{\"filename\":\"movie.mp4\",\"format\":\"video/h264-mp4\"}]},\"2\":{\"text\":[\"你\",\"好\"]},\"3\":{\"string\":[\"line one\",\"line two\"]}}")
        let result = OutputParser.parse(promptID: "p", outputs: value)
        XCTAssertEqual(result.first?.kind, .video)
        XCTAssertTrue(result.contains { $0.text == "你好" })
        XCTAssertTrue(result.contains { $0.text == "line one\nline two" })
    }
    func testReverseProxyURLAndSpecialFilename() throws {
        let base = try ServerAddress.normalized(" https://example.com/comfy/ ")
        let url = try ServerAddress.endpoint(base: base, route: "/view", query: [URLQueryItem(name: "filename", value: "猫 & sky#.png")])
        XCTAssertEqual(url.path, "/comfy/view")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "猫 & sky#.png")
        XCTAssertTrue(ServerAddress.sameOrigin(base, URL(string: "https://example.com:443/other")!))
        XCTAssertFalse(ServerAddress.sameOrigin(base, URL(string: "http://example.com/other")!))
        XCTAssertThrowsError(try ServerAddress.normalized("https://user:password@example.com"))
        XCTAssertThrowsError(try ServerAddress.normalized("file:///tmp"))
        XCTAssertThrowsError(try ServerAddress.normalized("https://example.com/?secret=1"))
    }
    func testRecoverSubmissionFromQueueAndHistory() throws {
        let queue = try decode("{\"queue_pending\":[[1,\"p\",{}, {\"comfy_pocket_job\":\"job\",\"comfy_pocket_index\":2}]]}")
        XCTAssertEqual(QueueParser.recover(jobID: "job", index: 2, queue: queue, history: .object([:])), "p")
        XCTAssertNil(QueueParser.recover(jobID: "other", index: 2, queue: queue, history: .object([:])))
        let history = try decode("{\"old\":{\"prompt\":[1,\"old\",{}, {\"comfy_pocket_job\":\"job\",\"comfy_pocket_index\":1}]}}")
        XCTAssertEqual(QueueParser.recover(jobID: "job", index: 1, queue: .object([:]), history: history), "old")
    }
}
