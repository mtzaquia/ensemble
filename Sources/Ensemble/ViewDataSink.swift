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

/// Applies an accepted binding update to its presentation state.
///
/// Ensemble supplies a sink to the custom ``ViewDataContext/bind(_:to:reload:receive:)`` handler.
/// Actions are applied only while that binding remains active. A sink retained beyond the handler
/// is safe to call, but its actions are ignored after the binding is replaced or cancelled.
@MainActor
public struct ViewDataSink<Value> {
    enum Action {
        case value(Value)
        case failure(any Error)
        case reset
    }

    private let apply: @MainActor (Action) -> Void

    init(
        apply: @escaping @MainActor (Action) -> Void
    ) {
        self.apply = apply
    }

    /// Applies a success or failure without ending the binding.
    ///
    /// A success replaces the latest value. A failure enters the failure phase while preserving
    /// the latest successful value.
    ///
    /// - Parameter result: The accepted result to apply.
    public func receive<Failure: Error>(_ result: Result<Value, Failure>) {
        switch result {
        case .success(let value):
            apply(.value(value))
        case .failure(let error):
            apply(.failure(error))
        }
    }

    /// Returns presentation state to empty without ending the binding.
    public func reset() {
        apply(.reset)
    }
}
