//
//  KleynApp.swift
//  Kleyn
//
//  Created by Tyastono Taufiq on 29/10/26.
//

import SwiftUI

@main
struct KleynApp: App {
    @State private var locker = KeyboardLocker()
    @State private var screenCleaner = ScreenCleaner()

    var body: some Scene {
        Window("Kleyn", id: "main") {
            ContentView(locker: locker, screenCleaner: screenCleaner)
        }
        .windowResizability(.contentSize)
    }
}
