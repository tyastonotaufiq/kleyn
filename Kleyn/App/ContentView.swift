//
//  ContentView.swift
//  Kleyn
//
//  Created by Tyastono Taufiq on 29/10/26.
//

import SwiftUI

/// The pages in the sidebar.
enum Page: String, CaseIterable, Identifiable {
    case keepAwake, keyboard, screen, cleaner, uninstaller, adbExplorer

    var id: Self { self }

    var title: String {
        switch self {
        case .keyboard: "Keyboard Cleaning"
        case .screen: "Screen Cleaning"
        case .keepAwake: "Keep Awake"
        case .cleaner: "Cleaner"
        case .uninstaller: "Uninstaller"
        case .adbExplorer: "ADB Explorer"
        }
    }

    var systemImage: String {
        switch self {
        case .keyboard: "keyboard"
        case .screen: "display"
        case .keepAwake: "cup.and.saucer"
        case .cleaner: "internaldrive"
        case .uninstaller: "xmark.bin"
        case .adbExplorer: "smartphone"
        }
    }
}

struct ContentView: View {
    let locker: KeyboardLocker
    let screenCleaner: ScreenCleaner
    let keepAwake: KeepAwake
    let cleaner: Cleaner
    let uninstaller: Uninstaller
    let adbExplorer: AdbExplorer

    @SceneStorage("page") private var page: Page = .keepAwake
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: selection) { page in
                Label {
                    HStack {
                        Text(page.title)
                        Spacer()
                        if page == .keepAwake && keepAwake.isActive {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.green)
                                .accessibilityLabel("On")
                        }
                    }
                } icon: {
                    Image(systemName: page.systemImage)
                }
                .tag(page)
            }
            // Focus starts in the sidebar, as in Finder and System Settings, instead of in
            // the first text field of the page (Keep Awake's Until field).
            .focused($sidebarFocused)
            // AppKit picks the window's first text field as it opens, so take focus once it has.
            .task { sidebarFocused = true }
            // While the keyboard is locked, stay on the Keyboard Cleaning page so Unlock is always there.
            .disabled(locker.isLocked)
            .safeAreaInset(edge: .bottom) {
                Button("Quit Kleyn") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch page {
            case .keyboard:
                KeyboardView(locker: locker)
            case .screen:
                ScreenView(screenCleaner: screenCleaner, keyboardLocked: locker.isLocked)
            case .keepAwake:
                KeepAwakeView(keepAwake: keepAwake)
            case .cleaner:
                CleanerView(cleaner: cleaner)
            case .uninstaller:
                UninstallerView(uninstaller: uninstaller)
            case .adbExplorer:
                AdbExplorerView(explorer: adbExplorer)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .onChange(of: locker.isLocked) { _, isLocked in
            if isLocked { page = .keyboard }
        }
        // Keep the Unlock button reachable while the keyboard is locked.
        .windowDismissBehavior(locker.isLocked ? .disabled : .automatic)
        .windowMinimizeBehavior(locker.isLocked ? .disabled : .automatic)
    }

    /// The list's selection. A click on empty space can't leave the window without a page.
    private var selection: Binding<Page?> {
        Binding(
            get: { page },
            set: { newPage in
                guard let newPage, !locker.isLocked else { return }
                page = newPage
            }
        )
    }
}

#Preview {
    ContentView(locker: KeyboardLocker(), screenCleaner: ScreenCleaner(), keepAwake: KeepAwake(), cleaner: Cleaner(), uninstaller: Uninstaller(), adbExplorer: AdbExplorer())
}
