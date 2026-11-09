import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var device: OnDeviceJobCenter
    @EnvironmentObject private var voices: VoiceProfiles

    @State private var server = ""
    @State private var token = ""
    @State private var tailscale = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false
    @State private var tsState: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("서버 주소 (https://…)", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("앱 토큰", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        Task { await saveAndCheck() }
                    } label: {
                        HStack {
                            Text("저장하고 연결 확인")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(checking || server.isEmpty)
                    if let checkResult {
                        Label(checkResult, systemImage: checkOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(checkOK ? Color.green : Color.red)
                            .font(.footnote)
                    }
                } header: {
                    Text("서버")
                } footer: {
                    Text("앱은 서버의 앱 전용 주소(/app/api)를 토큰으로 호출합니다. 토큰은 이 기기의 키체인에만 저장됩니다.")
                }

                Section {
                    TextField("Tailscale 직통 주소 (선택)", text: $tailscale)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { config.tailscaleServer = tailscale }
                    HStack {
                        Text("상태")
                        Spacer()
                        switch tsState {
                        case .none: ProgressView()
                        case .some(true): Label("연결됨", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(.green)
                        case .some(false): Text(tailscale.isEmpty ? "주소 없음" : "연결 안 됨").foregroundStyle(.secondary)
                        }
                    }
                    Button("다시 확인") { Task { await probe() } }
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("Tailscale이 연결되어 있으면 업로드는 직통 주소로 갑니다. 100MB가 넘는 파일은 Tailscale 연결 시에만 올릴 수 있어요.")
                }

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
            .onAppear {
                server = config.server
                token = config.token
                tailscale = config.tailscaleServer
            }
            .task { await probe() }
        }
    }

    private func probe() async {
        config.tailscaleServer = tailscale.trimmingCharacters(in: .whitespacesAndNewlines)
        tsState = nil
        tsState = await API.shared.probeTailscale()
    }

    private func saveAndCheck() async {
        config.server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        config.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        config.tailscaleServer = tailscale.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        defer { checking = false }
        do {
            let d = try await API.shared.meetingsRaw()
            let n = (try? JSONDecoder().decode([Meeting].self, from: d))?.count ?? 0
            checkOK = true
            checkResult = "연결됨 · 회의 \(n)건"
            await store.refresh()
        } catch {
            checkOK = false
            checkResult = error.localizedDescription
        }
    }
}
