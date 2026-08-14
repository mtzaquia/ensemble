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

    var body: some View {
        AsyncContent(viewModel.entries) { entries, source in
            List {
                Section {
                    SampleEntryRows(entries: entries, source: source)
                } header: {
                    Text("Stable-ID rows")
                } footer: {
                    Text("The List receives the reordered value and animation revision in one observable presentation update.")
                }

                Section("Action") {
                    Button("Reverse row order") {
                        viewModel.reverseRowOrder()
                    }
                    .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingReverse)
                }

                Section("What this shows") {
                    Label("Rows keep the same identities", systemImage: "number")
                    Label("ViewData accepts the reordered value", systemImage: "arrow.up.arrow.down")
                    Label("animationValue drives the List animation", systemImage: "sparkles")
                }
            }
            .accessibilityIdentifier(SampleAppAccessibility.animatedReorderingScreen)
        }
        .animation(.default, value: viewModel.entries.animationValue)
        .navigationTitle("Animated reordering")
    }
}

@Observable
private final class AnimatedReorderingViewModel {
    let entries: ViewData<[SampleEntry]>

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private var isReversed = false

    init() {
        entries = ViewData(Self.originalEntries)
    }

    func reverseRowOrder() {
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
