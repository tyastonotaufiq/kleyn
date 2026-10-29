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

    var body: some Scene {
        Window("Kleyn", id: "main") {
            ContentView(locker: locker)
        }
        .windowResizability(.contentSize)
    }
}
