import SwiftUI

private let suggestions = ["주요 결정사항을 정리해줘", "액션 아이템과 담당자를 뽑아줘", "회의 요약을 3줄로 해줘", "다음 회의 안건으로 뭐가 좋을까?"]

/// 회의 스크립트 기반 질문 (서버 LLM 체인, SSE 스트리밍). 대화 기록은 서버에 저장됨.
struct ChatView: View {
    let meetingID: Int

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var sending = false
    @State private var historyLoaded = false
    @State private var confirmClear = false
    @State private var streamTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if historyLoaded && messages.isEmpty { empty }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            inputBar
        }
        .background(Color(.systemGroupedBackground))
        .task(id: meetingID) { await loadHistory() }
        .onDisappear { streamTask?.cancel() }
        .confirmationDialog("대화 기록을 모두 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                Task {
                    try? await API.shared.clearChat(meetingID)
                    messages = []
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.accentJulglo)
            Text("Claude에게 질문").font(.headline)
            Text("스크립트 기반").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !messages.isEmpty {
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("대화 기록 지우기")
                    .disabled(sending)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("✦").font(.title).foregroundStyle(.accentJulglo)
            Text("회의 스크립트에 대해 무엇이든 물어보세요").font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == "user" {
            HStack {
                Spacer(minLength: 40)
                Text(m.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentJulglo, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if m.text.isEmpty && m.streaming {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("생각 중…").font(.caption).foregroundStyle(.secondary) }
                } else {
                    MarkdownText(text: m.text)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                Button { UIPasteboard.general.string = m.text } label: { Label("복사", systemImage: "doc.on.doc") }
                ShareLink(item: m.text)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("질문 입력", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onSubmit { send(nil) }
                .submitLabel(.send)
            Button { send(nil) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("전송")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func loadHistory() async {
        do {
            let h = try await API.shared.chatHistory(meetingID)
            if !sending { messages = h }
        } catch {}
        historyLoaded = true
    }

    private func send(_ question: String?) {
        let q = (question ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !sending else { return }
        input = ""
        messages.append(ChatMessage(role: "user", text: q))
        messages.append(ChatMessage(role: "assistant", text: "", streaming: true))
        sending = true
        streamTask = Task {
            defer { sending = false }
            do {
                for try await ev in API.shared.chat(meetingID, question: q) {
                    let type = ev["type"] as? String
                    guard let i = messages.indices.last else { break }
                    if type == "chunk", let t = ev["text"] as? String {
                        messages[i].text += t
                    } else if type == "done" {
                        messages[i].streaming = false
                    } else if type == "error" {
                        // 오류면 말풍선에 표시 (답변 일부가 이미 나왔으면 뒤에 덧붙임)
                        let msg = ev["message"] as? String ?? "오류"
                        messages[i].text = messages[i].text.isEmpty ? "⚠️ \(msg)" : messages[i].text + "\n\n⚠️ \(msg)"
                        messages[i].streaming = false
                    }
                }
                if let i = messages.indices.last { messages[i].streaming = false }
            } catch {
                if let i = messages.indices.last {
                    messages[i].streaming = false
                    if !error.isCancellation { messages[i].text = "오류: \(error.localizedDescription)" }
                }
            }
        }
    }
}

// MARK: - 마크다운 (제목·목록·표·코드·인용·구분선 + 인라인 강조/링크)

struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String), paragraph(String), bullet(String, Int), ordered(String, String, Int)
        case quote(String), code(String), table([[String]]), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in view(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ b: Block) -> some View {
        switch b {
        case .heading(let lv, let t):
            inline(t).font(lv <= 1 ? .title3.bold() : lv == 2 ? .headline : .subheadline.bold()).padding(.top, 4)
        case .paragraph(let t):
            inline(t)
        case .bullet(let t, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(t) }.padding(.leading, CGFloat(depth) * 14)
        case .ordered(let n, let t, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text(n).monospacedDigit(); inline(t) }.padding(.leading, CGFloat(depth) * 14)
        case .quote(let t):
            inline(t).foregroundStyle(.secondary).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t).font(.system(.footnote, design: .monospaced)).padding(10)
            }
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        GridRow {
                            ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                inline(c).font(i == 0 ? .footnote.bold() : .footnote)
                            }
                        }
                        if i == 0 { Divider() }
                    }
                }
                .padding(10)
            }
            .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var table: [[String]] = []
        var code: [String]? = nil
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flushPara(); flushTable(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix("|") {
                flushPara()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }   // 구분 행
                table.append(cells)
                continue
            }
            flushTable()
            if line.isEmpty { flushPara(); continue }
            let depth = (raw.prefix { $0 == " " }.count) / 2
            if let m = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushPara(); out.append(.heading(line[m].count - 1, String(line[m.upperBound...]))); continue
            }
            if line == "---" || line == "***" || line == "___" { flushPara(); out.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushPara(); out.append(.bullet(String(line.dropFirst(2)), depth)); continue
            }
            if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushPara(); out.append(.ordered(String(line[m]).trimmingCharacters(in: .whitespaces), String(line[m.upperBound...]), depth)); continue
            }
            if line.hasPrefix(">") { flushPara(); out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara(); flushTable()
        return out
    }
}
