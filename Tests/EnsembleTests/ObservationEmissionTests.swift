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
import Testing
@testable import Ensemble

@Suite("Observation emissions")
struct ObservationEmissionTests {
    @Observable
    final class Model {
        var value = 0
        var isReady = false
        var resetRevision = 0

        @ObservationIgnored
        var evaluationCount = 0
    }

    @Test("Observation yields its initial value and later changes")
    func yieldsInitialAndChangedValues() async {
        let model = Model()
        let stream = AsyncStream<ObservationEmission<Int>>.observing {
            .yield(model.value)
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .yield(0))

        model.value = 42
        #expect(await iterator.next() == .yield(42))
    }

    @Test("Skip waits for another observed change without emitting")
    func skipWaitsForChange() async {
        let model = Model()
        let stream = AsyncStream<ObservationEmission<Int>>.observing {
            model.evaluationCount += 1
            return model.isReady ? .yield(model.value) : .skip
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await eventually { model.evaluationCount == 1 })

        model.value = 42
        model.isReady = true
        #expect(await iterator.next() == .yield(42))
    }

    @Test("Reset is delivered before a same-turn replacement")
    func resetPrecedesReplacement() async {
        let model = Model()
        let stream = AsyncStream<ObservationEmission<Int>>.observing(
            resetValue: model.resetRevision
        ) {
            .yield(model.value)
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .yield(0))

        model.resetRevision += 1
        model.value = 42
        #expect(await iterator.next() == .reset)
        #expect(await iterator.next() == .yield(42))
    }

    @Test("The current reset value establishes the subscription baseline")
    func currentResetValueDoesNotReplay() async {
        let model = Model()
        model.resetRevision = 42
        let stream = AsyncStream<ObservationEmission<Int>>.observing(
            resetValue: model.resetRevision
        ) {
            .yield(model.value)
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .yield(0))
    }

    @Test("A reset after stream creation is not absorbed into the baseline")
    func resetAfterStreamCreation() async {
        let model = Model()
        let stream = AsyncStream<ObservationEmission<Int>>.observing(
            resetValue: model.resetRevision
        ) {
            .yield(model.value)
        }

        model.resetRevision += 1
        model.value = 42
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .reset)
        #expect(await iterator.next() == .yield(42))
    }

    @Test("Repeated reset decisions wait for an observed change")
    func repeatedResetWaitsForChange() async {
        let model = Model()
        let stream = AsyncStream<ObservationEmission<Int>>.observing {
            _ = model.value
            model.evaluationCount += 1
            return .reset
        }
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .reset)
        #expect(await eventually { model.evaluationCount == 2 })

        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(model.evaluationCount == 2)

        model.value = 42
        #expect(await iterator.next() == .reset)
        #expect(await eventually { model.evaluationCount == 4 })
    }

    @Test("Cancelling iteration stops observation")
    func cancellationStopsObservation() async {
        let model = Model()
        let stream = AsyncStream<ObservationEmission<Int>>.observing {
            model.evaluationCount += 1
            return .yield(model.value)
        }
        let consumer = Task {
            for await _ in stream {}
        }

        #expect(await eventually { model.evaluationCount == 1 })
        consumer.cancel()
        await consumer.value

        let evaluationCount = model.evaluationCount
        model.value = 42
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(model.evaluationCount == evaluationCount)
    }
}

private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}
