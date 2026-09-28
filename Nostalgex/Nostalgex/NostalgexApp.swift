//
//  NostalgexApp.swift
//  Nostalgex
//
//  Created by Chad Mueller on 2026-03-19.
//

import SwiftUI
import CoreText

@main
struct NostalgexApp: App {
    @State private var appState = AppState()

    init() {
        Self.registerCustomFonts()
        Self.configureAnalytics()
        // Now Playing only surfaces for an app with an active .playback session.
        NowPlayingInfoService.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }

    private static func configureAnalytics() {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isRunningTests, TelemetryDeckConfig.isConfigured else {
            Analytics.configure(with: NoOpAnalytics())
            return
        }
        Analytics.configure(with: TelemetryDeckAnalytics(appID: TelemetryDeckConfig.appID))
    }

    private static func registerCustomFonts() {
        let fonts = ["DMMono-Regular", "DMMono-Medium", "VT323-Regular"]
        for name in fonts {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("[Nostalgex] Font file \(name).ttf not found in bundle")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
