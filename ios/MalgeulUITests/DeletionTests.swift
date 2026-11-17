import XCTest

final class MalgeulNoteListDeletionTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demoServer", "http://127.0.0.1:8080", "-demoToken", "demo", "-noteListUITest", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note-button"].waitForExistence(timeout: 20))
    }
    override func tearDownWithError() throws { app.terminate() }

    private var row: XCUIElement {
        app.cells.containing(.staticText, identifier: "화면 시험 녹음").firstMatch
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func verifySameButton(_ button: XCUIElement, prefix: String) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable, "보이는 삭제 버튼이 실제로 눌려야 한다")
        let before = button.frame
        XCTAssertGreaterThan(before.width, 40)
        capture(prefix + "-before")
        button.tap()
        XCTAssertTrue(row.exists, "첫 누름에는 실제 녹음 파일을 삭제하지 않는다")
        XCTAssertTrue(button.exists)
        XCTAssertTrue(button.label.contains("한 번 더"), "같은 버튼의 문구가 확인으로 바뀐다")
        let after = button.frame
        XCTAssertEqual(before.origin.x, after.origin.x, accuracy: 0.5)
        XCTAssertEqual(before.origin.y, after.origin.y, accuracy: 0.5)
        XCTAssertEqual(before.width, after.width, accuracy: 0.5)
        XCTAssertEqual(before.height, after.height, accuracy: 0.5)
        let frames = ["before":[before.minX,before.minY,before.width,before.height],
                      "armed":[after.minX,after.minY,after.width,after.height]]
        let data = try! JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = prefix + "-frames"; attachment.lifetime = .keepAlways; add(attachment)
        capture(prefix + "-armed")
        let reset = NSPredicate(format: "label == %@", "삭제")
        expectation(for: reset, evaluatedWith: button)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(row.exists, "4초가 지나도 행과 펼친 삭제 버튼이 유지된다")
        // 첫 누름 보존·좌표·만료는 위에서 검증했다. 깊은 AX 조회 지연 없이 같은 버튼에 두 탭을 보낸다.
        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY))
        point.tap()
        Thread.sleep(forTimeInterval: 0.4)
        point.tap()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: row)
        waitForExpectations(timeout: 5)
        capture(prefix + "-deleted")
    }
    func testPlusOffersRecordingAndUpload() {
        app.buttons["new-note-button"].tap()
        XCTAssertTrue(app.buttons["녹음"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["파일 업로드"].exists)
        capture("plus-menu")
    }
    func testMenuDeleteStaysInPlace() {
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.buttons["note-menu"].tap()
        verifySameButton(app.buttons["delete-confirm-button"], prefix: "menu")
    }
    func testSwipeDeleteStaysInPlace() {
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft(velocity: .slow)
        verifySameButton(app.buttons["swipe-delete-button"].firstMatch, prefix: "swipe")
    }
}
