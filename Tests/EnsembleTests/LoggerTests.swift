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

@Suite("Logging")
struct LoggerTests {
    enum TestError: Error {
        case expected
    }

    @Test("Log events separate normal lifecycle from trace detail")
    func eventLevels() {
        let destination = ObjectIdentifier(ViewData<Int>())

        #expect(
            EnsembleLogEvent.loadStarted(destination: destination).logLevel == .normal
        )
        #expect(
            EnsembleLogEvent.bindingReceivedFailure(
                destination: destination,
                error: TestError.expected
            ).logLevel == .normal
        )
        #expect(
            EnsembleLogEvent.bindingReceivedValue(destination: destination).logLevel == .trace
        )
        #expect(
            EnsembleLogEvent.bindingReceivedReset(destination: destination).logLevel == .trace
        )
        #expect(
            EnsembleLogEvent.bindingCompleted(destination: destination).logLevel == .trace
        )
        #expect(
            EnsembleLogEvent.reloadIgnored(destination: destination).logLevel == .normal
        )
    }

    @Test("Ignored reloads use info severity")
    func eventSeverities() {
        let destination = ObjectIdentifier(ViewData<Int>())

        #expect(
            EnsembleLogEvent.reloadRequested(
                destination: destination,
                mode: .refresh
            ).severity == .debug
        )
        #expect(
            EnsembleLogEvent.reloadIgnored(destination: destination).severity == .info
        )
    }

    @Test("Log messages include lifecycle context without values")
    func eventMessages() {
        let data = ViewData<Int>()
        let destination = ObjectIdentifier(data)
        let message = EnsembleLogEvent.bindingStarted(
            destination: destination,
            reload: .refresh
        ).message

        #expect(message.contains("[bind] → started"))
        #expect(message.contains("destination=\(destination)"))
        #expect(message.contains("reload=refresh"))

        let valueMessage =
            EnsembleLogEvent.bindingReceivedValue(destination: destination).message
        #expect(valueMessage.contains("[bind] ✓ received value"))
        #expect(valueMessage.contains("destination=\(destination)"))

        let resetMessage =
            EnsembleLogEvent.bindingReceivedReset(destination: destination).message
        #expect(resetMessage.contains("[bind] • received reset"))
        #expect(resetMessage.contains("destination=\(destination)"))

        let ignoredReloadMessage =
            EnsembleLogEvent.reloadIgnored(destination: destination).message
        #expect(
            ignoredReloadMessage ==
                "[reload] ⊘ ignored because no source is bound | destination=\(destination)"
        )
    }
}
