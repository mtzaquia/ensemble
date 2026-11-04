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
import EnsembleMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@Suite("Source macro expansion")
struct ViewDataSourceMacroTests {
    @Test("Generates source-backed accessors with a default result adapter", arguments: ["", ", receive: nil"])
    func propertyExpansion(_ adapter: String) {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(make: { (model: Self) in model.values() }\(adapter))
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int> {
                    @storageRestrictions(initializes: _value)
                    init(initialValue) {
                        _value = initialValue
                    }
                    get {
                        _value._installSource(
                            owner: self,
                            make: { (model: Model) in
                                model.values()
                            },
                            refresh: nil,
                            receive: { result, sink in
                                sink.receive(result)
                            }
                        )
                        return _value
                    }
                }

                @ObservationIgnored private var _value: ViewData<Int>
            }
            """,
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Forwards custom receive and async refresh closures")
    func customAdapterExpansion() {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(
                    make: { (model: Self) in model.updates() },
                    refresh: { model in await model.reload() },
                    receive: { update, sink in
                        switch update {
                        case .result(let result): sink.receive(result)
                        case .reset: sink.reset()
                        }
                    }
                )
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int> {
                    @storageRestrictions(initializes: _value)
                    init(initialValue) {
                        _value = initialValue
                    }
                    get {
                        _value._installSource(
                            owner: self,
                            make: { (model: Model) in
                                model.updates()
                            },
                            refresh: { model in
                                await model.reload()
                            },
                            receive: { update, sink in
                                switch update {
                                case .result(let result):
                                    sink.receive(result)
                                case .reset:
                                    sink.reset()
                                }
                            }
                        )
                        return _value
                    }
                }

                @ObservationIgnored private var _value: ViewData<Int>
            }
            """,
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Rejects direct instance captures, including capture lists and nested callbacks", arguments: [
        "make: { (model: Model) in self.values() }",
        "make: { [weak self] (model: Model) in model.values() }",
        "make: { (model: Model) in model.values { self.reload() } }",
        "make: { (model: Model) in super.values() }",
        "make: { (model: Model) in model.values() }, refresh: { model in self.reload() }",
        "make: { (model: Model) in model.values() }, receive: { value, sink in self.apply(value) }",
    ])
    func instanceCapture(_ arguments: String) {
        let token = arguments.range(of: "self") ?? arguments.range(of: "super")!
        let column = "    @ViewDataSource(".count + arguments.distance(from: arguments.startIndex, to: token.lowerBound) + 1
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(\(arguments))
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int>
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "@ViewDataSource callbacks must not capture instance self or super",
                line: 2, column: column
            )],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Rejects opaque callback references whose captures cannot be checked")
    func opaqueCallback() {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(make: factory)
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int>
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "@ViewDataSource callbacks must be inline closures so their captures can be checked",
                line: 2, column: 27
            )],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Reports unsupported declarations instead of producing malformed storage")
    func invalidProperty() {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(make: factory)
                let value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                let value: ViewData<Int>
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ViewDataSource requires one stored instance var explicitly typed as ViewData<Value> in a class",
                    line: 2, column: 5
                ),
            ],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }
}
