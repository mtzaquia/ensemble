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

struct IndependentSectionsExample: View {
    @State private var viewModel = IndependentSectionsViewModel()

    var body: some View {
        List {
            AsyncContent(
                viewModel.activity,
                loading: .placeholder(SampleEntry.placeholders),
                failure: .failureContent
            ) { entries, source in
                Section {
                    SampleEntryRows(entries: entries, source: source)
                } header: {
                    sectionHeader("Activity", source: source)
                }
            } failure: { error, retry in
                Section {
                    SampleInlineFailure(
                        title: "Activity unavailable",
                        error: error,
                        retry: retry,
                        identifier: "activity"
                    )
                }
            }

            AsyncContent(
                viewModel.account,
                loading: .retained,
                failure: .retained
            ) { entries, source in
                Section {
                    SampleEntryRows(entries: entries, source: source)
                } header: {
                    sectionHeader("Account", source: source)
                }
            } failure: { error, retry in
                Section {
                    SampleInlineFailure(
                        title: "Account unavailable",
                        error: error,
                        retry: retry,
                        identifier: "account"
                    )
                }
            }

            AsyncContent(
                viewModel.tip,
                loading: .hidden,
                failure: .failureContent
            ) { tip, source in
                Section {
                    Text(tip)
                        .accessibilityIdentifier(SampleAppAccessibility.independentSectionsTip)
                } header: {
                    sectionHeader("Tip", source: source)
                }
            } failure: { error, retry in
                Section {
                    SampleInlineFailure(
                        title: "Tip unavailable",
                        error: error,
                        retry: retry,
                        identifier: "tip"
                    )
                }
            }

            Section("Controls") {
                Button("Reload every section") {
                    viewModel.reload()
                }
                .accessibilityIdentifier(SampleAppAccessibility.independentSectionsReload)
            }
        }
        .animation(.default, value: viewModel.activity.animationValue)
        .animation(.default, value: viewModel.account.animationValue)
        .animation(.default, value: viewModel.tip.animationValue)
        .accessibilityIdentifier(SampleAppAccessibility.independentSectionsScreen)
        .navigationTitle("Independent sections")
        .task {
            viewModel.start()
        }
    }

    private func sectionHeader(_ title: String, source: AsyncContentSource) -> some View {
        HStack {
            Text(title)
            Spacer()
            SampleSourceBadge(source: source)
        }
    }
}

@Observable
private final class IndependentSectionsViewModel {
    let activity = ViewData<[SampleEntry]>()
    let account = ViewData(SampleEntry.cached)
    let tip = ViewData<String>()

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private let useCase = IndependentSectionsUseCase()
    @ObservationIgnored private var hasStarted = false

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true
        context.bind(useCase.activityValues, to: activity)
        context.bind(useCase.accountValues, to: account)
        context.bind(useCase.tipValues, to: tip)
    }

    func reload() {
        context.reload(activity)
        context.reload(account)
        context.reload(tip)
    }
}

private final class IndependentSectionsUseCase {
    private var accountAttempt = 0
    private var tipAttempt = 0

    func activityValues() -> AsyncStream<Result<[SampleEntry], SampleFailure>> {
        DelayedSource(
            result: .success([
                SampleEntry(id: 300, title: "Recent activity", detail: "This section loaded independently"),
                SampleEntry(id: 301, title: "Another event", detail: "Other sections can still be loading or failed"),
            ]),
            delay: .milliseconds(900)
        ).values()
    }

    func accountValues() -> AsyncStream<Result<[SampleEntry], SampleFailure>> {
        accountAttempt += 1
        let result: Result<[SampleEntry], SampleFailure> = accountAttempt == 1
            ? .failure(.offline)
            : .success([
                SampleEntry(id: 400, title: "Account refreshed", detail: "Retry replaced the retained account value"),
            ])
        return DelayedSource(result: result, delay: .milliseconds(1_200)).values()
    }

    func tipValues() -> AsyncStream<Result<String, SampleFailure>> {
        tipAttempt += 1
        let result: Result<String, SampleFailure> = tipAttempt == 1
            ? .failure(.offline)
            : .success("A later success can recover this section without affecting its siblings.")
        return DelayedSource(result: result, delay: .milliseconds(600)).values()
    }
}
