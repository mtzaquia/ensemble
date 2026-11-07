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
    @State private var showsBadge = false
    @State private var previousMacroSource: SourceLabUseCase?

    var body: some View {
        List {
            Section {
                Text("The first source is seeded before rendering. Change the selected source to rebind automatically while keeping the same model data and rows. Connection only subscribes; choose Reload to request a refresh, then deliver a response.")
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
                Button("Read badge") { showsBadge = true }
                    .accessibilityIdentifier("sample.source-lifecycle.read-badge")
                if showsBadge {
                    Text("Badge count: \(macroModel.badgeCount)")
                        .accessibilityIdentifier("sample.source-lifecycle.badge")
                }
                Button(showsMacro ? "Hide macro source" : "Show macro source") {
                    showsMacro.toggle()
                }
                    .accessibilityIdentifier("sample.source-lifecycle.show-macro")
                Text("Macro connections: \(macroModel.useCase.connections)")
                    .accessibilityIdentifier("sample.source-lifecycle.connections")
                if showsMacro {
                    if macroModel.canShowEntries {
                        AsyncContent(macroModel.entries) { entries, source in
                            SampleEntryRows(entries: entries, source: source)
                        }
                    } else {
                        Text("The data gate is waiting for a response.")
                            .accessibilityIdentifier("sample.source-lifecycle.gate")
                    }
                }
                Button("Deliver macro response") { macroModel.useCase.deliver() }
                    .accessibilityIdentifier("sample.source-lifecycle.deliver-macro")
                Button("Release macro model") {
                    previousMacroSource = macroModel.useCase
                    showsBadge = false
                    showsMacro = false
                    macroModel = MacroSourceModel()
                }
                .accessibilityIdentifier("sample.source-lifecycle.release-model")
                if let previousMacroSource {
                    Text("Previous active connections: \(previousMacroSource.activeConnections)")
                        .accessibilityIdentifier("sample.source-lifecycle.previous-connections")
                }
            } header: {
                Text("Property macro")
            } footer: {
                Text("Read the badge or show the data gate to activate the source. Hidden content keeps its connection while the model lives. Release the model to cancel it.")
            }
        }
        .navigationTitle("Source lifecycle")
        .accessibilityIdentifier("sample.source-lifecycle.screen")
    }
}

@Observable
private final class SourceLifecycleModel {
    @ViewDataSource(
        initial: { _ in .available(SampleEntry.cached) },
        make: { (model: Self) in model.currentSource.values() },
        refresh: { model in model.currentSource.reload() }
    )
    @ObservationIgnored
    var entries: ViewData<[SampleEntry]>
    private(set) var isSecond = false
    private let first = SourceLabUseCase(seed: SampleEntry.cached)
    private let second = SourceLabUseCase(seed: nil)

    var hasValue: Bool {
        if case .available = entries.latestValue { true } else { false }
    }

    private var currentSource: SourceLabUseCase { isSecond ? second : first }

    func swap() {
        isSecond.toggle()
    }

    func deliver() { (isSecond ? second : first).deliver() }
    func fail() { (isSecond ? second : first).fail() }
}

private final class MacroSourceModel {
    let useCase = SourceLabUseCase(seed: nil)

    var badgeCount: Int {
        if case .available(let entries) = entries.latestValue { entries.count } else { 0 }
    }

    var canShowEntries: Bool { badgeCount > 0 }

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() }
    )
    var entries: ViewData<[SampleEntry]>
}

@Observable
private final class SourceLabUseCase {
    private(set) var connections = 0
    private(set) var activeConnections = 0
    @ObservationIgnored private var connectionCount = 0
    @ObservationIgnored private var seed: [SampleEntry]?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Result<[SampleEntry], SampleFailure>>.Continuation] = [:]

    init(seed: [SampleEntry]?) { self.seed = seed }

    func values() -> AsyncStream<Result<[SampleEntry], SampleFailure>> {
        connectionCount += 1
        connections = connectionCount
        let id = UUID()
        let (stream, continuation) = AsyncStream<Result<[SampleEntry], SampleFailure>>.makeStream()
        continuations[id] = continuation
        activeConnections = continuations.count
        if let seed { continuation.yield(.success(seed)) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.continuations[id] = nil
                self.activeConnections = self.continuations.count
            }
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
