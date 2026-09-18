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

import SwiftUI
import Testing
@testable import Ensemble

#if canImport(AppKit)
import AppKit

@Suite("Hosted async content animation", .serialized)
struct AsyncContentAnimationTests {
    @Test("Phase animation is local, leaves initial rendering alone, and does not animate value revisions")
    func phaseAnimationIsScoped() async throws {
        let fixture = AnimationFixture(phaseAnimation: .snappy)
        let host = makeHost(fixture)
        try await render(host) { fixture.primary.contains(0) }
        #expect(fixture.primary.animation(for: 0) == nil)

        fixture.data.set(42)
        fixture.sibling.set(7)
        try await render(host) {
            fixture.primary.contains(42) && fixture.secondary.contains(42)
                && fixture.siblingProbe.contains(7)
        }
        #expect(fixture.primary.animation(for: 42) == .snappy)
        #expect(fixture.secondary.animation(for: 42) == nil)
        #expect(fixture.siblingProbe.animation(for: 7) == nil)

        fixture.data.set(43)
        try await render(host) { fixture.primary.contains(43) }
        #expect(fixture.primary.animation(for: 43) == nil)

        withAnimation(.linear) {
            fixture.data.set(44)
        }
        try await render(host) { fixture.primary.contains(44) && fixture.secondary.contains(44) }
        #expect(fixture.primary.animation(for: 44) == .linear)
        #expect(fixture.secondary.animation(for: 44) == .linear)

        fixture.data.beginLoading()
        try await render(host) {
            fixture.primary.contains(44, tag: "retained")
                && fixture.secondary.contains(44, tag: "retained")
        }
        #expect(fixture.primary.animation(for: 44, tag: "retained") == .snappy)
        #expect(fixture.secondary.animation(for: 44, tag: "retained") == nil)
    }

    @Test("Nil phase animation leaves placeholder replacement unanimated")
    func defaultPhaseAnimation() async throws {
        let fixture = AnimationFixture(phaseAnimation: nil)
        let host = makeHost(fixture)
        try await render(host) { fixture.primary.contains(0) }

        fixture.data.set(42)
        try await render(host) { fixture.primary.contains(42) }
        #expect(fixture.primary.animation(for: 42) == nil)
    }

    // A newly inserted leaf can receive a nil transaction after the container consumes the
    // structural animation. Check native row movement, not only the transaction at the leaf.
    @Test("List phase changes animate row movement without a List animation modifier",
          arguments: [(false, false, false), (false, false, true),
                      (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true),
                      (true, true, false), (true, true, true)])
    func listPhaseChanges(usePlaceholder: Bool, fail: Bool, animated: Bool) async throws {
        let data = ViewData<[Int]>()
        data.beginLoading()
        let marker = ListMovementProbe()
        let host = makeHost(ListAnimationFixture(
            data: data, marker: marker, usePlaceholder: usePlaceholder,
            animation: animated ? .snappy : nil
        ))
        let window = show(host)
        defer { window.orderOut(nil) }
        try await render(host) { marker.view != nil }
        try await Task.sleep(for: .milliseconds(100))
        let before = try #require(marker.position)

        if fail { data.fail(AnimationError.expected) } else { data.set([4]) }
        let didAnimate = try await observeMovement(host, marker: marker, from: before)
        #expect(didAnimate == animated)
    }

    @Test("Same-phase List updates inherit the caller animation instead of the phase animation")
    func listSamePhaseChanges() async throws {
        let data = ViewData([1])
        let marker = ListMovementProbe()
        let host = makeHost(ListAnimationFixture(data: data, marker: marker, animation: .snappy))
        let window = show(host)
        defer { window.orderOut(nil) }
        try await render(host) { marker.view != nil }
        try await Task.sleep(for: .milliseconds(100))
        var before = try #require(marker.position)

        data.set([1, 2, 3])
        #expect(try await !observeMovement(host, marker: marker, from: before))
        before = try #require(marker.position)
        withAnimation(.linear) { data.set([1]) }
        #expect(try await observeMovement(host, marker: marker, from: before))
    }

    @Test("Phase animation reaches List removals when content becomes hidden")
    func listContentRemoval() async throws {
        let data = ViewData([1, 2, 3])
        let marker = ListMovementProbe()
        let host = makeHost(ListAnimationFixture(data: data, marker: marker, animation: .snappy))
        let window = show(host)
        defer { window.orderOut(nil) }
        try await render(host) { marker.view != nil }
        try await Task.sleep(for: .milliseconds(100))
        let before = try #require(marker.position)
        data.reset()
        #expect(try await observeMovement(host, marker: marker, from: before))
    }

