import SwiftUI
import WebKit

/// 서버가 그리는 회의록 보기·편집 화면(report.html)을 그대로 띄움.
/// 페이지의 저장/되돌리기 요청에 앱 토큰을 붙이고, 인쇄·확인창은 iOS 기본 UI로 연결.
@MainActor
final class ReportWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var loading = true
    @Published var loadError: String?
    /// 페이지 상태 (페이지 도구 막대는 숨기고 앱 툴바로 조작)
    @Published var saveText = ""
    @Published var dirty = false
    @Published var edited = false
    @Published var docType = "meeting"
    @Published var conf = true
    @Published var wm = true
    private(set) var webView: WKWebView!
    private var origin = ""
    private var lastAuthReload = Date.distantPast

    func make(meetingID: Int) -> WKWebView {
        if let webView { return webView }
        let token = AppConfig.shared.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenJS = (try? String(data: JSONSerialization.data(withJSONObject: [token]), encoding: .utf8)) ?? "[\"\"]"
        let script = """
        (function(){
          var T = \(tokenJS)[0];
          var of = window.fetch;
          window.fetch = function(input, init){
            init = init || {};
            var url = (typeof input === 'string') ? input : input.url;
            var abs = new URL(url, location.href);
            if (abs.origin === location.origin) {
              var h = new Headers(init.headers || (typeof input !== 'string' ? input.headers : undefined) || {});
              h.set('Authorization', 'Bearer ' + T);
              init.headers = h;
            }
            return of.call(this, input, init);
          };
          window.print = function(){ window.webkit.messageHandlers.malgeulPrint.postMessage(document.title || ''); };
        })();
        """
        // 앱 안에서는: 페이지 도구 막대 숨김(앱 툴바로 대신) + 좁은 화면에선 A4 폭을 화면에 맞춤(확대해도 메뉴는 그대로)
        let appScript = """
        (function(){
          var css=document.createElement('style');
          css.textContent='.bar{display:none!important} .sheet{margin-top:12px!important;margin-bottom:24px!important} @media print{.sheet{zoom:1!important}}';
          document.head.appendChild(css);
          function fit(){
            var s=document.querySelector('.sheet'); if(!s) return;
            s.style.zoom='';
            var w=document.documentElement.clientWidth, sw=s.offsetWidth+16;
            if(sw>w) s.style.zoom=String(w/sw);
          }
          fit(); window.addEventListener('resize',fit);
          var b=document.body, st=document.getElementById('save-st');
          function send(){
            try{ window.webkit.messageHandlers.malgeulState.postMessage({
              save:(st&&st.textContent)||'', dirty:!!(st&&st.classList.contains('dirty')), edited:!!b.dataset.edited,
              type:b.dataset.type||'meeting', conf:b.dataset.conf!=='off', wm:b.dataset.wm!=='off'}); }catch(e){}
          }
          new MutationObserver(send).observe(b,{attributes:true,attributeFilter:['data-type','data-conf','data-wm','data-edited']});
          if(st) new MutationObserver(send).observe(st,{childList:true,characterData:true,subtree:true,attributes:true});
          window.__malgeul={
            save:function(){var x=document.getElementById('btn-save'); if(x)x.click();},
            revert:function(){var x=document.getElementById('btn-revert'); if(x)x.click();},
            type:function(t){var x=document.querySelector('#seg-type button[data-v="'+t+'"]'); if(x)x.click();},
            toggle:function(id){var x=document.getElementById(id); if(x){x.checked=!x.checked; x.dispatchEvent(new Event('change'));}}
          };
          send();
        })();
        """
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: appScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ucc.add(WeakScriptHandler(self), name: "malgeulPrint")
        ucc.add(WeakScriptHandler(self), name: "malgeulState")
        cfg.userContentController = ucc
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.isInspectable = true
        webView = wv
        if let req = try? API.shared.request("meetings/\(meetingID)/report.html") {
            origin = req.url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? ""
            wv.load(req)
        }
        return wv
    }

    func reload() {
        guard let url = webView?.url ?? webView?.backForwardList.currentItem?.url else { return }
        var r = URLRequest(url: url)
        r.setValue(API.shared.authHeader, forHTTPHeaderField: "Authorization")
        webView.load(r)
    }

    /// 페이지에 저장 안 한 수정이 있는지 (save-st 에 dirty 표시)
    func isDirty() async -> Bool {
        guard let webView else { return false }
        let v = try? await webView.evaluateJavaScript("(function(){var s=document.getElementById('save-st');return !!(s&&s.classList.contains('dirty'))})()")
        return (v as? Bool) ?? false
    }

    // MARK: 탐색 — 같은 서버로 가는 본문 요청엔 토큰 헤더를 다시 붙임 (location.reload 등)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let req = action.request
        guard let u = req.url else { return .allow }
        let o = "\(u.scheme ?? "")://\(u.host ?? "")"
        if o == origin, action.targetFrame?.isMainFrame ?? true, req.value(forHTTPHeaderField: "Authorization") == nil,
           Date().timeIntervalSince(lastAuthReload) > 2 {
            lastAuthReload = Date()
            var r = URLRequest(url: u)
            r.setValue(API.shared.authHeader, forHTTPHeaderField: "Authorization")
            webView.load(r)
            return .cancel
        }
        if o != origin, u.scheme == "http" || u.scheme == "https", action.navigationType == .linkActivated {
            await UIApplication.shared.open(u)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let h = response.response as? HTTPURLResponse, response.isForMainFrame, !(200..<300).contains(h.statusCode) {
            loadError = h.statusCode == 404 ? "생성된 문서가 없습니다" : h.statusCode == 401 ? "로그인이 필요합니다" : "HTTP \(h.statusCode)"
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if !error.isCancellation { loadError = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if !error.isCancellation && (error as NSError).code != 102 { loadError = error.localizedDescription }
    }

    // MARK: 인쇄 (페이지의 '인쇄 / PDF 저장' 버튼)
    func run(_ js: String) { webView?.evaluateJavaScript("window.__malgeul && window.__malgeul.\(js)", completionHandler: nil) }
    func printDoc() { webView?.evaluateJavaScript("window.print()", completionHandler: nil) }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "malgeulState", let o = message.body as? [String: Any] {
            saveText = o["save"] as? String ?? ""
            dirty = o["dirty"] as? Bool ?? false
            edited = o["edited"] as? Bool ?? false
            docType = o["type"] as? String ?? "meeting"
            conf = o["conf"] as? Bool ?? true
            wm = o["wm"] as? Bool ?? true
            return
        }
        guard message.name == "malgeulPrint", let webView else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = (message.body as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "회의록"
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info
        pc.printFormatter = webView.viewPrintFormatter()
        pc.present(animated: true)
    }

    // MARK: alert / confirm
    private func topVC() -> UIViewController? {
        var vc = webView?.window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard let vc = topVC() else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "확인", style: .default) { _ in c.resume() })
            vc.present(a, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let vc = topVC() else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in c.resume(returning: false) })
            a.addAction(UIAlertAction(title: "확인", style: .destructive) { _ in c.resume(returning: true) })
            vc.present(a, animated: true)
        }
    }
}

