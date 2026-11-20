import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// 설정 > 문서화 (웹 설정의 ‘문서화’와 같은 항목)
struct DocSettingsView: View {
    @State private var s = DocSettings()
    @State private var loaded = false
    @State private var config: DocConfig?
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var wmItem: PhotosPickerItem?
    @State private var logoItem: PhotosPickerItem?
    @State private var cellsText = ""
    @State private var showPreview = false

    private var types: [DocTypeInfo] { config?.types ?? [] }

    var body: some View {
        Form {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                favoritesSection
                authorSection
                lookSection
                markSection
                fileSection
                vizSection
                Section {
                    Toggle("받아쓰기 끝나면 자동 문서화", isOn: $s.autoDoc)
                } footer: { Text("화자 추정까지 끝난 뒤 ‘추천’ 양식으로 문서 하나를 만듭니다.") }
                Section {
                    Button { showPreview = true } label: { Label("지금 설정으로 예시 문서 보기", systemImage: "doc.richtext") }
                }
            }
        }
        .navigationTitle("문서화")
        .inlineTitle()
        .task { await load() }
        .onChange(of: s) { _, _ in if loaded { scheduleSave() } }
        .onChange(of: wmItem) { _, v in if let v { Task { await upload(v, kind: "wm") } } }
        .onChange(of: logoItem) { _, v in if let v { Task { await upload(v, kind: "logo") } } }
        .onDisappear { saveTask?.cancel(); Task { try? await API.shared.saveDocSettings(s) } }
        .navigationDestination(isPresented: $showPreview) {
            ReportWebView(meetingID: 0, path: "doc/preview", readOnly: true, onSaved: {})
        }
        .alert("오류", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: 항목

    private var favoritesSection: some View {
        Section {
            ForEach(0..<2, id: \.self) { (i: Int) in
                Picker("즐겨찾기 \(i + 1)", selection: Binding(
                    get: { i < s.favorites.count ? s.favorites[i] : "" },
                    set: { v in
                        var f = s.favorites
                        while f.count < 2 { f.append(types.first { !f.contains($0.key) }?.key ?? "meeting") }
                        if f[1 - i] == v { f[1 - i] = f[i] }
                        f[i] = v
                        s.favorites = f
                    })) {
                    ForEach(types) { (t: DocTypeInfo) in Text(t.name).tag(t.key) }
                }
            }
        } header: { Text("즐겨찾기 양식") } footer: { Text("녹취 화면의 문서화 탭에 ‘추천’과 함께 바로 보이는 두 양식") }
    }

    private var authorSection: some View {
        Section {
            TextField("기관 (예: 한국조폐공사)", text: $s.org)
            TextField("부서 (예: 영업처 판매운영부)", text: $s.dept)
            TextField("직급 (예: 4급)", text: $s.rank)
            TextField("이름", text: $s.name)
        } header: { Text("작성자 정보") } footer: { Text("문서 머리·작성자 칸·파일명에 들어갑니다. AI가 녹음 속 본인을 알아보는 데도 씁니다.") }
    }

    private var lookSection: some View {
        Section("모양") {
            Picker("색상 테마", selection: $s.theme) {
                ForEach(config?.themes ?? [], id: \.key) { (t: DocConfig.Named) in
                    Label { Text(t.name) } icon: { Circle().fill(Color(hexString: t.accent ?? "#1f4e8c")).frame(width: 14, height: 14) }.tag(t.key)
                }
            }
            Picker("글자 크기", selection: $s.fontSize) { Text("작게").tag("sm"); Text("보통").tag("md"); Text("크게").tag("lg") }
            Picker("문체", selection: $s.style) { Text("개조식").tag("gaejo"); Text("서술식").tag("prose") }
            Picker("분량", selection: $s.length) { Text("간결").tag("short"); Text("보통").tag("normal"); Text("상세").tag("long") }
        }
    }

    private var markSection: some View {
        Section {
            Toggle("CONFIDENTIAL 표시", isOn: $s.conf)
            Toggle("배경 워터마크", isOn: $s.watermark)
            if s.watermark {
                PhotosPicker(selection: $wmItem, matching: .images) {
                    Label(s.hasWmImage == true ? "워터마크 이미지 바꾸기" : "워터마크 이미지 올리기", systemImage: "photo")
                }
                if s.hasWmImage == true {
                    HStack {
                        Text("진하기")
                        Slider(value: Binding(get: { Double(s.wmOpacity) }, set: { s.wmOpacity = Int($0 / 5) * 5 }), in: 10...100)
                        Text("\(s.wmOpacity)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button("기본 워터마크로", role: .destructive) { Task { await clear("wm") } }
                }
            }
            PhotosPicker(selection: $logoItem, matching: .images) {
                Label(s.hasLogoImage == true ? "머리 로고 바꾸기" : "머리 로고 올리기", systemImage: "seal")
            }
            if s.hasLogoImage == true { Button("로고 지우기", role: .destructive) { Task { await clear("logo") } } }
            Toggle("결재란", isOn: $s.approval.on)
            if s.approval.on {
                TextField("칸 이름 (쉼표로 구분)", text: $cellsText)
                    .onSubmit { applyCells() }
                    .onChange(of: cellsText) { _, _ in applyCells() }
            }
        } header: { Text("표시") } footer: { Text("CONFIDENTIAL·워터마크는 새 문서의 기본값이고, 보기 화면에서 문서마다 바꿀 수 있습니다.") }
    }

    private var fileSection: some View {
        Section {
            Picker("기본 파일 형식", selection: $s.format) {
                ForEach(docFormatLabel, id: \.0) { (f: (String, String)) in Text(f.1).tag(f.0) }
            }
            TextField("파일 이름 규칙", text: $s.filename)
        } header: { Text("파일") } footer: {
            Text("쓸 수 있는 자리: {양식} {YYMMDD} {YYYYMMDD} {부서} {기관} {건명} {작성자}")
        }
    }

    private var vizSection: some View {
        Section {
            Picker("시각화", selection: $s.viz) {
                Text("필요할 때 자동").tag("auto"); Text("종류 직접 선택").tag("custom"); Text("쓰지 않음").tag("off")
            }
            if s.viz == "custom" {
                ForEach(config?.viz ?? [], id: \.key) { (v: DocConfig.Named) in
                    Toggle(v.name, isOn: Binding(
                        get: { s.vizAllowed.contains(v.key) },
                        set: { on in if on { if !s.vizAllowed.contains(v.key) { s.vizAllowed.append(v.key) } } else { s.vizAllowed.removeAll { $0 == v.key } } }))
                }
            }
        } header: { Text("시각화") } footer: { Text("그림은 대화에 근거(단계·날짜·숫자)가 있고 꼭 필요할 때만, 문서당 최대 2개") }
    }

    // MARK: 동작

    private func load() async {
        do {
            async let c = API.shared.docConfig()
            async let st = API.shared.docSettings()
            config = try await c
            s = try await st
            cellsText = s.approval.cells.joined(separator: ", ")
            loaded = true
        } catch { errorText = error.localizedDescription }
    }

    private func applyCells() {
        let cells = cellsText.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cells.isEmpty && cells != s.approval.cells { s.approval.cells = Array(cells.prefix(5)) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = s
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            do { _ = try await API.shared.saveDocSettings(snapshot) } catch { errorText = "저장 실패: " + error.localizedDescription }
        }
    }

    private func upload(_ item: PhotosPickerItem, kind: String) async {
        defer { if kind == "wm" { wmItem = nil } else { logoItem = nil } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            try await API.shared.uploadDocImage(kind: kind, dataURL: Self.dataURL(data))
            let fresh = try await API.shared.docSettings()
            loaded = false
            s.hasWmImage = fresh.hasWmImage; s.hasLogoImage = fresh.hasLogoImage
            if kind == "wm" { s.watermark = true }
            loaded = true
            scheduleSave()
        } catch { errorText = "이미지 올리기 실패: " + error.localizedDescription }
    }

    private func clear(_ kind: String) async {
        do {
            try await API.shared.deleteDocImage(kind: kind)
            loaded = false
            if kind == "wm" { s.hasWmImage = false } else { s.hasLogoImage = false }
            loaded = true
        } catch { errorText = error.localizedDescription }
    }

    /// 사진 → PNG data URL (긴 변 1600px까지 줄임)
    static func dataURL(_ data: Data) -> String {
        #if canImport(UIKit)
        if let img = UIImage(data: data) {
            let k = min(1, 1600 / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * k, height: img.size.height * k)
            let out = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            if let png = out.pngData() { return "data:image/png;base64," + png.base64EncodedString() }
        }
        #endif
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        return "data:image/\(isPNG ? "png" : "jpeg");base64," + data.base64EncodedString()
    }
}

extension Color {
    /// "#1f4e8c" → Color
    init(hexString: String) {
        let h = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(hex: UInt32(h, radix: 16) ?? 0x1F4E8C)
    }
}