    @Test("Two Lists presenting the same data keep independent phase-animation configuration")
    func listAnimationIsViewLocal() async throws {
        let data = ViewData<[Int]>()
        let animated = ListMovementProbe()
        let unanimated = ListMovementProbe()
        let host = makeHost(HStack {
            ListAnimationFixture(data: data, marker: animated, animation: .snappy)
            ListAnimationFixture(data: data, marker: unanimated, animation: nil)
        })
        host.frame.size.width = 640
        let window = show(host)
        defer { window.orderOut(nil) }
        try await render(host) { animated.view != nil && unanimated.view != nil }
        try await Task.sleep(for: .milliseconds(100))
        let before = try #require(animated.position)
        data.set([1])
        var animatedMoved = false
        var unanimatedMoved = false
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            animatedMoved = animatedMoved || animated.hasPositionAnimation
            unanimatedMoved = unanimatedMoved || unanimated.hasPositionAnimation
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(animated.position != before)
        #expect(animatedMoved)
        #expect(!unanimatedMoved)
    }

    @Test("List phase updates preserve a caller transaction that disables animations")
    func listDisabledAnimation() async throws {
        let data = ViewData<[Int]>()
        let marker = ListMovementProbe()
        let host = makeHost(ListAnimationFixture(data: data, marker: marker, animation: .snappy))
        let window = show(host)
        defer { window.orderOut(nil) }
        try await render(host) { marker.view != nil }
        try await Task.sleep(for: .milliseconds(100))
        let before = try #require(marker.position)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { data.set([1]) }
        #expect(try await !observeMovement(host, marker: marker, from: before))
    }

    @Test("Unwrapping forwards phase changes but does not animate same-phase nil replacement")
    func listOptionalPresentation() async throws {
        let data = ViewData<[Int]?>()
        let marker = ListMovementProbe()
        let host = makeHost(List {
            AsyncContent(unwrapping: data, loading: .hidden) { rows, _ in
                Section("Async") {
                    ForEach(rows, id: \.self) { id in Text("Row \(id)") }
                }
            }
            Section("Unrelated") { ListMovementMarker(probe: marker) }
        }.phaseAnimation(.snappy))
        let window = show(host)
        defer { window.orderOut(nil) }
        try await render(host) { marker.view != nil }
        try await Task.sleep(for: .milliseconds(100))
        var before = try #require(marker.position)
        data.set([1])
        #expect(try await observeMovement(host, marker: marker, from: before))
        before = try #require(marker.position)
        data.set(nil)
        #expect(try await !observeMovement(host, marker: marker, from: before))
    }

    @Test("The local phase transaction preserves custom caller transaction values")
    func callerTransactionValues() async throws {
        let fixture = AnimationFixture(phaseAnimation: .snappy)
        let host = makeHost(fixture)
        try await render(host) { fixture.primary.contains(0) }
        var transaction = Transaction(animation: .linear)
        transaction[CallerTransactionKey.self] = 17
        withTransaction(transaction) { fixture.data.set(42) }
        try await render(host) { fixture.primary.contains(42) && fixture.secondary.contains(42) }
        #expect(fixture.primary.callerValue(for: 42) == 17)
        #expect(fixture.secondary.callerValue(for: 42) == 17)
        #expect(fixture.primary.animation(for: 42) == .snappy)
        #expect(fixture.secondary.animation(for: 42) == .linear)
    }

    @Test("Enclosing view configuration cascades, with nearer animation and nil overrides")
    func environmentCascades() async throws {
        var fixture = AnimationFixture(phaseAnimation: .snappy)
        let host = makeHost(fixture)
        try await render(host) { fixture.inherited.contains(0) }
        #expect(fixture.inherited.animation(for: 0) == nil)

        fixture.data.set(42)
        try await render(host) {
            fixture.primary.contains(42) && fixture.secondary.contains(42)
                && fixture.inherited.contains(42)
        }
        #expect(fixture.primary.animation(for: 42) == .snappy)
        #expect(fixture.secondary.animation(for: 42) == nil)
        #expect(fixture.inherited.animation(for: 42) == .linear)

        fixture.ancestorAnimation = .easeInOut
        host.rootView = fixture
        fixture.data.set(43)
        try await render(host) { fixture.inherited.contains(43) }
        #expect(fixture.inherited.animation(for: 43) == nil)

        fixture.data.beginLoading()
        try await render(host) { fixture.inherited.contains(43, tag: "retained") }
        #expect(fixture.inherited.animation(for: 43, tag: "retained") == .easeInOut)
    }

    @Test("The environment default supplies no phase animation")
    func environmentDefault() {
        #expect(EnvironmentValues().ensemblePhaseAnimation == nil)
        // The public modifier is available after arbitrary SwiftUI modifiers, not just on AsyncContent.
        _ = Text("Region").padding().phaseAnimation(.snappy)
    }

    @Test("Nested async content inherits configuration and animates its own phase independently")
    func nestedAsyncContent() async throws {
        let outer = ViewData(1)
        let inner = ViewData<Int>()
        let probe = AnimationProbe()
        let host = makeHost(
            AsyncContent(outer) { _, _ in
                AsyncContent(inner, loading: .placeholder(0)) { value, _ in
                    ProbeView(value: value, probe: probe)
                }
            }
            .phaseAnimation(.snappy)
        )
        try await render(host) { probe.contains(0) }
        #expect(probe.animation(for: 0) == nil)

        inner.set(42)
        try await render(host) { probe.contains(42) }
        #expect(probe.animation(for: 42) == .snappy)

        inner.set(43)
        try await render(host) { probe.contains(43) }
        #expect(probe.animation(for: 43) == nil)
    }

