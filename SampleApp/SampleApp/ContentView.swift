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

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SampleScenario.allCases) { scenario in
                        ScenarioLink(scenario: scenario)
                    }
                } header: {
                    Text("Scenarios")
                } footer: {
                    Text("Each screen isolates one presentation contract while using the same ViewData and AsyncContent APIs.")
                }
            }
            .accessibilityIdentifier(SampleAppAccessibility.catalog)
            .navigationTitle("Ensemble")
        }
    }
}

private struct ScenarioLink: View {
    let scenario: SampleScenario

    var body: some View {
        NavigationLink {
            ScenarioDestination(scenario: scenario)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scenario.title)
                        .font(.headline)
                    Text(scenario.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: scenario.systemImage)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier(SampleAppAccessibility.scenarioLink(scenario))
    }
}

#Preview {
    ContentView()
}
