import SwiftUI

/// 아이폰·아이패드와 Mac에서 같은 화면 코드를 쓰기 위한 작은 도우미.
#if os(macOS)
/// macOS에는 크기 등급이 없어 항상 넓은 화면(아이패드 배치)으로 그린다.
enum SizeClassShim: Hashable { case compact, regular }
#endif

extension ToolbarItemPlacement {
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
    static var bottomBarOrAuto: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

extension View {
    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func largeTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }
    @ViewBuilder func whiteNavigationBar() -> some View {
        #if os(iOS)
        toolbarBackground(Color.white, for: .navigationBar)
        #else
        self
        #endif
    }
    @ViewBuilder func editModeActive() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
    @ViewBuilder func emailEntry() -> some View {
        #if os(iOS)
        textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        textContentType(.username).autocorrectionDisabled()
        #endif
    }
    /// 아이폰·아이패드는 전체 화면, Mac은 시트
    @ViewBuilder func coverOrSheet<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) { content().frame(minWidth: 460, minHeight: 560) }
        #endif
    }
}
