// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import AppKit

/// Older systems cannot resolve Icon Composer appearances in Finder.
/// Keep their running Dock icon in sync without changing files or preferences.
@MainActor
final class AppearanceDockIcon {
    private let light: NSImage
    private let dark: NSImage
    private var observation: NSKeyValueObservation?

    init?(bundle: Bundle) {
        guard let lightURL = bundle.url(forResource: "RecallLight", withExtension: "icns"),
              let darkURL = bundle.url(forResource: "RecallDark", withExtension: "icns"),
              let light = NSImage(contentsOf: lightURL),
              let dark = NSImage(contentsOf: darkURL) else { return nil }
        self.light = light
        self.dark = dark
        observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] application, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                application.applicationIconImage = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? self.dark : self.light
            }
        }
    }
}
