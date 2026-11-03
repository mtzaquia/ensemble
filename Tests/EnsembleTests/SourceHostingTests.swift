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

@Suite("Hosted source observation", .serialized)
struct SourceHostingTests {
    @Test("A hidden AsyncContent starts its source without a task on an ancestor")
    func hiddenSourceStarts() async throws {
        let useCase = HostedSource()
        let data = ViewData<Int>(make: useCase.values, refresh: useCase.reload)
        let host = NSHostingView(rootView: AsyncContent(data) { value, _ in Text("\(value)") })
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if data.latestValue == .available(42) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(useCase.connections == 1)
        #expect(data.latestValue == .available(42))
    }

    @Test("A List retains real model data while its source is replaced")
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
        model.data.replaceSource(make: replacement.values, refresh: replacement.reload)
        try await render(host) {
            replacement.connections == 1 && model.data === previous && probe.samples.contains("41-retained")
        }
        // Give source startup's metadata and loading updates a frame to render as well.
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(probe.lastSample == "41-retained")
        #expect(model.data.latestValue == .available(41))
        replacement.continuation?.yield(.success(99))
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
    var deliversOnRefresh = true
    var continuation: AsyncStream<Result<Int, HostedError>>.Continuation?
    func values() -> AsyncStream<Result<Int, HostedError>> {
        connections += 1
        let (stream, continuation) = AsyncStream<Result<Int, HostedError>>.makeStream()
        self.continuation = continuation
        return stream
    }
    func reload() {
        if deliversOnRefresh { continuation?.yield(.success(42)) }
    }
}

private enum HostedError: Error { case failed }

@Observable
private final class HostedModel {
    let useCase: HostedSource

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() },
        initialRefresh: .always
    )
    @ObservationIgnored
    var data: ViewData<Int>
    init(useCase: HostedSource) {
        self.useCase = useCase
        data = ViewData(.available(41))
    }
}

private final class HandoffProbe {
    var samples: Set<String> = []
    var lastSample: String?
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
