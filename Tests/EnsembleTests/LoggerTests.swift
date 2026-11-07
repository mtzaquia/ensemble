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

import Testing
@testable import Ensemble

@Suite("Logging", .serialized)
struct LoggerTests {
    enum TestError: Error { case expected }

    @Test("Every lifecycle event has a deliberate minimum log level")
    func eventLevels() {
        let source = EnsembleLogSource(declaration: "Model.entries", destination: ObjectIdentifier(ViewData<Int>()))
        let events: [(EnsembleLogEvent, Ensemble.DebugLogLevel)] = [
            (.loadStarted(destination: source.destination), .normal),
            (.loadSucceeded(destination: source.destination), .normal),
            (.loadFailed(destination: source.destination, error: TestError.expected), .normal),
            (.loadCancelled(destination: source.destination), .normal),
            (.sourceInstalled(source: source), .trace),
            (.connectionScheduled(source: source, reason: .connect), .trace),
            (.bindingStarted(source: source, generation: 1, reason: .connect, reload: .refresh), .normal),
            (.bindingIdentityUnchanged(source: source, generation: 1), .trace),
            (.reloadJoinedInitial(source: source, generation: 1), .trace),
            (.bindingReceivedValue(source: source, generation: 1), .trace),
            (.bindingReceivedReset(source: source, generation: 1), .trace),
            (.bindingReceivedFailure(source: source, generation: 1, error: TestError.expected), .normal),
            (.bindingCompleted(source: source, generation: 1), .trace),
            (.reloadRequested(source: source, generation: 1, mode: .refresh, trigger: .retry), .normal),
            (.bindingRequestCancelled(source: source, generation: 1), .normal),
            (.bindingCancelled(source: source, generation: 1, reason: .ownerReleased), .normal),
        ]
        for (event, level) in events { #expect(event.logLevel == level) }
    }

    @Test("Log levels include only the configured lifecycle detail")
    func levelMatrix() {
        for level in [Ensemble.DebugLogLevel.normal, .trace] {
            #expect(!Ensemble.DebugLogLevel.off.includes(level))
            #expect(Ensemble.DebugLogLevel.trace.includes(level))
        }
        #expect(Ensemble.DebugLogLevel.normal.includes(.normal))
        #expect(!Ensemble.DebugLogLevel.normal.includes(.trace))
    }

    @Test("Source events identify the declaration, generation, and lifecycle decision")
    func eventMessages() {
        let data = ViewData<Int>()
        let source = EnsembleLogSource(declaration: "Wallet.sections", destination: ObjectIdentifier(data))
        let fields = "source=\"Wallet.sections\" destination=\(source.destination)"
        let events: [(EnsembleLogEvent, String)] = [
            (.sourceInstalled(source: source), "[bind] • installed | \(fields) state=dormant"),
            (.connectionScheduled(source: source, reason: .render), "[bind] ⏳ scheduled | \(fields) reason=render"),
            (.bindingStarted(source: source, generation: 2, reason: .identityChanged, reload: .refresh),
             "[bind] → started | \(fields) generation=2 reason=identityChanged reload=refresh"),
            (.bindingIdentityUnchanged(source: source, generation: 2),
             "[bind] • kept connection | \(fields) generation=2 reason=identityEqual"),
            (.reloadJoinedInitial(source: source, generation: 2), "[reload] • joined initial load | \(fields) generation=2"),
            (.bindingReceivedValue(source: source, generation: 2), "[bind] ✓ received value | \(fields) generation=2"),
            (.bindingReceivedReset(source: source, generation: 2), "[bind] • received reset | \(fields) generation=2"),
            (.bindingReceivedFailure(source: source, generation: 2, error: TestError.expected),
             "[bind] ✗ received failure | \(fields) generation=2 error=expected"),
            (.bindingCompleted(source: source, generation: 2), "[bind] • completed | \(fields) generation=2"),
            (.reloadRequested(source: source, generation: 2, mode: .refresh, trigger: .retry),
             "[reload] ↻ requested | \(fields) generation=2 mode=refresh trigger=retry"),
            (.bindingRequestCancelled(source: source, generation: 2), "[reload] • cancelled cold request | \(fields) generation=2"),
            (.bindingCancelled(source: source, generation: 2, reason: .ownerReleased),
             "[bind] • cancelled | \(fields) generation=2 reason=ownerReleased"),
            (.bindingCancelled(source: source, generation: 1, reason: .replaced),
             "[bind] • cancelled | \(fields) generation=1 reason=replaced"),
        ]
        for (event, expected) in events { #expect(event.message == expected) }
    }

    @Test("Every connection reason is visible without rendering a domain identity", arguments: EnsembleConnectionReason.allCases)
    func connectionReasons(_ reason: EnsembleConnectionReason) {
        let source = EnsembleLogSource(declaration: "Model.entries", destination: ObjectIdentifier(ViewData<Int>()))
        let message = EnsembleLogEvent.bindingStarted(source: source, generation: 3, reason: reason, reload: .resubscribe).message
        #expect(message.contains("reason=\(reason.rawValue)"))
        #expect(!message.contains("identity="))
        #expect(!message.contains("value="))
    }

    @Test("Declaration labels escape quotes and control characters")
    func escapedLabels() {
        let source = EnsembleLogSource(declaration: "Model.\"entries\\\n\r\t", destination: ObjectIdentifier(ViewData<Int>()))
        #expect(source.fields == "source=\"Model.\\\"entries\\\\\\n\\r\\t\" destination=\(source.destination)")
    }

    @Test("Disabled diagnostics do not construct events")
    func disabledLogging() {
        let previous = Ensemble.debug
        defer { Ensemble.debug = previous }
        Ensemble.debug = .off
        var constructed = false
        func event() -> EnsembleLogEvent {
            constructed = true
            return .loadStarted(destination: ObjectIdentifier(ViewData<Int>()))
        }
        ensembleLog.ensembleDebug(event())
        #expect(!constructed)
    }
}
