//
//  Copyright (c) 2026 @mtzaquia
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Ensemble
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum SampleScenario: String, CaseIterable, Identifiable {
    case loadingLab = "loading-lab"
    case screenReplacement = "screen-replacement"
    case cachedRefresh = "cached-refresh"
    case animatedReordering = "animated-reordering"
    case independentSections = "independent-sections"

    var id: Self { self }

    var title: String {
        switch self {
        case .loadingLab: "Loading lab"
        case .screenReplacement: "Screen replacement"
        case .cachedRefresh: "Cached refresh"
        case .animatedReordering: "Animated reordering"
        case .independentSections: "Independent sections"
        }
    }

    var detail: String {
        switch self {
        case .loadingLab:
            "Switch request states, tune latency, clear the cache, and trigger failures."
        case .screenReplacement:
            "Placeholder loading, a blocking failure, and retry."
        case .cachedRefresh:
            "Seeded data remains visible through loading and failure."
        case .animatedReordering:
            "Placeholder-first loading, smart updates, stable-ID reordering, and an explicit nil opt-out."
        case .independentSections:
            "Several streams drive separate parts of one list."
        }
    }

    var systemImage: String {
        switch self {
        case .loadingLab: "slider.horizontal.3"
        case .screenReplacement: "rectangle.portrait.slash"
        case .cachedRefresh: "arrow.trianglehead.2.clockwise.rotate.90"
        case .animatedReordering: "arrow.up.arrow.down"
        case .independentSections: "rectangle.3.group"
        }
    }
}

struct ScenarioDestination: View {
    let scenario: SampleScenario

    var body: some View {
        switch scenario {
        case .loadingLab:
            LoadingLabExample()
        case .screenReplacement:
            ScreenReplacementExample()
        case .cachedRefresh:
            CachedRefreshExample()
        case .animatedReordering:
            AnimatedReorderingExample()
        case .independentSections:
            IndependentSectionsExample()
        }
    }
}

enum SampleAppUITesting {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("UI_TESTING")

    static let initialScenario: SampleScenario? = ProcessInfo.processInfo.arguments
        .first(where: { $0.hasPrefix("--scenario=") })
        .flatMap { SampleScenario(rawValue: String($0.dropFirst("--scenario=".count))) }

    @MainActor
    static func configure() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        UIView.setAnimationsEnabled(false)
        #endif
    }
}

enum SampleAppAccessibility {
    static let catalog = "sample.catalog"
    static func scenarioLink(_ scenario: SampleScenario) -> String { "sample.catalog.\(scenario.rawValue)" }

    static let loadingLabScreen = "sample.loading-lab.screen"
    static let loadingLabStage = "sample.loading-lab.stage"
    static let loadingLabStart = "sample.loading-lab.start"
    static let loadingLabNoContent = "sample.loading-lab.no-content"
    static let loadingLabDeleteCache = "sample.loading-lab.delete-cache"
    static let loadingLabRestoreCache = "sample.loading-lab.restore-cache"
    static let loadingLabFailure = "sample.loading-lab.failure"
    static let loadingLabHistory = "sample.loading-lab.history"
    static let loadingLabClearHistory = "sample.loading-lab.history.clear"

    static let screenReplacementContent = "sample.screen-replacement.content"
    static let screenReplacementFailure = "sample.screen-replacement.failure"
    static let screenReplacementRetry = "sample.screen-replacement.retry"

    static let cachedRefreshScreen = "sample.cached-refresh.screen"
    static let cachedRefreshPhase = "sample.cached-refresh.phase"
    static let cachedRefreshSuccess = "sample.cached-refresh.success"
    static let cachedRefreshFailure = "sample.cached-refresh.failure"
    static let cachedRefreshDirect = "sample.cached-refresh.direct"

    static let animatedReorderingScreen = "sample.animated-reordering.screen"
    static let animatedReorderingReverse = "sample.animated-reordering.reverse"
    static let animatedReorderingSibling = "sample.animated-reordering.sibling"
    static let animatedReorderingAnimation = "sample.animated-reordering.animation"
    static let animatedReorderingSource = "sample.animated-reordering.source"
    static let animatedReorderingHide = "sample.animated-reordering.hide"
    static let animatedReorderingRestore = "sample.animated-reordering.restore"

    static let independentSectionsScreen = "sample.independent-sections.screen"
    static let independentSectionsReload = "sample.independent-sections.reload"
    static let independentSectionsTip = "sample.independent-sections.tip"

    static func entry(_ id: Int) -> String { "sample.entry.\(id)" }
    static func source(_ source: AsyncContentSource) -> String {
        switch source {
        case .latest: "sample.source.latest"
        case .retained: "sample.source.retained"
        case .placeholder: "sample.source.placeholder"
        }
    }

    static func failure(_ name: String) -> String { "sample.failure.\(name)" }
    static func failureRetry(_ name: String) -> String { "sample.failure.\(name).retry" }
}
