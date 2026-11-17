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

    // MARK: - 서버 노트 팝오버 메뉴 테스트

    private var serverNoteRow: XCUIElement {
        app.cells.containing(.staticText, identifier: "디자인 시안 검토 회의").firstMatch
    }

    func testServerNotePopopverMenuFrames() {
        XCTAssertTrue(serverNoteRow.waitForExistence(timeout: 10), "서버 노트 행이 로드되어야 한다")
        capture("server-note-row-before-menu")

        // 메뉴 열기
        serverNoteRow.buttons["note-menu"].tap()
        XCTAssertTrue(app.buttons["delete-confirm-button"].waitForExistence(timeout: 5), "팝오버 메뉴가 나타나야 한다")
        capture("server-note-menu-opened")

        // 네 가지 주요 항목 프레임 조회
        let titleButton = app.buttons.containing(.staticText, identifier: "제목 수정").firstMatch
        let dateButton = app.buttons.containing(.staticText, identifier: "녹음 시각 수정").firstMatch
        let groupButton = app.buttons.containing(.staticText, identifier: "그룹 옮기기").firstMatch
        let deleteButton = app.buttons["delete-confirm-button"]

        XCTAssertTrue(titleButton.waitForExistence(timeout: 3), "제목 수정 버튼이 보여야 한다")
        XCTAssertTrue(dateButton.exists, "녹음 시각 수정 버튼이 보여야 한다")
        XCTAssertTrue(groupButton.exists, "그룹 옮기기 버튼이 보여야 한다")
        XCTAssertTrue(deleteButton.exists, "삭제 버튼이 보여야 한다")

        // 각 버튼의 frame 수집
        let frames: [String: [Double]] = [
            "title_button": [titleButton.frame.minX, titleButton.frame.minY, titleButton.frame.width, titleButton.frame.height],
            "date_button": [dateButton.frame.minX, dateButton.frame.minY, dateButton.frame.width, dateButton.frame.height],
            "group_button": [groupButton.frame.minX, groupButton.frame.minY, groupButton.frame.width, groupButton.frame.height],
            "delete_button": [deleteButton.frame.minX, deleteButton.frame.minY, deleteButton.frame.width, deleteButton.frame.height],
        ]

        // 조건 검증: 각 버튼의 높이가 44 이상
        for (name, frame) in frames {
            let height = frame[3]
            XCTAssertGreaterThanOrEqual(height, 44, "\(name)의 높이가 44 이상이어야 한다. 실제: \(height)")
        }

        // 조건 검증: 버튼들이 겹치지 않음 (y 범위 확인)
        let titleY = frames["title_button"]![1]
        let titleH = frames["title_button"]![3]
        let dateY = frames["date_button"]![1]
        let dateH = frames["date_button"]![3]
        let groupY = frames["group_button"]![1]
        let groupH = frames["group_button"]![3]
        let deleteY = frames["delete_button"]![1]
        let deleteH = frames["delete_button"]![3]

        // 겹치지 않는지 확인 (각 버튼 범위가 다음 버튼과 겹치지 않음)
        XCTAssertLessThanOrEqual(titleY + titleH, dateY, "제목 수정과 시각 수정이 겹쳐서는 안 된다")
        XCTAssertLessThanOrEqual(dateY + dateH, groupY, "시각 수정과 그룹 옮기기가 겹쳐서는 안 된다")
        XCTAssertLessThanOrEqual(groupY + groupH, deleteY, "그룹 옮기기와 삭제가 겹쳐서는 안 된다")

        // 조건 검증: 같은 시작 x와 width (0.5 오차)
        let titleX = frames["title_button"]![0]
        let titleW = frames["title_button"]![2]
        let dateX = frames["date_button"]![0]
        let dateW = frames["date_button"]![2]
        let groupX = frames["group_button"]![0]
        let groupW = frames["group_button"]![2]
        let deleteX = frames["delete_button"]![0]
        let deleteW = frames["delete_button"]![2]

        XCTAssertEqual(titleX, dateX, accuracy: 0.5, "제목·시각이 같은 시작 x를 가져야 한다")
        XCTAssertEqual(dateX, groupX, accuracy: 0.5, "시각·그룹이 같은 시작 x를 가져야 한다")
        XCTAssertEqual(groupX, deleteX, accuracy: 0.5, "그룹·삭제가 같은 시작 x를 가져야 한다")

        XCTAssertEqual(titleW, dateW, accuracy: 0.5, "제목·시각이 같은 너비를 가져야 한다")
        XCTAssertEqual(dateW, groupW, accuracy: 0.5, "시각·그룹이 같은 너비를 가져야 한다")
        XCTAssertEqual(groupW, deleteW, accuracy: 0.5, "그룹·삭제가 같은 너비를 가져야 한다")

        // frame JSON 첨부
        let data = try! JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "server-note-menu-frames"; attachment.lifetime = .keepAlways; add(attachment)
        capture("server-note-menu-frames")
    }

    func testServerNoteMenuTitleEditAlert() {
        XCTAssertTrue(serverNoteRow.waitForExistence(timeout: 10), "서버 노트 행이 로드되어야 한다")
        capture("server-note-menu-title-test-start")

        // 메뉴 열기
        serverNoteRow.buttons["note-menu"].tap()
        XCTAssertTrue(app.buttons["delete-confirm-button"].waitForExistence(timeout: 5), "팝오버 메뉴가 나타나야 한다")
        capture("server-note-menu-title-opened")

        // 제목 수정 버튼의 오른쪽 빈곳(0.85, 0.5)을 탭
        let titleButton = app.buttons.containing(.staticText, identifier: "제목 수정").firstMatch
        XCTAssertTrue(titleButton.waitForExistence(timeout: 3))
        let titleFrame = titleButton.frame
        let tapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: titleFrame.minX + titleFrame.width * 0.85, dy: titleFrame.midY))
        capture("server-note-menu-title-before-tap")
        tapPoint.tap()

        // 제목 수정 alert이 나타나는지 확인
        let titleAlert = app.alerts.firstMatch
        XCTAssertTrue(titleAlert.waitForExistence(timeout: 3), "제목 수정 alert이 나타나야 한다")
        capture("server-note-menu-title-alert-appeared")

        // 다른 화면이 나타나지 않았는지 확인
        XCTAssertFalse(app.sheets.firstMatch.exists, "시각 수정 sheet가 나타나면 안 된다")
        XCTAssertFalse(app.otherElements["group-selection-menu"].exists, "그룹 선택 메뉴가 나타나면 안 된다")

        // alert 닫기
        app.buttons["Cancel"].tap()
        capture("server-note-menu-title-alert-closed")
    }

    func testServerNoteMenuDateEditSheet() {
        XCTAssertTrue(serverNoteRow.waitForExistence(timeout: 10), "서버 노트 행이 로드되어야 한다")
        capture("server-note-menu-date-test-start")

        // 메뉴 열기
        serverNoteRow.buttons["note-menu"].tap()
        XCTAssertTrue(app.buttons["delete-confirm-button"].waitForExistence(timeout: 5), "팝오버 메뉴가 나타나야 한다")
        capture("server-note-menu-date-opened")

        // 녹음 시각 수정 버튼의 오른쪽 빈곳(0.85, 0.5)을 탭
        let dateButton = app.buttons.containing(.staticText, identifier: "녹음 시각 수정").firstMatch
        XCTAssertTrue(dateButton.waitForExistence(timeout: 3))
        let dateFrame = dateButton.frame
        let tapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dateFrame.minX + dateFrame.width * 0.85, dy: dateFrame.midY))
        capture("server-note-menu-date-before-tap")
        tapPoint.tap()

        // 녹음 시각 수정 sheet이 나타나는지 확인 (DatePicker를 포함하는 sheet)
        let dateSheet = app.sheets.firstMatch
        XCTAssertTrue(dateSheet.waitForExistence(timeout: 3), "녹음 시각 수정 sheet이 나타나야 한다")
        capture("server-note-menu-date-sheet-appeared")

        // 다른 화면이 나타나지 않았는지 확인
        XCTAssertFalse(app.alerts.firstMatch.exists, "제목 수정 alert이 나타나면 안 된다")
        XCTAssertFalse(app.otherElements["group-selection-menu"].exists, "그룹 선택 메뉴가 나타나면 안 된다")

        // sheet 닫기
        app.buttons["Cancel"].tap()
        capture("server-note-menu-date-sheet-closed")
    }

    func testServerNoteMenuGroupSelectionSubmenu() {
        XCTAssertTrue(serverNoteRow.waitForExistence(timeout: 10), "서버 노트 행이 로드되어야 한다")
        capture("server-note-menu-group-test-start")

        // 메뉴 열기
        serverNoteRow.buttons["note-menu"].tap()
        XCTAssertTrue(app.buttons["delete-confirm-button"].waitForExistence(timeout: 5), "팝오버 메뉴가 나타나야 한다")
        capture("server-note-menu-group-opened")

        // 그룹 옮기기 버튼의 오른쪽 빈곳(0.85, 0.5)을 탭
        let groupButton = app.buttons.containing(.staticText, identifier: "그룹 옮기기").firstMatch
        XCTAssertTrue(groupButton.waitForExistence(timeout: 3))
        let groupFrame = groupButton.frame
        let tapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: groupFrame.minX + groupFrame.width * 0.85, dy: groupFrame.midY))
        capture("server-note-menu-group-before-tap")
        tapPoint.tap()

        // 그룹 선택 하위 메뉴가 나타나는지 확인 (native Menu → native submenu)
        // SwiftUI Menu는 시스템 메뉴로 렌더링되므로 메뉴 항목 텍스트로 확인
        XCTAssertTrue(app.menuItems.containing(.staticText, identifier: "기본").firstMatch.waitForExistence(timeout: 3),
                      "기본 그룹이 메뉴에 나타나야 한다")
        XCTAssertTrue(app.menuItems.containing(.staticText, identifier: "팀 회의").firstMatch.exists,
                      "팀 회의 그룹이 메뉴에 나타나야 한다")
        capture("server-note-menu-group-submenu-appeared")

        // 다른 화면이 나타나지 않았는지 확인
        XCTAssertFalse(app.alerts.firstMatch.exists, "제목 수정 alert이 나타나면 안 된다")
        XCTAssertFalse(app.sheets.firstMatch.exists, "시각 수정 sheet이 나타나면 안 된다")

        // 메뉴 닫기 (다른 곳 탭)
        app.coordinate(withNormalizedOffset: CGPoint(x: 0.1, y: 0.1)).tap()
        capture("server-note-menu-group-submenu-closed")
    }

    func testServerNoteMenuTouchOutsideArea() {
        XCTAssertTrue(serverNoteRow.waitForExistence(timeout: 10), "서버 노트 행이 로드되어야 한다")
        capture("server-note-menu-touch-test-start")

        // 메뉴 열기
        serverNoteRow.buttons["note-menu"].tap()
        XCTAssertTrue(app.buttons["delete-confirm-button"].waitForExistence(timeout: 5), "팝오버 메뉴가 나타나야 한다")
        capture("server-note-menu-touch-opened")

        // 메뉴 전체 아래 링크 영역(메뉴 하단)의 오른쪽 빈곳을 탭하여 오작동 없음 확인
        let deleteButton = app.buttons["delete-confirm-button"]
        let deleteFrame = deleteButton.frame
        let belowMenuTapPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: deleteFrame.minX + deleteFrame.width * 0.85,
                                 dy: deleteFrame.maxY + 10))
        capture("server-note-menu-touch-before-below-tap")
        belowMenuTapPoint.tap()

        // 메뉴가 닫혀야 한다 (팝오버 외부 탭)
        XCTAssertFalse(app.buttons["delete-confirm-button"].exists, "메뉴가 닫혀야 한다")
        capture("server-note-menu-touch-after-below-tap")

        // 행이 여전히 존재해야 한다
        XCTAssertTrue(serverNoteRow.exists, "행이 삭제되지 않았어야 한다")
    }
}
