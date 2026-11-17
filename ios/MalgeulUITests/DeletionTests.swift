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

    // MARK: - 서버 노트 팝오버의 표시 영역과 실제 좌표 터치
    private var serverNoteRow: XCUIElement {
        app.cells.containing(.staticText, identifier: "디자인 시안 검토 회의").firstMatch
    }
    private func serverButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
    private func openServerMenu() {
        XCTAssertTrue(serverNoteRow.waitForExistence(timeout: 10))
        serverNoteRow.buttons["note-menu"].tap()
        XCTAssertTrue(app.buttons["delete-confirm-button"].waitForExistence(timeout: 5))
        capture("server-menu-open")
    }
    private func tapTrailingArea(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let frame = button.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * 0.85, dy: frame.midY)).tap()
    }
    func testServerNotePopoverMenuFrames() {
        openServerMenu()
        let buttons = [serverButton("제목 수정"), serverButton("녹음 시각 수정"),
                       serverButton("그룹 옮기기"), app.buttons["delete-confirm-button"]]
        for button in buttons { XCTAssertTrue(button.exists) }
        let frames = buttons.map { $0.frame }
        let data = try! JSONSerialization.data(withJSONObject: frames.map {
            [$0.minX, $0.minY, $0.width, $0.height]
        }, options: [.prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "server-menu-frames"; attachment.lifetime = .keepAlways; add(attachment)
        capture("server-menu-geometry")
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "항목 \(index)의 보이는 버튼 영역이 44포인트 이상")
            XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 0.5)
            XCTAssertEqual(frame.width, frames[0].width, accuracy: 0.5)
            if index > 0 { XCTAssertLessThanOrEqual(frames[index-1].maxY, frame.minY + 0.5, "인접 메뉴 터치 영역이 겹치면 안 됨") }
        }
    }
    func testServerNoteMenuTitleEditAlert() {
        openServerMenu(); tapTrailingArea(serverButton("제목 수정"))
        let alert = app.alerts["제목 수정"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["녹음 시각 수정"].exists)
        capture("server-title-correct-target")
        alert.buttons["취소"].tap()
    }
    func testServerNoteMenuDateEditSheet() {
        openServerMenu(); tapTrailingArea(serverButton("녹음 시각 수정"))
        XCTAssertTrue(app.navigationBars["녹음 시각 수정"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["제목 수정"].exists)
        capture("server-date-correct-target")
        app.buttons["취소"].tap()
    }
    func testServerNoteMenuGroupSelectionSubmenu() {
        openServerMenu(); tapTrailingArea(serverButton("그룹 옮기기"))
        XCTAssertTrue(serverButton("팀 회의").waitForExistence(timeout: 5))
        XCTAssertTrue(serverButton("기본").exists)
        XCTAssertFalse(app.alerts["제목 수정"].exists)
        XCTAssertFalse(app.navigationBars["녹음 시각 수정"].exists)
        capture("server-group-correct-target")
    }
    func testServerNoteMenuTouchOutsideArea() {
        openServerMenu()
        app.coordinate(withNormalizedOffset: CGPoint(x: 0.05, y: 0.08)).tap()
        XCTAssertFalse(app.buttons["delete-confirm-button"].exists)
        XCTAssertTrue(serverNoteRow.exists)
        capture("server-outside-no-delete")
    }
}
