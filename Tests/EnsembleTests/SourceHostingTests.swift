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

import Observation
import SwiftUI
import Testing
@testable import Ensemble

#if canImport(AppKit)
import AppKit

@Suite("Hosted model-owned sources", .serialized)
struct SourceHostingTests {
    @Test("An initially hidden AsyncContent requests its source connection")
    func hiddenSourceStarts() async throws {
        let useCase = HostedSource()
        useCase.valueOnSubscription = 42
        let model = HostedModel(useCase: useCase, initial: .unavailable)
        defer { withExtendedLifetime(model) {} }
        let probe = HandoffProbe()
        let host = NSHostingView(rootView: AsyncContent(model.data) { value, source in
            HandoffMarker(value: value, source: source, probe: probe)
        })
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        try await render(host) { probe.lastSample == "42-latest" }
        #expect(useCase.connections == 1)
        #expect(model.data.latestValue == .available(42))
        #expect(useCase.refreshes == 0)
    }

    @Test("A conditional gate stays passive until the model connects its source")
    func gateConnectsExplicitly() async throws {
        let useCase = HostedSource()
        useCase.valueOnSubscription = 42
        let model = HostedModel(useCase: useCase, initial: .unavailable)
        defer { withExtendedLifetime(model) {} }
        let probe = HandoffProbe()
        let host = NSHostingView(rootView: GatedSourceContent(model: model, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        #expect(useCase.connections == 0)
        #expect(probe.lastSample == nil)
        model.start()
        try await render(host) { probe.lastSample == "42-latest" }
        #expect(useCase.connections == 1)
        #expect(useCase.refreshes == 0)
    }

    @Test("Removing and restoring content keeps one model-owned connection")
    func hiddenConsumerKeepsSource() async throws {
        let useCase = HostedSource()
        let model = HostedModel(useCase: useCase)
        let probe = HandoffProbe()
        let host = NSHostingView(rootView: GatedSourceContent(model: model, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        try await render(host) { probe.lastSample == "41-latest" && useCase.connections == 1 }
        model.showsContent = false
        host.layoutSubtreeIfNeeded()
        useCase.continuation?.yield(.success(42))
        try await render(host) { model.data.latestValue == .available(42) }
        model.showsContent = true
        try await render(host) { probe.lastSample == "42-latest" }
        #expect(useCase.connections == 1)
        #expect(useCase.refreshes == 0)
    }

    @Test("A List retains real model data while observed inputs rebind its source")
    func listHandoff() async throws {
        let useCase = HostedSource()
        let model = HostedModel(useCase: useCase)
        let probe = HandoffProbe()
        let host = NSHostingView(rootView: HostedList(model: model, probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await render(host) { probe.samples.contains("41-latest") }
        let previous = model.data
        let replacement = HostedSource()
        replacement.deliversOnRefresh = false
        model.useCase = replacement
        try await render(host) { replacement.connections == 1 }
        #expect(model.data === previous)
        #expect(replacement.refreshes == 0)
        #expect(probe.lastSample == "41-latest")
        let reload = Task { await model.data.reload() }
        defer { reload.cancel() }
        try await render(host) { probe.samples.contains("41-retained") }
        // Give source startup's metadata and loading updates a frame to render as well.
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(probe.lastSample == "41-retained")
        #expect(model.data.latestValue == .available(41))
        replacement.completeRefresh(with: 99)
        await reload.value
        try await render(host) { probe.samples.contains("99-latest") }
        #expect(model.data.latestValue == .available(99))
    }

    private func render<Content: View>(_ host: NSHostingView<Content>, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Hosted source did not reach its expected state")
    }
}

private final class HostedSource {
    var connections = 0
    var refreshes = 0
    var valueOnSubscription: Int?
    var deliversOnRefresh = true
    var continuation: AsyncStream<Result<Int, HostedError>>.Continuation?
    private let manualRefresh = AsyncStream<Void>.makeStream()
    func values() -> AsyncStream<Result<Int, HostedError>> {
        connections += 1
        let (stream, continuation) = AsyncStream<Result<Int, HostedError>>.makeStream()
        self.continuation = continuation
        if let valueOnSubscription { continuation.yield(.success(valueOnSubscription)) }
        return stream
    }
    func reload() async {
        refreshes += 1
        if deliversOnRefresh {
            continuation?.yield(.success(42))
        } else {
            for await _ in manualRefresh.stream {}
        }
    }

    func completeRefresh(with value: Int) {
        continuation?.yield(.success(value))
        manualRefresh.continuation.finish()
    }
}

private enum HostedError: Error { case failed }

@Observable
private final class HostedModel {
    var sourceID: ObjectIdentifier { ObjectIdentifier(useCase) }
    var useCase: HostedSource
    let initial: ViewDataAvailability<Int>
    var showsContent = true
    func start() { data.connect() }
    var hasContent: Bool {
        if case .available = data.latestValue { true } else { false }
    }

    @ViewDataSource(
        id: \.sourceID,
        initial: { (model: Self) in model.initial },
        make: { (model: Self) in model.useCase.values() },
        refresh: { model, _ in await model.useCase.reload() }
    )
    @ObservationIgnored
    var data: ViewData<Int>
    init(useCase: HostedSource, initial: ViewDataAvailability<Int> = .available(41)) {
        self.useCase = useCase
        self.initial = initial
    }
}

private final class HandoffProbe {
    var samples: Set<String> = []
    var lastSample: String?
}

private struct GatedSourceContent: View {
    let model: HostedModel
    let probe: HandoffProbe
    var body: some View {
        if model.showsContent && model.hasContent {
            AsyncContent(model.data) { value, source in
                HandoffMarker(value: value, source: source, probe: probe)
            }
        } else {
            Text("Waiting for content")
        }
    }
}

private struct HostedList: View {
    let model: HostedModel
    let probe: HandoffProbe
    var body: some View {
        List {
            AsyncContent(model.data, loading: .placeholder(0)) { value, source in
                Section("Source") {
                    HandoffMarker(value: value, source: source, probe: probe)
                }
            }
            Text("Unrelated row")
        }
    }
}

private struct HandoffMarker: NSViewRepresentable {
    let value: Int
    let source: AsyncContentSource
    let probe: HandoffProbe
    func makeNSView(context: Context) -> NSTextField { NSTextField(labelWithString: "") }
    func updateNSView(_ view: NSTextField, context: Context) {
        view.stringValue = "\(value)"
        probe.samples.insert("\(value)-\(source)")
        probe.lastSample = "\(value)-\(source)"
    }
}
#endif
