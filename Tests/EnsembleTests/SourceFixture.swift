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

import Observation
@testable import Ensemble

// Typed fixtures exercise the same generated declarations as clients. Keep each fixture alive
// for the source's lifetime; ViewData deliberately holds its owning model weakly.
final class SourceFixture<Value, Source: AsyncSequence> {
    let initial: ViewDataAvailability<Value>
    private var makeSource: @MainActor () -> Source
    private let inputs = SourceFixtureInputs()
    private let refreshAction: (@MainActor () async -> Void)?
    private let allowsReload: Bool
    private let adapter: @MainActor (SourceFixture<Value, Source>, Source.Element, ViewDataSink<Value>) -> Void

    var factory: @MainActor () -> Source {
        get {
            _ = inputs.revision
            return makeSource
        }
        set {
            makeSource = newValue
            inputs.revision += 1
        }
    }

    @ViewDataSource(
        initial: { (model: Self) in model.initial },
        make: { model in model.factory() },
        receive: { model, element, sink in model.adapter(model, element, sink) }
    )
    private var cold: ViewData<Value>

    @ViewDataSource(
        initial: { (model: Self) in model.initial },
        make: { model in model.factory() },
        refresh: { model in await model.refreshAction?() },
        receive: { model, element, sink in model.adapter(model, element, sink) }
    )
    private var hot: ViewData<Value>

    @ViewDataSource(
        initial: { (model: Self) in model.initial },
        make: { model in model.factory() },
        allowsReload: false,
        receive: { model, element, sink in model.adapter(model, element, sink) }
    )
    private var passive: ViewData<Value>

    var data: ViewData<Value> {
        if !allowsReload { return passive }
        return refreshAction == nil ? cold : hot
    }

    convenience init<Failure: Error>(
        _ initial: ViewDataAvailability<Value> = .unavailable,
        make: @escaping @MainActor () -> Source,
        refresh: (@MainActor () async -> Void)? = nil,
        allowsReload: Bool = true,
        receive: (@MainActor (SourceFixture<Value, Source>, Source.Element, ViewDataSink<Value>) -> Void)? = nil
    ) where Source.Element == Result<Value, Failure> {
        self.init(
            initial, make: make, refresh: refresh, allowsReload: allowsReload,
            receive: receive ?? { _, result, sink in sink.receive(result) }
        )
    }

    init(
        _ initial: ViewDataAvailability<Value> = .unavailable,
        make: @escaping @MainActor () -> Source,
        refresh: (@MainActor () async -> Void)? = nil,
        allowsReload: Bool = true,
        receive: @escaping @MainActor (SourceFixture<Value, Source>, Source.Element, ViewDataSink<Value>) -> Void
    ) {
        self.initial = initial
        self.makeSource = make
        self.refreshAction = refresh
        self.allowsReload = allowsReload
        self.adapter = receive
    }
}

@Observable
private final class SourceFixtureInputs {
    var revision = 0
}
