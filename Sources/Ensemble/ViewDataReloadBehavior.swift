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

/// Defines how a ``ViewDataContext`` reloads a bound ``ViewData`` value.
public enum ViewDataReloadBehavior {
    /// Cancels the current subscription and creates a fresh sequence from the source factory.
    case resubscribe

    /// Keeps an active subscription and asks its upstream producer to publish a new result.
    ///
    /// If the sequence has already completed, the context creates a fresh sequence before calling
    /// the action. The action must publish into the sequence returned by the source factory.
    ///
    /// - Parameter action: The main actor-isolated operation that starts the upstream refresh.
    case refresh(@MainActor () -> Void)

    /// Installs no reload or failure-retry action for the binding.
    case disabled
}