/// 메시지 핸들러가 컨트롤러를 붙잡아 두지 않도록 약한 참조로 중계
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

struct ReportWebContainer: UIViewRepresentable {
    let meetingID: Int
    let controller: ReportWebController
    func makeUIView(context: Context) -> WKWebView { controller.make(meetingID: meetingID) }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct ReportWebView: View {
    let meetingID: Int
    var onSaved: () -> Void
    @StateObject private var controller = ReportWebController()
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false

    var body: some View {
        ReportWebContainer(meetingID: meetingID, controller: controller)
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if let e = controller.loadError {
                    ContentUnavailableView("문서를 열 수 없습니다", systemImage: "doc.questionmark", description: Text(e))
                        .background(.background)
                } else if controller.loading {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            if await controller.isDirty() { confirmLeave = true } else { onSaved(); dismiss() }
                        }
                    } label: { Label("뒤로", systemImage: "chevron.backward") }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("보기·편집").font(.headline)
                        if !controller.saveText.isEmpty {
                            Text(controller.saveText).font(.caption2)
                                .foregroundStyle(controller.dirty ? Color.red : Color.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") { controller.run("save()") }
                        .fontWeight(controller.dirty ? .semibold : .regular)
                        .disabled(controller.loadError != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { controller.printDoc() } label: { Label("인쇄 / PDF 저장", systemImage: "printer") }
                        if controller.edited {
                            Button(role: .destructive) { controller.run("revert()") } label: { Label("자동 작성본으로", systemImage: "arrow.uturn.backward") }
                        }
                        Section("문서 유형") {
                            Picker("문서 유형", selection: Binding(get: { controller.docType }, set: { controller.run("type('\($0)')") })) {
                                Text("회의록").tag("meeting")
                                Text("출장복명서").tag("trip")
                            }
                        }
                        Section {
                            Toggle("CONFIDENTIAL 표시", isOn: Binding(get: { controller.conf }, set: { _ in controller.run("toggle('opt-conf')") }))
                            Toggle("배경 워터마크", isOn: Binding(get: { controller.wm }, set: { _ in controller.run("toggle('opt-wm')") }))
                        }
                        Button { controller.loadError = nil; controller.reload() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                    } label: {
                        Label("더 보기", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("저장하지 않은 수정 내용이 있습니다. 나갈까요?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("저장하지 않고 나가기", role: .destructive) { onSaved(); dismiss() }
            }
    }
}
