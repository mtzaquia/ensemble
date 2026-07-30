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

/// A decision produced while turning observed state into an asynchronous stream.
///
/// Use ``skip`` while observed state has no update to deliver, ``yield(_:)`` for an ordinary
/// element, and ``reset`` when a bound ``ViewData`` value should return to its initial state.
public enum ObservationEmission<Element> {
    /// Waits for another observed change without producing a stream element.
    case skip

    /// Produces an element from the current observed state.
    ///
    /// - Parameter element: The element delivered to the stream's consumer.
    case yield(Element)

    /// Produces a reset instruction and immediately evaluates the observed state again.
    ///
    /// Immediate reevaluation lets a producer reset presentation before delivering replacement
    /// state that became available in the same observation transaction.
    case reset
}

extension ObservationEmission: Equatable where Element: Equatable {}
extension ObservationEmission: Sendable where Element: Sendable {}

public extension AsyncStream {
    /// Creates a stream by repeatedly evaluating a main actor-isolated observation.
    ///
    /// The closure is evaluated immediately. Observable properties it reads are tracked until one
    /// changes, after which the closure is evaluated again on the main actor. A
    /// ``ObservationEmission/skip`` decision waits without producing an element.
    /// ``ObservationEmission/yield(_:)`` and ``ObservationEmission/reset`` are delivered in order
    /// using unbounded buffering so a reset cannot be dropped before a replacement element.
    ///
    /// Returning ``ObservationEmission/reset`` causes one immediate reevaluation. Repeated reset
    /// decisions without an intervening decision or observed change are coalesced to prevent a
    /// producer loop.
    ///
    /// Emitted elements must be `Sendable` because the stream may be consumed outside the main
    /// actor. The observable reads and emission decision remain main actor-isolated.
    ///
    /// Cancelling iteration stops the observation and finishes the stream.
    ///
    /// - Parameter emissions: A closure that reads observable state and decides what to emit.
    /// - Returns: A fresh stream of yielded elements and reset instructions.
    @MainActor
    static func observing<ObservedElement: Sendable>(
        emissions: @escaping @MainActor @Sendable () ->
            ObservationEmission<ObservedElement>
    ) -> Self where Element == ObservationEmission<ObservedElement> {
        Self { continuation in
            let producer = Task { @MainActor in
                let (changes, changeContinuation) = AsyncStream<Void>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                var changeIterator = changes.makeAsyncIterator()
                var isImmediateResetEvaluation = false

                defer {
                    changeContinuation.finish()
                    continuation.finish()
                }

                while Task.isCancelled == false {
                    let emission = withObservationTracking {
                        emissions()
                    } onChange: {
                        changeContinuation.yield()
                    }

                    switch emission {
                    case .skip:
                        isImmediateResetEvaluation = false

                    case .yield(let element):
                        isImmediateResetEvaluation = false
                        if case .terminated = continuation.yield(.yield(element)) {
                            return
                        }

                    case .reset:
                        guard isImmediateResetEvaluation == false else {
                            isImmediateResetEvaluation = false
                            guard await changeIterator.next() != nil else { return }
                            continue
                        }

                        if case .terminated = continuation.yield(.reset) {
                            return
                        }
                        isImmediateResetEvaluation = true
                        continue
                    }

                    guard await changeIterator.next() != nil else { return }
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
}
