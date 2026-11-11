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

import Foundation
import os

/// Ensemble request operations and global diagnostic configuration.
public enum Ensemble {
    /// The amount of lifecycle detail emitted by Ensemble in debug builds.
    public enum DebugLogLevel: Equatable, Sendable {
        /// Disables lifecycle logs.
        case off

        /// Logs loads, bindings, reloads, cancellations, and failures.
        case normal

        /// Includes dormant sources, scheduled connections, unchanged identities, values, and completion.
        case trace
    }

    private nonisolated static let debugLock =
        OSAllocatedUnfairLock(initialState: DebugLogLevel.off)

    /// Controls lifecycle logging emitted in debug builds.
    ///
    /// ```swift
    /// Ensemble.debug = .trace
    /// ```
    public nonisolated static var debug: DebugLogLevel {
        get { debugLock.withLock { $0 } }
        set { debugLock.withLock { $0 = newValue } }
    }
}

nonisolated let ensembleLog = Logger(
    subsystem: "eu.lelfe.ensemble",
    category: "Ensemble"
)

enum EnsembleReloadMode: String {
    case resubscribe
    case refresh
    case loadable
    case disabled
}

enum EnsembleConnectionReason: String, CaseIterable {
    case render, connect, reload, identityChanged, coldReload, completedSource
}

enum EnsembleReloadTrigger: String { case reload, retry }
enum EnsembleDisconnectionReason: String { case replaced, ownerReleased }

struct EnsembleLogSource {
    let declaration: String
    let destination: ObjectIdentifier

    var fields: String {
        let name = declaration
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "source=\"\(name)\" destination=\(destination)"
    }
}

enum EnsembleLogEvent {
    case loadStarted(destination: ObjectIdentifier)
    case loadSucceeded(destination: ObjectIdentifier)
    case loadFailed(destination: ObjectIdentifier, error: any Error)
    case loadCancelled(destination: ObjectIdentifier)
    case sourceInstalled(source: EnsembleLogSource)
    case connectionScheduled(source: EnsembleLogSource, reason: EnsembleConnectionReason)
    case bindingStarted(source: EnsembleLogSource, generation: UInt, reason: EnsembleConnectionReason, reload: EnsembleReloadMode)
    case bindingIdentityUnchanged(source: EnsembleLogSource, generation: UInt)
    case reloadJoinedInitial(source: EnsembleLogSource, generation: UInt)
    case bindingReceivedValue(source: EnsembleLogSource, generation: UInt)
    case bindingReceivedReset(source: EnsembleLogSource, generation: UInt)
    case bindingReceivedFailure(source: EnsembleLogSource, generation: UInt, error: any Error)
    case bindingCompleted(source: EnsembleLogSource, generation: UInt)
    case reloadRequested(source: EnsembleLogSource, generation: UInt, mode: EnsembleReloadMode, trigger: EnsembleReloadTrigger)
    case bindingRequestCancelled(source: EnsembleLogSource, generation: UInt)
    case bindingCancelled(source: EnsembleLogSource, generation: UInt, reason: EnsembleDisconnectionReason)

    var logLevel: Ensemble.DebugLogLevel {
        switch self {
        case .sourceInstalled, .connectionScheduled, .bindingIdentityUnchanged, .reloadJoinedInitial,
             .bindingReceivedValue, .bindingReceivedReset, .bindingCompleted:
            .trace
        default:
            .normal
        }
    }

    var message: String {
        switch self {
        case .loadStarted(let destination):
            "[load] → started | destination=\(destination)"
        case .loadSucceeded(let destination):
            "[load] ✓ succeeded | destination=\(destination)"
        case .loadFailed(let destination, let error):
            "[load] ✗ failed | destination=\(destination) error=\(error)"
        case .loadCancelled(let destination):
            "[load] • cancelled | destination=\(destination)"
        case .sourceInstalled(let source):
            "[bind] • installed | \(source.fields) state=dormant"
        case .connectionScheduled(let source, let reason):
            "[bind] ⏳ scheduled | \(source.fields) reason=\(reason.rawValue)"
        case .bindingStarted(let source, let generation, let reason, let reload):
            "[bind] → started | \(source.fields) generation=\(generation) reason=\(reason.rawValue) reload=\(reload.rawValue)"
        case .bindingIdentityUnchanged(let source, let generation):
            "[bind] • kept connection | \(source.fields) generation=\(generation) reason=identityEqual"
        case .reloadJoinedInitial(let source, let generation):
            "[reload] • joined initial load | \(source.fields) generation=\(generation)"
        case .bindingReceivedValue(let source, let generation):
            "[bind] ✓ received value | \(source.fields) generation=\(generation)"
        case .bindingReceivedReset(let source, let generation):
            "[bind] • received reset | \(source.fields) generation=\(generation)"
        case .bindingReceivedFailure(let source, let generation, let error):
            "[bind] ✗ received failure | \(source.fields) generation=\(generation) error=\(error)"
        case .bindingCompleted(let source, let generation):
            "[bind] • completed | \(source.fields) generation=\(generation)"
        case .reloadRequested(let source, let generation, let mode, let trigger):
            "[reload] ↻ requested | \(source.fields) generation=\(generation) mode=\(mode.rawValue) trigger=\(trigger.rawValue)"
        case .bindingRequestCancelled(let source, let generation):
            "[reload] • cancelled cold request | \(source.fields) generation=\(generation)"
        case .bindingCancelled(let source, let generation, let reason):
            "[bind] • cancelled | \(source.fields) generation=\(generation) reason=\(reason.rawValue)"
        }
    }

}

extension Logger {
    func ensembleDebug(_ event: @autoclosure () -> EnsembleLogEvent) {
#if DEBUG
        let configuredLevel = Ensemble.debug
        guard configuredLevel != .off else { return }

        let event = event()
        guard configuredLevel.includes(event.logLevel) else { return }
        debug("\(event.message, privacy: .public)")
#endif
    }
}

extension Ensemble.DebugLogLevel {
    func includes(_ eventLevel: Self) -> Bool {
        switch (self, eventLevel) {
        case (.trace, _), (.normal, .normal), (.off, .off):
            true
        default:
            false
        }
    }
}
