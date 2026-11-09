import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        NavigationStack {
            Form {
                ServerSection()
                TailscaleSection()

                Section("녹음") {
                    Toggle("녹음 업로드 후 바로 받아쓰기", isOn: $config.autoTranscribeRecordings)
                    Toggle("업로드가 끝난 녹음은 기기에서 지우기", isOn: $config.deleteAfterUpload)
                }

                ProcessingSection()

                Section("정보") {
                    LabeledContent("버전", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    if let u = URL(string: config.server) {
                        Link(destination: u) { Label("웹에서 열기", systemImage: "safari") }
                    }
                }
            }
            .navigationTitle("설정")
        }
    }
}

/// 연결 상태 점: 초록 = 연결됨, 빨강 = 안 됨, 회색 = 주소 없음, 주황 깜빡임 = 확인 중
struct StatusDot: View {
    enum Kind: Equatable { case ok, fail, none, checking }
    let kind: Kind

    private var color: Color {
        switch kind {
        case .ok: return .green
        case .fail: return .red
        case .none: return Color.secondary.opacity(0.4)
        case .checking: return .orange
        }
    }

    var body: some View {
        Group {
            if kind == .checking {
                Circle().fill(color)
                    .phaseAnimator([1.0, 0.25]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.6) }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(kind == .ok ? "연결됨" : kind == .fail ? "연결 안 됨" : kind == .checking ? "확인 중" : "주소 없음")
    }
}

/// 서버: 입력돼 있으면 주소·토큰 칸 없이 상태만. 연결 안 되면 '재연결'. '서버 변경'을 누르면 입력 칸
private struct ServerSection: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: MeetingStore

    @State private var editing = false
    @State private var server = ""
    @State private var token = ""
    @State private var kind: StatusDot.Kind = .checking
    @State private var detail: String?

    private var host: String { URL(string: config.server)?.host() ?? config.server }

    var body: some View {
        Section {
            if config.isConfigured && !editing {
                HStack(spacing: 10) {
                    StatusDot(kind: kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host).lineLimit(1)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(kind == .fail ? Color.red : Color.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if kind == .fail {
                        Button("재연결") { Task { await check() } }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                Button("서버 변경") {
                    server = config.server
                    token = config.token
                    editing = true
                }
            } else {
                TextField("서버 주소 (https://…)", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("앱 토큰", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Button {
                        Task { await saveAndCheck() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("저장하고 연결")
                            if kind == .checking && editing { ProgressView() }
                        }
                    }
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if editing && config.isConfigured {
                        Button("취소", role: .cancel) { editing = false; Task { await check() } }
                            .buttonStyle(.borderless)
                    }
                }
                if let detail, kind == .fail {
                    Text(detail).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("서버")
        } footer: {
            if !config.isConfigured || editing {
                Text("앱은 서버의 앱 전용 주소(/app/api)를 토큰으로 호출합니다. 토큰은 이 기기의 키체인에만 저장됩니다.")
            }
        }
        .task(id: config.token + config.server) {
            if config.isConfigured && !editing { await check() }
        }
    }

    private func check() async {
        kind = .checking
        detail = nil
        do {
            let d = try await API.shared.meetingsRaw()
            let n = (try? JSONDecoder().decode([Meeting].self, from: d))?.count ?? 0
            kind = .ok
            detail = "회의 \(n)건"
        } catch {
            if error.isCancellation { return }
            kind = .fail
            detail = error.localizedDescription
        }
    }

    private func saveAndCheck() async {
        editing = true
        config.server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        config.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        await check()
        if kind == .ok {
            editing = false
            await store.refresh()
        }
    }
}

/// Tailscale 직통 주소: 주소 칸 옆에 상태 점(누르면 다시 확인)
private struct TailscaleSection: View {
    @EnvironmentObject private var config: AppConfig
    @State private var address = ""
    @State private var kind: StatusDot.Kind = .none

    var body: some View {
        Section {
            HStack(spacing: 6) {
                TextField("Tailscale 직통 주소 (선택)", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await probe() } }
                Button { Task { await probe() } } label: {
                    StatusDot(kind: kind).padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("다시 확인")
            }
        } header: {
            Text("Tailscale")
        } footer: {
            Text("점을 누르면 다시 확인합니다. 연결되어 있으면 업로드는 직통 주소로 가고, 100MB가 넘는 파일은 이때만 올릴 수 있어요.")
        }
        .task {
            address = config.tailscaleServer
            await probe()
        }
    }

    private func probe() async {
        config.tailscaleServer = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.tailscaleServer.isEmpty else { kind = .none; return }
        kind = .checking
        kind = await API.shared.probeTailscale() ? .ok : .fail
    }
}
