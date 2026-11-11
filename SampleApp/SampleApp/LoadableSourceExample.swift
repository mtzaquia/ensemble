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

struct LoadableSourceExample: View {
    @State private var model = LoadableEntriesModel()
    @State private var showsEntries = false

    var body: some View {
        List {
            Section {
                LabeledContent("Account", value: model.isWorkAccount ? "Work" : "Personal")
                LoadableSnapshotRow(data: model.entries)
            } footer: {
                Text("The snapshot is available before Entries appears. Showing Entries starts the first load.")
            }

            Section {
                Button("Show entries") { showsEntries = true }
                    .disabled(showsEntries)
                    .accessibilityIdentifier(SampleAppAccessibility.loadableShow)
                Button("Switch account") { model.isWorkAccount.toggle() }
                    .disabled(!showsEntries)
                    .accessibilityIdentifier(SampleAppAccessibility.loadableSwitch)
                Button("Reload") { Task { await model.entries.reload() } }
                    .disabled(!showsEntries)
                    .accessibilityIdentifier(SampleAppAccessibility.loadableReload)
            } footer: {
                Text("Switching accounts loads that account’s entries. The first reload for each account simulates going offline.")
            }

            if showsEntries {
                LoadableEntriesSection(data: model.entries)
            }
        }
        .navigationTitle("Loadable sources")
    }
}

private struct LoadableSnapshotRow: View {
    let data: ViewData<[SampleEntry]>

    var body: some View {
        LabeledContent("Snapshot") {
            if case .available(let entries) = data.latestValue, let entry = entries.first {
                Text(entry.title)
            } else {
                Text("No snapshot")
            }
        }
        .accessibilityIdentifier(SampleAppAccessibility.loadableSnapshot)
    }
}

private struct LoadableEntriesSection: View {
    let data: ViewData<[SampleEntry]>

    var body: some View {
        Section("Entries") {
            AsyncContent(data) { entries, source in
                SampleEntryRows(entries: entries, source: source)
            } failure: { error, retry in
                Text(error.localizedDescription)
                if let retry {
                    Button("Retry") { retry() }
                        .accessibilityIdentifier(SampleAppAccessibility.loadableRetry)
                }
            }
        }
    }
}

@Observable
private final class LoadableEntriesModel {
    var isWorkAccount = false

    @ViewDataSource(id: \.isWorkAccount, updates: { (model: Self) in
        LoadableEntriesProducer(isWorkAccount: model.isWorkAccount)
    })
    @ObservationIgnored
    var entries: ViewData<[SampleEntry]>
}

private final class LoadableEntriesProducer: ViewDataLoadableSource {
    let isWorkAccount: Bool
    private var reloads = 0
    private var continuation: AsyncStream<ViewDataUpdate<[SampleEntry]>>.Continuation?

    init(isWorkAccount: Bool) { self.isWorkAccount = isWorkAccount }

    var availability: ViewDataAvailability<[SampleEntry]> {
        isWorkAccount ? .unavailable : .available([
            SampleEntry(id: 100, title: "Cached personal entries", detail: "Available before connection")
        ])
    }

    func viewDataUpdates() -> AsyncStream<ViewDataUpdate<[SampleEntry]>> {
        let (stream, continuation) = AsyncStream<ViewDataUpdate<[SampleEntry]>>.makeStream()
        self.continuation = continuation
        return stream
    }

    func viewDataLoad(_ request: ViewDataLoadRequest) async {
        let account = isWorkAccount ? "work" : "personal"
        if request == .reload {
            reloads += 1
            if reloads == 1 {
                continuation?.yield(.result(.failure(SampleFailure.offline)))
                return
            }
        }
        let entry = SampleEntry(
            id: isWorkAccount ? 102 : 101,
            title: request == .initial ? "Loaded \(account) entries" : "Refreshed \(account) entries",
            detail: request == .initial ? "Initial request" : "Reload request"
        )
        continuation?.yield(.result(.success([entry])))
    }
}