    private func makeHost<Content: View>(_ fixture: Content) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: fixture)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        return host
    }

    private func show<Content: View>(_ host: NSHostingView<Content>) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func observeMovement<Content: View>(
        _ host: NSHostingView<Content>, marker: ListMovementProbe, from position: CGFloat
    ) async throws -> Bool {
        var moved = false
        var animated = false
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            moved = moved || marker.position != position
            animated = animated || marker.hasPositionAnimation
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(moved, "The update must change native List row layout")
        return animated
    }

    private func render<Content: View>(
        _ host: NSHostingView<Content>,
        until rendered: () -> Bool
    ) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if rendered() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The hosted SwiftUI update did not render within one second")
    }
}

private final class ListMovementProbe {
    weak var view: NSView?
    var position: CGFloat? { view.map { $0.convert($0.bounds, to: nil).minY } }
    var hasPositionAnimation: Bool {
        var ancestor = view
        while let current = ancestor {
            if current.layer?.animationKeys()?.contains("position") == true { return true }
            ancestor = current.superview
        }
        return false
    }
}

private struct ListAnimationFixture: View {
    let data: ViewData<[Int]>
    let marker: ListMovementProbe
    var usePlaceholder = false
    let animation: Animation?

    var body: some View {
        List {
            AsyncContent(data, loading: usePlaceholder ? .placeholder([1, 2, 3]) : .hidden) { rows, _ in
                Section("Async") {
                    ForEach(rows, id: \.self) { id in Text("Row \(id)") }
                }
            } failure: { _, _ in
                Section("Failure") { Text("Failed") }
            }
            Section("Unrelated") { ListMovementMarker(probe: marker) }
        }
        .phaseAnimation(animation)
    }
}

private struct ListMovementMarker: NSViewRepresentable {
    let probe: ListMovementProbe
    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(labelWithString: "Unrelated row")
        probe.view = view
        return view
    }
    func updateNSView(_ view: NSTextField, context: Context) {}
}

private enum AnimationError: Error {
    case expected
}

private struct CallerTransactionKey: TransactionKey {
    static let defaultValue = 0
}

private final class AnimationProbe {
    private var samples: [(value: Int, tag: String, animation: Animation?, callerValue: Int)] = []

    func record(_ value: Int, tag: String, transaction: Transaction) {
        samples.append((value, tag, transaction.animation, transaction[CallerTransactionKey.self]))
    }

    func contains(_ value: Int, tag: String? = nil) -> Bool {
        samples.contains { $0.value == value && (tag == nil || $0.tag == tag) }
    }

    func animation(for value: Int, tag: String? = nil) -> Animation? {
        samples.first { $0.value == value && (tag == nil || $0.tag == tag) }?.animation
    }

    func callerValue(for value: Int) -> Int? {
        samples.first { $0.value == value }?.callerValue
    }
}

private struct AnimationFixture: View {
    let data = ViewData<Int>()
    let sibling = ViewData(0)
    let primary = AnimationProbe()
    let secondary = AnimationProbe()
    let inherited = AnimationProbe()
    let siblingProbe = AnimationProbe()
    let phaseAnimation: Animation?
    var usesPlaceholder = true
    var ancestorAnimation: Animation? = .linear

    var body: some View {
        VStack {
            AsyncContent(data, loading: usesPlaceholder ? .placeholder(0) : .hidden) { value, source in
                ProbeView(value: value, tag: String(describing: source), probe: primary)
            } failure: { _, _ in
                ProbeView(value: -1, probe: primary)
            }
            .phaseAnimation(phaseAnimation)

            AsyncContent(data, loading: usesPlaceholder ? .placeholder(0) : .hidden) { value, source in
                ProbeView(value: value, tag: String(describing: source), probe: secondary)
            } failure: { _, _ in
                ProbeView(value: -1, probe: secondary)
            }
            .phaseAnimation(nil)

            VStack {
                AsyncContent(data, loading: .placeholder(0)) { value, source in
                    ProbeView(value: value, tag: String(describing: source), probe: inherited)
                }
            }

            AsyncContent(sibling) { value, _ in
                ProbeView(value: value, probe: siblingProbe)
            }
        }
        .phaseAnimation(ancestorAnimation)
    }
}

private struct ProbeView: NSViewRepresentable {
    let value: Int
    var tag: String = ""
    let probe: AnimationProbe

    func makeNSView(context: Context) -> NSTextField {
        NSTextField(labelWithString: "\(value)")
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        view.stringValue = "\(value)"
        probe.record(value, tag: tag, transaction: context.transaction)
    }
}
#endif
