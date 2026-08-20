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

/// Global Ensemble diagnostic configuration.
public enum Ensemble {
    /// The amount of lifecycle detail emitted by Ensemble in debug builds.
    public enum DebugLogLevel: Equatable, Sendable {
        /// Disables lifecycle logs.
        case off

        /// Logs loads, bindings, reloads, cancellations, and failures.
        case normal

        /// Includes each accepted binding value or reset and source completion.
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
    case disabled
}

enum EnsembleLogSeverity: Equatable {
    case debug
    case info
}

enum EnsembleLogEvent {
    case loadStarted(destination: ObjectIdentifier)
    case loadSucceeded(destination: ObjectIdentifier)
    case loadFailed(destination: ObjectIdentifier, error: any Error)
    case loadCancelled(destination: ObjectIdentifier)
    case bindingStarted(destination: ObjectIdentifier, reload: EnsembleReloadMode)
    case bindingReceivedValue(destination: ObjectIdentifier)
    case bindingReceivedReset(destination: ObjectIdentifier)
    case bindingReceivedFailure(destination: ObjectIdentifier, error: any Error)
    case bindingCompleted(destination: ObjectIdentifier)
    case reloadRequested(destination: ObjectIdentifier, mode: EnsembleReloadMode)
    case reloadIgnored(destination: ObjectIdentifier)
    case bindingCancelled(destination: ObjectIdentifier)

    var logLevel: Ensemble.DebugLogLevel {
        switch self {
        case .bindingReceivedValue, .bindingReceivedReset, .bindingCompleted:
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
        case .bindingStarted(let destination, let reload):
            "[bind] → started | destination=\(destination) reload=\(reload.rawValue)"
        case .bindingReceivedValue(let destination):
            "[bind] ✓ received value | destination=\(destination)"
        case .bindingReceivedReset(let destination):
            "[bind] • received reset | destination=\(destination)"
        case .bindingReceivedFailure(let destination, let error):
            "[bind] ✗ received failure | destination=\(destination) error=\(error)"
        case .bindingCompleted(let destination):
            "[bind] • completed | destination=\(destination)"
        case .reloadRequested(let destination, let mode):
            "[reload] ↻ requested | destination=\(destination) mode=\(mode.rawValue)"
        case .reloadIgnored(let destination):
            "[reload] ⊘ ignored because no source is bound | destination=\(destination)"
        case .bindingCancelled(let destination):
            "[bind] • cancelled | destination=\(destination)"
        }
    }

    var severity: EnsembleLogSeverity {
        switch self {
        case .reloadIgnored:
            .info
        default:
            .debug
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
        switch event.severity {
        case .debug:
            debug("\(event.message, privacy: .public)")
        case .info:
            info("\(event.message, privacy: .public)")
        }
#endif
    }
}

private extension Ensemble.DebugLogLevel {
    func includes(_ eventLevel: Self) -> Bool {
        switch (self, eventLevel) {
        case (.trace, _), (.normal, .normal), (.off, .off):
            true
        default:
            false
        }
    }
}

extension ViewDataReloadBehavior {
    var logMode: EnsembleReloadMode {
        switch self {
        case .resubscribe:
            .resubscribe
        case .refresh:
            .refresh
        case .disabled:
            .disabled
        }
    }
}
