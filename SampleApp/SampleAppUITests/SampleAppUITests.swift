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

        let succeededEvent = app.staticTexts["Request succeeded"]
        scrollUntilHittable(succeededEvent, direction: .up, attempts: 10)
        XCTAssertTrue(succeededEvent.exists)

        let clearHistory = app.buttons["Clear history"]
        scrollUntilHittable(clearHistory, direction: .up, attempts: 10)
        clearHistory.tap()
        XCTAssertFalse(succeededEvent.exists)

        let noContent = app.switches[A11y.loadingLabNoContent]
        scrollUntilHittable(noContent, direction: .down, attempts: 10)
        noContent.tap()

        scrollUntilHittable(deleteCache, direction: .up)
        deleteCache.tap()

        scrollUntilHittable(requestStage, direction: .down)
        requestStage.buttons["In-flight"].tap()
        XCTAssertTrue(element(A11y.entry(0)).waitForExistence(timeout: 2))

        requestStage.buttons["Finished"].tap()
        XCTAssertTrue(waitForNonExistence(element(A11y.entry(0))))
    }

    @MainActor
    func testScreenReplacementRetriesWithFreshSource() {
        launch(.screenReplacement)

        XCTAssertTrue(element(A11y.screenReplacementFailure).waitForExistence(timeout: 3))

        let retry = app.buttons[A11y.screenReplacementRetry]
        XCTAssertTrue(retry.waitForExistence(timeout: 2))
        retry.tap()

        XCTAssertFalse(
            element(A11y.entry(0)).waitForExistence(timeout: 0.4),
            "Placeholder content replaced the failure while retrying"
        )
        XCTAssertTrue(
            element(A11y.screenReplacementFailure).exists,
            "Failure content disappeared before the retry produced a result"
        )
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
        XCTAssertTrue(element(A11y.entry(10)).exists, "Retained account content disappeared after failure")

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
    func testPresentationAndConsumerAnimationsUpdateAlongsideSibling() {
        launch(.animatedReordering)

        XCTAssertTrue(element(A11y.animatedReorderingScreen).waitForExistence(timeout: 3))
        let placeholder = app.staticTexts.matching(identifier: A11y.entry(0)).firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForNonExistence(placeholder, timeout: 10))

        XCTAssertEqual(element(A11y.animatedReorderingSibling).label, "Sibling update 0")
        let first = app.staticTexts.matching(identifier: A11y.entry(501)).firstMatch
        let third = app.staticTexts.matching(identifier: A11y.entry(503)).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(third.exists)
        XCTAssertLessThan(first.frame.minY, third.frame.minY)

        let update = app.buttons[A11y.animatedReorderingReverse]
        scrollUntilHittable(update, direction: .up)
        update.tap()

        XCTAssertTrue(waitForLabelContaining(
            "Sibling update 1",
            on: element(A11y.animatedReorderingSibling)
        ))
        scrollUntilHittable(third, direction: .down)
        XCTAssertLessThan(third.frame.minY, first.frame.minY)

        scrollUntilHittable(update, direction: .up)
        update.tap()
        XCTAssertTrue(waitForLabelContaining(
            "Sibling update 2",
            on: element(A11y.animatedReorderingSibling)
        ))
        scrollUntilHittable(first, direction: .down)
        XCTAssertLessThan(first.frame.minY, third.frame.minY)

        let hide = element(A11y.animatedReorderingHide)
        scrollUntilHittable(hide, direction: .up)
        hide.tap()
        XCTAssertTrue(waitForNonExistence(first))

        let restore = element(A11y.animatedReorderingRestore)
        scrollUntilHittable(restore, direction: .up)
        restore.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))

        let transitionAnimation = app.switches[A11y.animatedReorderingTransitionAnimation]
        scrollUntilHittable(transitionAnimation, direction: .up)
        transitionAnimation.tap()
        scrollUntilHittable(hide, direction: .up)
        hide.tap()
        XCTAssertTrue(waitForNonExistence(first))
        scrollUntilHittable(restore, direction: .up)
        restore.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))

        let animation = app.switches[A11y.animatedReorderingAnimation]
        scrollUntilHittable(animation, direction: .up)
        animation.tap()
        scrollUntilHittable(update, direction: .up)
        update.tap()

        XCTAssertTrue(waitForLabelContaining(
            "Sibling update 3",
            on: element(A11y.animatedReorderingSibling)
        ))
        scrollUntilHittable(third, direction: .down)
        XCTAssertLessThan(third.frame.minY, first.frame.minY)
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
    private func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"),
                    object: element
                ),
            ],
            timeout: timeout
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
    case animatedReordering = "animated-reordering"
    case independentSections = "independent-sections"
}

private enum A11y {
    static let loadingLabScreen = "sample.loading-lab.screen"
    static let loadingLabStage = "sample.loading-lab.stage"
    static let loadingLabDeleteCache = "sample.loading-lab.delete-cache"
    static let loadingLabNoContent = "sample.loading-lab.no-content"

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
    static let animatedReorderingTransitionAnimation =
        "sample.animated-reordering.transition-animation"
    static let animatedReorderingHide = "sample.animated-reordering.hide"
    static let animatedReorderingRestore = "sample.animated-reordering.restore"

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
