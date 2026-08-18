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
    @State private var animatesListChanges = true
    @State private var animatesPresentation = true
    @State private var hidesRows = false

    var body: some View {
        List {
            Section("Initial loading") {
                Text(
                    "The placeholder mounts without animation. Its replacement is also content, "
                        + "so Ensemble adds no transition."
                )
                    .foregroundStyle(.secondary)
            }

            entriesPresentation

            Section("Simultaneous sibling") {
                Text("Sibling update \(viewModel.siblingRevision)")
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingSibling)
                Text("This value changes in the same action without an explicit content transition.")
                    .foregroundStyle(.secondary)
            }

            Section("Action") {
                Toggle("Animate consumer list changes", isOn: $animatesListChanges)
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingAnimation)

                Toggle("Animate presentation changes", isOn: $animatesPresentation)
                    .accessibilityIdentifier(
                        SampleAppAccessibility.animatedReorderingTransitionAnimation
                    )

                Button("Update sibling and rows") {
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
                Label(
                    "AsyncContent owns presentation replacement",
                    systemImage: "rectangle.dashed.and.paperclip"
                )
                Label(
                    animatesListChanges
                        ? "The List owns stable-ID structural motion"
                        : "Consumer list animation is disabled",
                    systemImage: animatesListChanges ? "sparkles" : "sparkles.slash"
                )
                Label(
                    "The sibling has no explicit content animation",
                    systemImage: "rectangle.topthird.inset.filled"
                )
            }
        }
        .animation(
            animatesListChanges ? .snappy : nil,
            value: viewModel.entries.latestValueRevision
        )
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
            transitionAnimation: animatesPresentation ? .default : nil
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

            ForEach(entries) { entry in
                SampleEntryRow(entry: entry)
                    .animation(animatesListChanges ? .snappy : nil, value: entry.detail)
            }
            .redacted(reason: source == .placeholder ? .placeholder : [])
        } header: {
            Text("Stable-ID rows")
        } footer: {
            Text("The List revision animates stable-ID structure; each row owns its values.")
        }
    }
}

@Observable
private final class AnimatedReorderingViewModel {
    let entries = ViewData<[SampleEntry]>()
    private(set) var siblingRevision = 0

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private var showsUpdatedEntries = false
    @ObservationIgnored private var didStart = false

    func start() async {
        guard didStart == false else { return }
        didStart = true

        await context.load({
            let delay: Duration = SampleAppUITesting.isEnabled
                ? .seconds(8)
                : .milliseconds(1_200)
            try await Task.sleep(for: delay)
            return Self.originalEntries
        }, to: entries)
    }

    func updateBoth() {
        siblingRevision += 1
        showsUpdatedEntries.toggle()
        let nextEntries = showsUpdatedEntries ? Self.updatedEntries : Self.originalEntries
        load(nextEntries)
    }

    func hideRows() {
        entries.reset()
    }

    func restoreRows() {
        load(Self.originalEntries)
    }

    private func load(_ value: [SampleEntry]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.context.load({ value }, to: self.entries)
        }
    }

    private static let originalEntries = [
        SampleEntry(id: 501, title: "First", detail: "A stable row that moves to the bottom"),
        SampleEntry(id: 502, title: "Second", detail: "Its identity is preserved during the update"),
        SampleEntry(id: 503, title: "Third", detail: "A stable row that moves to the top"),
    ]

    private static let updatedEntries = [
        SampleEntry(id: 503, title: "Third", detail: "This retained row also changed its detail"),
        SampleEntry(id: 504, title: "Inserted", detail: "A new stable identity"),
        SampleEntry(id: 501, title: "First", detail: "This retained row moved to the bottom"),
    ]
}
