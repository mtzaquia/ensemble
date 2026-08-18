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

struct AnimatedReorderingExample: View {
    @State private var viewModel = AnimatedReorderingViewModel()
    @State private var animatesRows = true
    @State private var hidesRows = false

    var body: some View {
        List {
            Section("Initial loading") {
                Text("The first frame uses a local placeholder; mounting it never flies in.")
                    .foregroundStyle(.secondary)
                Text("The delayed real result is a post-mount replacement, so the smart policy animates it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            entriesPresentation

            Section("Unanimated sibling") {
                Text("Sibling update \(viewModel.siblingRevision)")
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingSibling)
                Text("This section changes in the same action without joining the row transition.")
                    .foregroundStyle(.secondary)
            }

            Section("Action") {
                Toggle("Animate changed rows", isOn: $animatesRows)
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingAnimation)

                Button("Update sibling and reverse rows") {
                    viewModel.updateBoth()
                }
                .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingReverse)

                Button(hidesRows ? "Rows are hidden" : "Hide rows") {
                    hidesRows = true
                    viewModel.hideRows()
                }
                .disabled(hidesRows)
                .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingHide)

                Button("Restore rows") {
                    hidesRows = false
                    viewModel.restoreRows()
                }
                .disabled(hidesRows == false)
                .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingRestore)
            }

            Section("What this shows") {
                Label("Rows keep the same identities", systemImage: "number")
                Label("Hide and restore animate this AsyncContent section's insertion and removal", systemImage: "rectangle.dashed.and.paperclip")
                Label(
                    animatesRows
                        ? "The default AsyncContent animation moves only changed rows"
                        : "An explicit nil disables animation for these rows",
                    systemImage: animatesRows ? "sparkles" : "sparkles.slash"
                )
                Label("The sibling starts from its new position", systemImage: "rectangle.topthird.inset.filled")
                Text("UI tests verify final order and source changes; inspect this screen in Simulator to see motion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingScreen)
        .navigationTitle("Animated reordering")
        .task {
            await viewModel.start()
        }
    }

    @ViewBuilder
    private var entriesPresentation: some View {
        AsyncContent(
            viewModel.entries,
            loading: hidesRows ? .hidden : .placeholder(SampleEntry.placeholders),
            animation: animatesRows ? .default : nil
        ) { entries, source in
            rowsSection(entries: entries, source: source)
        }
    }

    @ViewBuilder
    private func rowsSection(entries: [SampleEntry], source: AsyncContentSource) -> some View {
        Section {
            HStack {
                Text("Rendered source")
                Spacer()
                SampleSourceBadge(source: source)
            }
            .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingSource)

            SampleEntryRows(entries: entries, source: source)
        } header: {
            Text("Stable-ID rows")
        } footer: {
            Text("After mount, smart animation targets structural changes and changed latest or retained data.")
        }
    }
}

@Observable
private final class AnimatedReorderingViewModel {
    let entries: ViewData<[SampleEntry]>
    private(set) var siblingRevision = 0

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private var isReversed = false
    @ObservationIgnored private var didStart = false

    init() {
        entries = ViewData()
    }

    func start() async {
        guard didStart == false else { return }
        didStart = true

        await context.load({
            let delay: Duration = SampleAppUITesting.isEnabled
                ? .seconds(4)
                : .milliseconds(1_200)
            try await Task.sleep(for: delay)
            return Self.originalEntries
        }, to: entries)
    }

    func updateBoth() {
        siblingRevision += 1
        isReversed.toggle()
        let nextEntries = isReversed ? Array(Self.originalEntries.reversed()) : Self.originalEntries

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.context.load({ nextEntries }, to: self.entries)
        }
    }

    func hideRows() {
        entries.reset()
    }

    func restoreRows() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.context.load({ Self.originalEntries }, to: self.entries)
        }
    }

    private static let originalEntries = [
        SampleEntry(id: 501, title: "First", detail: "A stable row that moves to the bottom"),
        SampleEntry(id: 502, title: "Second", detail: "Its identity is preserved during the update"),
        SampleEntry(id: 503, title: "Third", detail: "A stable row that moves to the top"),
    ]
}
