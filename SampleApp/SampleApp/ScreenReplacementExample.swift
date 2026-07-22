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

struct ScreenReplacementExample: View {
    @State private var viewModel = ScreenReplacementViewModel()

    var body: some View {
        ZStack {
            AsyncContent(
                viewModel.entries,
                loading: .placeholder(SampleEntry.placeholders),
                failure: .replace
            ) { entries, source in
                List {
                    SampleEntryRows(entries: entries, source: source)
                }
                .animation(.default, value: viewModel.entries.animationValue)
                .accessibilityIdentifier(SampleAppAccessibility.screenReplacementContent)
            } failure: { error, retry in
                ContentUnavailableView {
                    Label("Entries unavailable", systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier(SampleAppAccessibility.screenReplacementFailure)
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    if let retry {
                        Button("Try again") {
                            retry()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(SampleAppAccessibility.screenReplacementRetry)
                    }
                }
            }
        }
        .navigationTitle("Screen replacement")
        .toolbar {
            Menu("Actions", systemImage: "ellipsis.circle") {
                Button("Reload stream") {
                    viewModel.reload()
                }
                Button("Load one value") {
                    viewModel.loadOneValue()
                }
            }
        }
        .task {
            viewModel.start()
        }
    }
}

@Observable
private final class ScreenReplacementViewModel {
    let entries = ViewData<[SampleEntry]>()

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private let useCase = ScreenReplacementUseCase()
    @ObservationIgnored private var hasStarted = false

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true
        context.bind(useCase.values, to: entries)
    }

    func reload() {
        context.reload(entries)
    }

    func loadOneValue() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await context.load({
                [
                    SampleEntry(
                        id: 100,
                        title: "One-shot value",
                        detail: "Loaded without replacing the bound stream"
                    ),
                ]
            }, to: entries)
        }
    }
}

private final class ScreenReplacementUseCase {
    private var attempt = 0

    func values() -> AsyncStream<Result<[SampleEntry], SampleFailure>> {
        attempt += 1
        let result: Result<[SampleEntry], SampleFailure> = attempt == 1
            ? .failure(.unavailable)
            : .success(SampleEntry.recovered)
        return DelayedSource(result: result).values()
    }
}
