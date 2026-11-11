import SwiftUI

/// 로그인 · 가입 신청 · 비밀번호 찾기 (웹과 같은 회원 계정)
struct LoginView: View {
    enum Mode { case login, signup, forgot }
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @FocusState private var focus: Int?

    private var title: String {
        switch mode { case .login: "로그인"; case .signup: "가입 신청"; case .forgot: "비밀번호 찾기" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if mode == .signup {
                        TextField("이름", text: $name).textContentType(.name).focused($focus, equals: 0)
                    }
                    TextField("이메일", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus, equals: 1)
                    if mode != .forgot {
                        SecureField(mode == .signup ? "비밀번호 (8자 이상)" : "비밀번호", text: $password)
                            .textContentType(mode == .signup ? .newPassword : .password).focused($focus, equals: 2)
                            .onSubmit { Task { await submit() } }
                    }
                } footer: {
                    switch mode {
                    case .signup: Text("관리자가 승인하면 메일로 알려 드립니다.")
                    case .forgot: Text("가입한 이메일로 비밀번호를 다시 정하는 링크를 보내 드립니다.")
                    case .login: EmptyView()
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
                if let notice {
                    Section { Text(notice).foregroundStyle(.green).font(.callout) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else {
                                Text(mode == .login ? "로그인" : mode == .signup ? "가입 신청" : "메일 보내기").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(busy || !valid)
                }
                Section {
                    if mode != .login { Button("로그인으로") { go(.login) } }
                    if mode != .signup { Button("가입 신청") { go(.signup) } }
                    if mode != .forgot { Button("비밀번호를 잊었어요") { go(.forgot) } }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 로그인 없이도 녹음은 할 수 있음
                    Button("나중에") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var valid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@") else { return false }
        switch mode {
        case .login: return !password.isEmpty
        case .signup: return password.count >= 8
        case .forgot: return true
        }
    }

    private func go(_ m: Mode) { mode = m; error = nil; notice = nil }

    private func submit() async {
        guard valid, !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch mode {
            case .login:
                try await API.shared.login(email: e, password: password)
                password = ""
                dismiss()
                await store.refresh()
            case .signup:
                notice = try await API.shared.signup(email: e, password: password, name: name.trimmingCharacters(in: .whitespaces))
                password = ""; mode = .login
            case .forgot:
                notice = try await API.shared.resetRequest(email: e)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 설정 > 계정: 이름·로그아웃·계정 삭제
struct AccountSection: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var router: Router
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmLogout = false
    @State private var deleting = false
    @State private var deletePw = ""
    @State private var error: String?

    var body: some View {
        Section {
            if let u = config.user, config.isConfigured {
                LabeledContent {
                    Button("이름 바꾸기") { newName = u.name; renaming = true }.buttonStyle(.borderless)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.name)
                        Text(u.email + (u.isAdmin ? " · 관리자" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if u.isAdmin, let url = URL(string: config.server + "/admin") {
                    Link(destination: url) { Label("관리자 화면 (웹)", systemImage: "person.badge.shield.checkmark") }
                }
                Button("로그아웃", role: .destructive) { confirmLogout = true }
                Button("계정 삭제", role: .destructive) { deletePw = ""; deleting = true }
                    .font(.footnote)
            } else {
                Button("로그인") { router.showLogin = true }
            }
        } header: {
            Text("계정")
        } footer: {
            if let error { Text(error).foregroundStyle(.red) }
        }
        .alert("이름", isPresented: $renaming) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("저장") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                Task { do { try await API.shared.rename(user: n) } catch { self.error = error.localizedDescription } }
            }
        }
        .confirmationDialog("로그아웃할까요? 이 기기에 있는 녹음은 그대로 남습니다.", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) { Task { await API.shared.logout() } }
        }
        .alert("계정 삭제", isPresented: $deleting) {
            SecureField("비밀번호", text: $deletePw)
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                Task { do { try await API.shared.deleteAccount(password: deletePw) } catch { self.error = error.localizedDescription } }
            }
        } message: {
            Text("모든 녹음·대화·회의록이 서버에서 바로 지워지고 되돌릴 수 없습니다. 계속하려면 비밀번호를 입력하세요.")
        }
    }
}

/// 설정 > 그룹: 올릴 그룹 고르기 · 만들기 · 이름 바꾸기 · 삭제
struct GroupsSection: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: MeetingStore
    @State private var adding = false
    @State private var renameTarget: MeetingGroup?
    @State private var text = ""
    @State private var deleteTarget: MeetingGroup?
    @State private var error: String?

    var body: some View {
        if config.isConfigured {
            Section {
                Picker("올릴 그룹", selection: Binding(get: { config.uploadGroup ?? store.groups.first(where: \.isDefault)?.id ?? 0 },
                                                   set: { config.uploadGroup = $0 })) {
                    ForEach(store.groups) { Text($0.name).tag($0.id) }
                }
                ForEach(store.groups) { (g: MeetingGroup) in
                    HStack {
                        Text(g.name)
                        if g.isDefault { Text("기본").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("노트 \(g.meetingCount)개").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { text = g.name; renameTarget = g } label: { Label("이름 바꾸기", systemImage: "pencil") }
                        if !g.isDefault {
                            Button(role: .destructive) { deleteTarget = g } label: { Label("삭제", systemImage: "trash") }
                        }
                    }
                    .swipeActions {
                        if !g.isDefault {
                            Button(role: .destructive) { deleteTarget = g } label: { Label("삭제", systemImage: "trash") }
                        }
                        Button { text = g.name; renameTarget = g } label: { Label("이름", systemImage: "pencil") }.tint(.gray)
                    }
                }
                Button { text = ""; adding = true } label: { Label("새 그룹", systemImage: "plus") }
            } header: {
                Text("그룹")
            } footer: {
                Text(error ?? "녹음을 그룹으로 나눠 봅니다. 화자 자동 추정은 같은 그룹의 노트끼리만 비교합니다. 이름을 바꾸거나 지우려면 그룹을 왼쪽으로 밀거나 길게 누르세요.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
            .task { await store.loadGroups() }
            .alert("새 그룹", isPresented: $adding) {
                TextField("이름", text: $text)
                Button("취소", role: .cancel) {}
                Button("만들기") { run { try await API.shared.createGroup(text) } }
            }
            .alert("그룹 이름", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }), presenting: renameTarget) { g in
                TextField("이름", text: $text)
                Button("취소", role: .cancel) {}
                Button("저장") { run { try await API.shared.renameGroup(g.id, text) } }
            }
            .confirmationDialog("그룹을 지울까요?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible, presenting: deleteTarget) { g in
                Button("‘\(g.name)’ 삭제", role: .destructive) {
                    if config.uploadGroup == g.id { config.uploadGroup = nil }
                    run { try await API.shared.deleteGroup(g.id); await store.refresh() }
                }
            } message: { g in
                Text(g.meetingCount > 0 ? "노트 \(g.meetingCount)개는 기본 그룹으로 옮겨집니다." : "빈 그룹입니다.")
            }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                error = nil
                await store.loadGroups()
            } catch { self.error = error.localizedDescription }
        }
    }
}
