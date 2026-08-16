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

    var body: some View {
        List {
            Section("Unanimated sibling") {
                Text("Sibling update \(viewModel.siblingRevision)")
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingSibling)
                Text("This section changes in the same action without joining the row transition.")
                    .foregroundStyle(.secondary)
            }

            AsyncContent(
                viewModel.entries,
                animation: animatesRows ? .default : nil
            ) { entries, source in
                Section {
                    SampleEntryRows(entries: entries, source: source)
                } header: {
                    Text("Stable-ID rows")
                } footer: {
                    Text("AsyncContent supplies the transaction List uses for this structural update.")
                }
            }

            Section("Action") {
                Toggle("Animate row changes", isOn: $animatesRows)
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingAnimation)

                Button("Update sibling and reverse rows") {
                    viewModel.updateBoth()
                }
                .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingReverse)
            }

            Section("What this shows") {
                Label("Rows keep the same identities", systemImage: "number")
                Label(
                    animatesRows
                        ? "A supplied animation moves only these rows"
                        : "An explicit nil disables animation for these rows",
                    systemImage: animatesRows ? "sparkles" : "sparkles.slash"
                )
                Label("The sibling starts from its new position", systemImage: "rectangle.topthird.inset.filled")
            }
        }
        .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingScreen)
        .navigationTitle("Animated reordering")
    }
}

@Observable
private final class AnimatedReorderingViewModel {
    let entries: ViewData<[SampleEntry]>
    private(set) var siblingRevision = 0

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private var isReversed = false

    init() {
        entries = ViewData(Self.originalEntries)
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

    private static let originalEntries = [
        SampleEntry(id: 501, title: "First", detail: "A stable row that moves to the bottom"),
        SampleEntry(id: 502, title: "Second", detail: "Its identity is preserved during the update"),
        SampleEntry(id: 503, title: "Third", detail: "A stable row that moves to the top"),
    ]
}
