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

extension ViewData {
    /// Performs one throwing asynchronous operation and applies its result to presentation state.
    ///
    /// Loading begins before `operation` is called. A returned value becomes the destination's
    /// latest successful value, while a thrown error enters failure and preserves any latest value.
    /// Cancellation is not presented as a new failure; it restores a failure that preceded loading,
    /// settles to retained success, or settles to empty when no later update has replaced this load's
    /// loading transition.
    ///
    /// A load does not cancel or replace a binding for the same destination. Load completions and
    /// bound results are accepted in arrival order. The load follows the lifetime of the caller's
    /// task and does not install a retry action.
    ///
    /// - Parameter operation: The one-shot asynchronous operation to perform.
    public func load(_ operation: () async throws -> Value) async {
        let destination = self
        let identifier = ObjectIdentifier(destination)
        ensembleLog.ensembleDebug(.loadStarted(destination: identifier))
        let loadingToken = destination.beginLoading()

        do {
            let value = try await operation()
            try Task.checkCancellation()
            destination.set(value)
            ensembleLog.ensembleDebug(.loadSucceeded(destination: identifier))
        } catch is CancellationError {
            destination.finishLoading(loadingToken)
            ensembleLog.ensembleDebug(.loadCancelled(destination: identifier))
        } catch {
            guard Task.isCancelled == false else {
                destination.finishLoading(loadingToken)
                ensembleLog.ensembleDebug(.loadCancelled(destination: identifier))
                return
            }
            destination.fail(error)
            ensembleLog.ensembleDebug(.loadFailed(destination: identifier, error: error))
        }
    }
}
