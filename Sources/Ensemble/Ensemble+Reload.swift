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
    /// Reloads independent presentation sources concurrently and waits for every request action.
    ///
    /// Sources may hold different value types. Each managed source is observed for the duration
    /// of the batch, so a startup request does not depend on `AsyncContent` activation. A newly
    /// connected cold source uses that first subscription instead of starting a second request.
    /// Existing consumers keep their own observation leases when the batch finishes.
    ///
    /// Each source handles its own results, failures, and resets. A failure does not cancel sibling
    /// requests or throw from the batch. Completion means every request action finished; streamed
    /// outcomes may be delivered separately. Consumers that need ongoing or queued delivery after
    /// the actions finish must keep their own observation, such as `AsyncContent` or `observe()`.
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
        var identities: Set<ObjectIdentifier> = []
        var operations: [ViewDataReloadOperation] = []
        func prepare<Chunk>(_ source: ViewData<Chunk>) {
            guard identities.insert(ObjectIdentifier(source)).inserted,
                  let operation = source.prepareBatchReload() else { return }
            operations.append(operation)
        }
        repeat prepare(each sources)
        defer {
            for operation in operations { operation.finish() }
        }
        await runReloadOperations(operations)
    }
}

@MainActor
private func runReloadOperations(_ operations: [ViewDataReloadOperation]) async {
    await withTaskGroup(of: Void.self) { group in
        for operation in operations {
            group.addTask(operation: operation.run)
        }
    }
}

// Only request actions are erased here; source values remain in their typed ViewData bindings.
struct ViewDataReloadOperation: Sendable {
    let run: @MainActor @Sendable () async -> Void
    let finish: @MainActor @Sendable () -> Void
}

extension ViewData {
    func prepareBatchReload() -> ViewDataReloadOperation? {
        guard let binding, let request = binding.acquireReloadObservation(self) else { return nil }
        return ViewDataReloadOperation(
            run: {
                if request.reuseConnection {
                    await self.binding?.waitForConnection(request.connection)
                } else {
                    await self.reload()
                }
            },
            finish: { self.binding?.releaseReloadObservation() }
        )
    }
}
