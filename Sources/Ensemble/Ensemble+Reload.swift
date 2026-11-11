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

extension Ensemble {
    /// Calls each source's reload concurrently and waits for every request action.
    ///
    /// Sources may hold different value types. Each call has the same behavior as
    /// ``ViewData/reload()``. Source connections belong to their models and keep delivering updates
    /// after the requests finish.
    ///
    /// Each source handles its own results, failures, and resets. A failure does not cancel sibling
    /// requests or throw from the batch. Completion means every request action finished; streamed
    /// outcomes may be delivered separately while the owning model remains alive.
    /// Caller cancellation propagates to outstanding work.
    /// Producers remain responsible for cooperative cancellation and update delivery.
    ///
    /// Repeated instances are reloaded once. Unmanaged data, disabled reloads, an empty batch, and
    /// already-cancelled calls do nothing. No persistent context or registration is created.
    ///
    /// ```swift
    /// await Ensemble.reload(model.profile, model.activity, model.notifications)
    /// ```
    ///
    /// - Parameter sources: The independent `ViewData` instances to reload.
    @MainActor
    public static func reload<each Value>(_ sources: repeat ViewData<each Value>) async {
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            var identities: Set<ObjectIdentifier> = []
            func enqueue<Chunk>(_ source: ViewData<Chunk>) {
                guard identities.insert(ObjectIdentifier(source)).inserted else { return }
                group.addTask { await source.reload() }
            }
            repeat enqueue(each sources)
        }
    }
}
