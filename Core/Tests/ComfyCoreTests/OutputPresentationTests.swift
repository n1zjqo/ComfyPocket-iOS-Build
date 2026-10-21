import XCTest
@testable import ComfyCore

final class OutputPresentationTests: XCTestCase {
    private func output(_ identifier: String, kind: AssetKind = .text, text: String = "") -> OutputDescriptor {
        OutputDescriptor(id: identifier, kind: kind, filename: kind == .text ? "" : "result.png", subfolder: "", fileType: "output", text: text)
    }

    func testMediaSuppressesSeparateTextCardsWithoutDiscardingMedia() {
        let outputs = [output("image1", kind: .image), output("prompt1", text: "cat"), output("prompt2", text: "cat"), output("image2", kind: .image)]
        XCTAssertEqual(OutputPresentation.galleryOutputs(outputs).map { $0.id }, ["image1", "image2"])
        XCTAssertEqual(outputs.count, 4)
    }

    func testVideoAlsoKeepsTextInItsDetailRatherThanSeparateCards() {
        XCTAssertEqual(OutputPresentation.galleryOutputs([output("video", kind: .video), output("caption", text: "a video")]).map { $0.id }, ["video"])
    }

    func testTextOnlyOutputsRemainVisibleAndDeduplicateAcrossNodes() {
        let outputs = [output("first", text: " cat\r\nnight "), output("second", text: "cat\nnight"), output("other", text: "CAT\nnight"), output("blank", text: " \n")]
        XCTAssertEqual(OutputPresentation.galleryOutputs(outputs).map { $0.id }, ["first", "other"])
    }

    func testDetailExcludesMatchingPromptButPreservesDifferentText() {
        let outputs = [output("echo", text: " cat\r\nnight "), output("negative", text: "blur, low quality"), output("duplicate", text: "blur, low quality"), output("image", kind: .image)]
        XCTAssertEqual(OutputPresentation.distinctTextOutputs(outputs, excluding: "cat\nnight").map { $0.id }, ["negative"])
    }

    func testEmptyOutputsAndWhitespaceProduceNoCards() {
        XCTAssertTrue(OutputPresentation.galleryOutputs([]).isEmpty)
        XCTAssertTrue(OutputPresentation.galleryOutputs([output("blank", text: "\r\n \t")]).isEmpty)
    }
}
