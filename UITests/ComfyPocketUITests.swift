import XCTest

final class ComfyPocketUITests: XCTestCase {
    func testSwipeClearScreenAndDraftRestore() {
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-app-demo", "--artwork-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 10))
        let background = app.descendants(matching: .any).matching(identifier: "generation-artwork").firstMatch
        XCTAssertTrue(background.exists)
        let originalFrame = background.frame
        capture("Swipe canvas — chat over fixed artwork", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        XCTAssertTrue(app.buttons["参数"].isHittable)
        let editor = app.textViews.firstMatch
        XCTAssertLessThanOrEqual(editor.frame.height, 72)
        editor.tap()
        editor.typeText(" keep this draft")
        let draft = editor.value as? String
        XCTAssertNotNil(draft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        swipeCanvas(app, right: true)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "清屏画面，左滑恢复聊天"), object: background)], timeout: 5), .completed)
        capture("Swipe canvas — cleared with no composer, header, tabs or floating strip", app: app)
        assertOffscreen(app.buttons["参数"], in: app)
        assertOffscreen(app.buttons["全屏查看生成图"], in: app)
        assertOffscreen(app.tabBars.buttons["作品"], in: app)
        XCTAssertFalse(app.buttons["展开提示词面板"].exists)
        XCTAssertFalse(app.buttons["关闭全屏预览"].exists)
        assertOffscreen(app.textViews.firstMatch, in: app)
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertEqual(background.frame, originalFrame)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertOffscreen(app.buttons["参数"], in: app)
        swipeCanvas(app, right: false)
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["参数"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["作品"].isHittable)
        XCTAssertEqual(app.textViews.firstMatch.value as? String, draft)
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertEqual(background.frame, originalFrame)
        capture("Swipe canvas — left swipe restores the same draft and controls", app: app)
        app.buttons["参数"].tap()
        XCTAssertTrue(app.navigationBars["工作流参数"].waitForExistence(timeout: 5))
        let parameterBar = app.navigationBars["工作流参数"]
        parameterBar.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(forDuration: 0.1, thenDragTo: parameterBar.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        XCTAssertTrue(parameterBar.exists)
        XCTAssertEqual(background.label, "生成结果背景，右滑清屏")
        capture("Swipe canvas — parameter sheet ignores clear-screen gestures", app: app)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["参数"].isHittable)
        app.buttons["输入工具"].tap()
        app.buttons["右滑清屏"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "清屏画面，左滑恢复聊天"), object: background)], timeout: 5), .completed)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(background.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(background.frame.midY, app.frame.midY, accuracy: 1)
        XCTAssertEqual(background.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(background.frame.height, app.frame.height, accuracy: 1)
        capture("Swipe canvas — cleared after rotation", app: app)
        assertOffscreen(app.buttons["输入工具"], in: app)
        assertOffscreen(app.buttons["参数"], in: app)
        assertOffscreen(app.textViews.firstMatch, in: app)
        assertOffscreen(app.tabBars.buttons["作品"], in: app)
        swipeCanvas(app, right: false)
        XCTAssertTrue(app.buttons["参数"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["作品"].isHittable)
        XCTAssertLessThanOrEqual(app.textViews.firstMatch.frame.maxY, app.tabBars.firstMatch.frame.minY + 0.5)
        capture("Swipe canvas — landscape restores compact glass composer", app: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: app)], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 1)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        swipeCanvas(app, right: true)
        XCTAssertTrue(app.navigationBars["设置"].exists)
        XCTAssertTrue(app.tabBars.buttons["生成"].isHittable)
        app.tabBars.buttons["生成"].tap()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testImageReplyAndGroupedGallery() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-app-demo", "--conversation-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let reply = app.buttons["查看生成图片"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        for _ in 0..<6 {
            if reply.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(reply.isHittable)
        XCTAssertEqual(app.textViews.firstMatch.value as? String, "")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "generation-artwork").firstMatch.exists)
        capture("Conversation — image reply with the same background and empty composer", app: app)
        reply.tap()
        XCTAssertTrue(app.navigationBars["作品详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["收藏这段提示词"].exists)
        let disclosure = app.buttons["工作流文字输出"]
        for _ in 0..<6 {
            if disclosure.exists && disclosure.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(disclosure.isHittable)
        disclosure.tap()
        XCTAssertTrue(app.staticTexts["负向提示词：模糊，低质量"].exists)
        let detail = app.scrollViews["asset-detail-content"]
        XCTAssertTrue(detail.exists)
        XCTAssertEqual(detail.staticTexts.matching(identifier: "代码绘制的测试画布，不是模型生成结果").count, 1)
        capture("Conversation — original result detail with supplementary text", app: app)
        app.navigationBars.buttons["完成"].tap()
        app.tabBars.buttons["作品"].tap()
        let galleryCards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "gallery-asset-"))
        XCTAssertEqual(galleryCards.count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "文字结果").count, 0)
        capture("Gallery — one image card rather than separate duplicate prompt cards", app: app)
        app.tabBars.buttons["生成"].tap()
        let background = app.descendants(matching: .any).matching(identifier: "generation-artwork").firstMatch
        swipeCanvas(app, right: true)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "清屏画面，左滑恢复聊天"), object: background)], timeout: 5), .completed)
        assertOffscreen(reply, in: app)
        swipeCanvas(app, right: false)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "生成结果背景，右滑清屏"), object: background)], timeout: 5), .completed)
        XCTAssertTrue(reply.isHittable)
        app.terminate()
    }

    func testFullscreenArtworkZoomRemainsSeparateFromClearScreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-app-demo", "--artwork-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["输入工具"].waitForExistence(timeout: 10))
        app.buttons["输入工具"].tap()
        app.buttons["全屏查看生成图"].tap()
        let close = app.buttons["关闭全屏预览"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["作品"].isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        capture("Artwork — separate native double-tap zoom", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)], timeout: 5), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testFullscreenSavesAndSharesOriginalArtwork() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-app-demo", "--artwork-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["全屏看图"].waitForExistence(timeout: 10))
        app.buttons["全屏看图"].tap()
        let save = app.buttons["保存到相册"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        capture("Artwork — complete native preview with original-file actions", app: app)
        save.tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 4) {
            let allow = permission.buttons.matching(NSPredicate(format: "label != %@ AND label != %@ AND label != %@", "不允许", "Don't Allow", "Don’t Allow")).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
        let result = app.alerts["保存结果"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.staticTexts["已保存到系统相册。"].exists)
        capture("Artwork — Photos reports successful real file save", app: app)
        result.buttons["知道了"].tap()
        app.buttons["分享原文件"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        let systemAction = app.cells.matching(NSPredicate(format: "label IN %@", ["拷贝", "复制", "Copy", "存储到文件", "Save to Files"])).firstMatch
        XCTAssertTrue(systemAction.waitForExistence(timeout: 10))
        capture("Artwork — system original-file share sheet", app: app)
        app.terminate()
    }

    private func assertOffscreen(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard element.exists else { return }
        let frame = element.frame
        let screen = app.frame
        XCTAssertTrue(frame.isEmpty || frame.minX >= screen.maxX - 0.5 || frame.maxX <= screen.minX + 0.5 || frame.minY >= screen.maxY - 0.5 || frame.maxY <= screen.minY + 0.5, "A cleared control remains inside the visible screen: \(frame)", file: file, line: line)
    }

    private func swipeCanvas(_ app: XCUIApplication, right: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.12 : 0.88, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.88 : 0.12, dy: 0.25))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    func testWorkflowApplicationEditingAndOverview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--workflow-app-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 10))
        app.buttons["参数"].tap()
        XCTAssertTrue(app.navigationBars["工作流参数"].waitForExistence(timeout: 5))
        capture("Fuyu parameters — simplified groups and draft boundary", app: app)
        app.buttons["parameter-node-canvas"].tap()
        XCTAssertTrue(app.buttons["parameter-node-canvas"].isSelected)
        let width = app.textFields["field-92|value"]
        scrollToEditableField(width, app: app)
        width.tap()
        width.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1024")
        XCTAssertEqual(width.value as? String, "1024")
        app.navigationBars.buttons["取消"].tap()
        app.buttons["参数"].tap()
        app.buttons["parameter-node-canvas"].tap()
        scrollToEditableField(width, app: app)
        XCTAssertEqual(width.value as? String, "2160")
        width.tap()
        width.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1024")
        app.navigationBars.buttons["应用"].tap()
        app.buttons["参数"].tap()
        app.buttons["parameter-node-canvas"].tap()
        scrollToEditableField(width, app: app)
        XCTAssertEqual(width.value as? String, "1024")
        capture("Fuyu parameters — applied upstream dimensions", app: app)
        app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全部节点")).firstMatch.tap()
        capture("Fuyu parameters — all actual API nodes", app: app)
        app.navigationBars.buttons["取消"].tap()
        app.tabBars.buttons["工作流"].tap()
        app.staticTexts["双采文生图 · 4K 应用"].firstMatch.tap()
        app.buttons["查看流程概览"].tap()
        XCTAssertTrue(app.navigationBars["流程概览"].waitForExistence(timeout: 5))
        capture("Fuyu parameters — read-only graph overview", app: app)
        app.terminate()
    }

    func testFirstRunNavigationAndSavingServer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["连接 ComfyUI"].waitForExistence(timeout: 10))
        capture("First run — image canvas and glass composer", app: app)
        app.buttons["连接 ComfyUI"].tap()
        app.buttons["添加连接"].tap()
        let address = app.textFields["server-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.alerts["连接未保存"].waitForExistence(timeout: 5))
        app.alerts["连接未保存"].buttons["知道了"].tap()
        XCTAssertTrue(address.isHittable)
        capture("Connection editor — draft survives validation", app: app)
        address.tap()
        address.typeText("http://127.0.0.1:8188")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["我的 ComfyUI"].waitForExistence(timeout: 5))
        app.tabBars.buttons["工作流"].tap()
        XCTAssertTrue(app.buttons["导入 API 工作流"].exists)
        app.tabBars.buttons["作品"].tap()
        XCTAssertTrue(app.staticTexts["作品会留在这里"].exists)
        app.tabBars.buttons["生成"].tap()
        XCTAssertTrue(app.buttons["导入工作流"].exists)
        capture("First run — glass composer and safe area", app: app)
    }

    func testLargestTextNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["参数"].isHittable)
        XCTAssertTrue(app.buttons["输入工具"].isHittable)
        XCTAssertTrue(app.buttons["查看任务队列"].isHittable)
        capture("Largest system text — first run and composer", app: app)
        app.buttons["参数"].tap()
        XCTAssertTrue(app.navigationBars["工作流参数"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        app.buttons["输入工具"].tap()
        app.buttons["提示词库"].tap()
        XCTAssertTrue(app.navigationBars["提示词库"].waitForExistence(timeout: 5))
        capture("Largest system text — prompt library", app: app)
        XCTAssertTrue(app.scrollViews.firstMatch.exists)
        app.scrollViews.firstMatch.swipeUp()
        capture("Largest system text — full prompt library description after scroll", app: app)
        app.navigationBars.buttons["关闭"].tap()
        app.buttons["查看任务队列"].tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        app.tabBars.buttons["作品"].tap()
        XCTAssertTrue(app.staticTexts["作品会留在这里"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews.firstMatch.exists)
        app.scrollViews.firstMatch.swipeUp()
        capture("Largest system text — full gallery description after scroll", app: app)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 5))
        capture("Largest system text — settings navigation", app: app)
        app.terminate()
    }

    func testReducedTransparencyUsesOpaquePanels() {
        continueAfterFailure = false
        let preferences = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        preferences.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        preferences.launch()
        let accessibility = preferences.cells.containing(.staticText, identifier: "Accessibility").firstMatch
        for _ in 0..<8 {
            if accessibility.isHittable { break }
            preferences.swipeUp()
        }
        XCTAssertTrue(accessibility.isHittable)
        accessibility.tap()
        let display = preferences.cells.containing(.staticText, identifier: "Display & Text Size").firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.tap()
        let transparency = preferences.switches["Reduce Transparency"]
        XCTAssertTrue(transparency.waitForExistence(timeout: 5))
        let originalValue = transparency.value as? String
        if originalValue == "0" { transparency.tap() }
        XCTAssertEqual(transparency.value as? String, "1")
        capture("System Settings — Reduce Transparency is enabled", app: preferences)
        defer {
            preferences.activate()
            if originalValue == "0", transparency.exists, transparency.value as? String == "1" { transparency.tap() }
            preferences.terminate()
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 10))
        capture("Reduced transparency — opaque canvas panels", app: app)
        app.buttons["参数"].tap()
        XCTAssertTrue(app.navigationBars["工作流参数"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["参数"].isHittable)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--workflow-app-demo", "--artwork-demo", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["参数"].waitForExistence(timeout: 10))
        swipeCanvas(app, right: true)
        let background = app.descendants(matching: .any).matching(identifier: "generation-artwork").firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "清屏画面，左滑恢复聊天"), object: background)], timeout: 5), .completed)
        capture("Reduced transparency — clear canvas glass frame fallback", app: app)
        assertOffscreen(app.buttons["参数"], in: app)
        swipeCanvas(app, right: false)
        XCTAssertTrue(app.buttons["参数"].isHittable)
        app.terminate()
    }

    private func scrollToEditableField(_ field: XCUIElement, app: XCUIApplication) {
        for _ in 0..<30 {
            var upward = true
            if field.exists {
                let frame = field.frame
                if field.isHittable, frame.minY > 140, frame.maxY < app.frame.maxY - 160 { return }
                upward = frame.maxY >= app.frame.maxY - 160 || !field.isHittable
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: upward ? 0.70 : 0.40))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: upward ? 0.45 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("输入框未完整进入可编辑区域")
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
