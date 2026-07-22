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

import XCTest

nonisolated final class SampleAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    @MainActor
    func testLoadingLabCanDeleteCacheAndFinishRequest() {
        launch(.loadingLab)

        XCTAssertTrue(element(A11y.loadingLabScreen).waitForExistence(timeout: 3))
        XCTAssertTrue(element(A11y.entry(10)).waitForExistence(timeout: 2))

        let deleteCache = app.buttons[A11y.loadingLabDeleteCache]
        scrollUntilHittable(deleteCache, direction: .up)
        deleteCache.tap()
        XCTAssertFalse(element(A11y.entry(10)).exists)

        let requestStage = app.segmentedControls[A11y.loadingLabStage]
        scrollUntilHittable(requestStage, direction: .down)
        requestStage.buttons["In-flight"].tap()
        XCTAssertTrue(element(A11y.entry(0)).waitForExistence(timeout: 2))

        requestStage.buttons["Finished"].tap()

        XCTAssertTrue(element(A11y.entry(101)).waitForExistence(timeout: 3))
    }

    @MainActor
    func testScreenReplacementRetriesWithFreshSource() {
        launch(.screenReplacement)

        XCTAssertTrue(element(A11y.screenReplacementFailure).waitForExistence(timeout: 3))

        let retry = app.buttons[A11y.screenReplacementRetry]
        XCTAssertTrue(retry.waitForExistence(timeout: 2))
        retry.tap()

        XCTAssertTrue(element(A11y.entry(30)).waitForExistence(timeout: 3))
        XCTAssertFalse(element(A11y.screenReplacementFailure).exists)
    }

    @MainActor
    func testSeededValueSurvivesFailedRefreshAndCanBeReplaced() {
        launch(.cachedRefresh)

        XCTAssertTrue(element(A11y.cachedRefreshScreen).waitForExistence(timeout: 3))
        XCTAssertTrue(element(A11y.entry(10)).waitForExistence(timeout: 2))

        app.buttons[A11y.cachedRefreshFailure].tap()
        XCTAssertTrue(element(A11y.entry(10)).exists, "Seeded content disappeared during refresh")
        XCTAssertTrue(waitForLabelContaining("refresh failed", on: app.staticTexts[A11y.cachedRefreshPhase]))
        XCTAssertTrue(element(A11y.entry(10)).exists, "Seeded content disappeared after failure")

        app.buttons[A11y.cachedRefreshSuccess].tap()
        XCTAssertTrue(element(A11y.entry(20)).waitForExistence(timeout: 3))

        app.buttons[A11y.cachedRefreshDirect].tap()
        XCTAssertTrue(element(A11y.entry(200)).waitForExistence(timeout: 2))
    }

    @MainActor
    func testSectionsResolveAndRetryIndependently() {
        launch(.independentSections)

        XCTAssertTrue(element(A11y.independentSectionsScreen).waitForExistence(timeout: 3))
        XCTAssertTrue(element(A11y.entry(10)).waitForExistence(timeout: 2))
        XCTAssertTrue(element(A11y.entry(300)).waitForExistence(timeout: 3))
        XCTAssertTrue(element(A11y.failure("tip")).waitForExistence(timeout: 3))
        XCTAssertTrue(element(A11y.entry(10)).exists, "Cached account content disappeared after failure")

        let retryTip = app.buttons[A11y.failureRetry("tip")]
        XCTAssertTrue(retryTip.waitForExistence(timeout: 2))
        retryTip.tap()
        XCTAssertTrue(element(A11y.independentSectionsTip).waitForExistence(timeout: 3))

        let reload = app.buttons[A11y.independentSectionsReload]
        XCTAssertTrue(reload.waitForExistence(timeout: 2))
        reload.tap()
        XCTAssertTrue(element(A11y.entry(400)).waitForExistence(timeout: 4))
    }

    @MainActor
    private func launch(_ scenario: Scenario) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI_TESTING", "--scenario=\(scenario.rawValue)"]
        app.launch()
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func waitForLabelContaining(_ text: String, on element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: 3
        ) == .completed
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        direction: SwipeDirection,
        attempts: Int = 5
    ) {
        for _ in 0..<attempts where element.isHittable == false {
            switch direction {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
        }
        XCTAssertTrue(element.isHittable)
    }
}

private enum Scenario: String {
    case loadingLab = "loading-lab"
    case screenReplacement = "screen-replacement"
    case cachedRefresh = "cached-refresh"
    case independentSections = "independent-sections"
}

private enum A11y {
    static let loadingLabScreen = "sample.loading-lab.screen"
    static let loadingLabStage = "sample.loading-lab.stage"
    static let loadingLabDeleteCache = "sample.loading-lab.delete-cache"

    static let screenReplacementFailure = "sample.screen-replacement.failure"
    static let screenReplacementRetry = "sample.screen-replacement.retry"

    static let cachedRefreshScreen = "sample.cached-refresh.screen"
    static let cachedRefreshPhase = "sample.cached-refresh.phase"
    static let cachedRefreshSuccess = "sample.cached-refresh.success"
    static let cachedRefreshFailure = "sample.cached-refresh.failure"
    static let cachedRefreshDirect = "sample.cached-refresh.direct"

    static let independentSectionsScreen = "sample.independent-sections.screen"
    static let independentSectionsReload = "sample.independent-sections.reload"
    static let independentSectionsTip = "sample.independent-sections.tip"

    static func entry(_ id: Int) -> String { "sample.entry.\(id)" }
    static func failure(_ name: String) -> String { "sample.failure.\(name)" }
    static func failureRetry(_ name: String) -> String { "sample.failure.\(name).retry" }
}

private enum SwipeDirection {
    case up
    case down
}
