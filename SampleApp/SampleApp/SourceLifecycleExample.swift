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
import Observation
import SwiftUI

struct SourceLifecycleExample: View {
    @State private var model = SourceLifecycleModel()
    @State private var macroModel = MacroSourceModel()
    @State private var showsMacro = false

    var body: some View {
        List {
            Section {
                Text("The first source is seeded before rendering. Replace its factory to keep the same model data and rows. Connection only subscribes; choose Reload to request a refresh, then deliver a response.")
                LabeledContent("Current source", value: model.isSecond ? "Second" : "First")
                    .accessibilityIdentifier("sample.source-lifecycle.current")
                Text("The model has a value: \(model.hasValue ? "yes" : "no")")
                    .accessibilityIdentifier("sample.source-lifecycle.model-value")
            }

            Section("Entries") {
                AsyncContent(model.entries, loading: .placeholder(SampleEntry.placeholders)) { entries, source in
                    SampleEntryRows(entries: entries, source: source)
                    SampleSourceBadge(source: source)
                        .accessibilityIdentifier("sample.source-lifecycle.origin")
                }
            }

            Section("Source controls") {
                Button("Swap source", action: model.swap)
                    .accessibilityIdentifier("sample.source-lifecycle.swap")
                Button("Deliver response", action: model.deliver)
                    .accessibilityIdentifier("sample.source-lifecycle.deliver")
                Button("Fail response", action: model.fail)
                    .accessibilityIdentifier("sample.source-lifecycle.fail")
                Button("Reload") { Task { await model.entries.reload() } }
                    .accessibilityIdentifier("sample.source-lifecycle.reload")
            }

            Section {
                Button(showsMacro ? "Hide macro source" : "Show macro source") {
                    showsMacro.toggle()
                }
                    .accessibilityIdentifier("sample.source-lifecycle.show-macro")
                Text("Macro connections: \(macroModel.useCase.connections)")
                    .accessibilityIdentifier("sample.source-lifecycle.connections")
                if showsMacro {
                    AsyncContent(macroModel.entries) { entries, source in
                        SampleEntryRows(entries: entries, source: source)
                    }
                    Button("Deliver macro response") { macroModel.useCase.deliver() }
                        .accessibilityIdentifier("sample.source-lifecycle.deliver-macro")
                }
            } header: {
                Text("Property macro")
            } footer: {
                Text("Reading state starts no work. Showing the consumer connects the declared source without a model-level macro or start method.")
            }
        }
        .navigationTitle("Source lifecycle")
        .accessibilityIdentifier("sample.source-lifecycle.screen")
    }
}

@Observable
private final class SourceLifecycleModel {
    let entries: ViewData<[SampleEntry]>
    private(set) var isSecond = false
    private let first = SourceLabUseCase(seed: SampleEntry.cached)
    private let second = SourceLabUseCase(seed: nil)

    var hasValue: Bool {
        if case .available = entries.latestValue { true } else { false }
    }

    init() {
        entries = ViewData(
            .available(SampleEntry.cached), owner: first,
            make: { $0.values() }, refresh: { $0.reload() }
        )
    }

    func swap() {
        isSecond.toggle()
        let source = isSecond ? second : first
        entries.replaceSource(make: source.values, refresh: source.reload)
    }

    func deliver() { (isSecond ? second : first).deliver() }
    func fail() { (isSecond ? second : first).fail() }
}

private final class MacroSourceModel {
    let useCase = SourceLabUseCase(seed: nil)

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() },
        initialValue: .available(SampleEntry.cached)
    )
    var entries: ViewData<[SampleEntry]>
}

@Observable
private final class SourceLabUseCase {
    private(set) var connections = 0
    @ObservationIgnored private var seed: [SampleEntry]?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Result<[SampleEntry], SampleFailure>>.Continuation] = [:]

    init(seed: [SampleEntry]?) { self.seed = seed }

    func values() -> AsyncStream<Result<[SampleEntry], SampleFailure>> {
        connections += 1
        let id = UUID()
        let (stream, continuation) = AsyncStream<Result<[SampleEntry], SampleFailure>>.makeStream()
        continuations[id] = continuation
        if let seed { continuation.yield(.success(seed)) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    // Responses are held until the user delivers them, making the handoff visible.
    func reload() {}

    func deliver() {
        seed = SampleEntry.refreshed
        for continuation in continuations.values { continuation.yield(.success(SampleEntry.refreshed)) }
    }

    func fail() {
        for continuation in continuations.values { continuation.yield(.failure(.offline)) }
    }
}
