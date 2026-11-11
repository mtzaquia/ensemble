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
    @Test("Generates stable get-only source state with a default result adapter", arguments: ["", ", receive: nil"], [false, true])
    func propertyExpansion(_ adapter: String, _ keyed: Bool) {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(\(keyed ? "id: \\.filterID, " : "")make: { (model: Self) in model.values() }\(adapter))
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int> {
                    get {
                        let __macro_local_4datafMu_ = ViewData<Int>._source(
                            _value,
                            owner: self,
                            declaration: "Model.value",
                            id: {\(keyed ? "" : " _ in")
                                \(keyed ? "$0 [keyPath: \\.filterID]" : "false")
                            },
                            initial: nil,
                            make: { (model: Model) in
                                model.values()
                            },
                            refresh: nil,
                            allowsReload: true,
                            receive: { _, result, sink in
                                sink.receive(result)
                            }
                        )
                        _value = __macro_local_4datafMu_
                        return __macro_local_4datafMu_.data
                    }
                }

                @ObservationIgnored private var _value: ViewData<Int>._Source?
            }
            """,
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Resolves Self in seeds and adapters and forwards refresh and reload policy", arguments: [false, true])
    func ownerCallbacks(_ keyed: Bool) {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(
                    \(keyed ? "id: \\.filterID,\n        " : "")initial: { (model: Self) in model.initial() },
                    make: { model in model.values() },
                    refresh: { model, _ in await model.reload() },
                    allowsReload: false,
                    receive: { (model: Self, result, sink) in model.receive(result, sink: sink) }
                )
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int> {
                    get {
                        let __macro_local_4datafMu_ = ViewData<Int>._source(
                            _value,
                            owner: self,
                            declaration: "Model.value",
                            id: {\(keyed ? "" : " _ in")
                                \(keyed ? "$0 [keyPath: \\.filterID]" : "false")
                            },
                            initial: { (model: Model) in
                                model.initial()
                            },
                            make: { model in
                                model.values()
                            },
                            refresh: { model, _ in
                                await model.reload()
                            },
                            allowsReload: false,
                            receive: { (model: Model, result, sink) in
                                model.receive(result, sink: sink)
                            }
                        )
                        _value = __macro_local_4datafMu_
                        return __macro_local_4datafMu_.data
                    }
                }

                @ObservationIgnored private var _value: ViewData<Int>._Source?
            }
            """,
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Loadable sources forward the producer", arguments: [false, true])
    func loadableExpansion(_ keyed: Bool) {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(\(keyed ? "id: \\.filterID, " : "")updates: { (model: Self) in model.producer() })
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int> {
                    get {
                        let __macro_local_4datafMu_ = ViewData<Int>._source(
                            _value,
                            owner: self,
                            declaration: "Model.value",
                            id: {\(keyed ? "" : " _ in")
                                \(keyed ? "$0 [keyPath: \\.filterID]" : "false")
                            },
                            updates: { (model: Model) in
                                model.producer()
                            },
                            receive: nil
                        )
                        _value = __macro_local_4datafMu_
                        return __macro_local_4datafMu_.data
                    }
                }

                @ObservationIgnored private var _value: ViewData<Int>._Source?
            }
            """,
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Rejects a separate seed for a loadable producer")
    func rejectsLoadableSeed() {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(initial: nil, updates: { (model: Self) in model.producer() })
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int>
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ViewDataSource(updates:) seeds from the producer's availability",
                    line: 2, column: 21
                ),
            ],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Rejects direct instance captures, including seeds and nested callbacks", arguments: [
        "updates: { (model: Model) in self.producer() }",
        "make: { (model: Model) in self.values() }",
        "make: { [weak self] (model: Model) in model.values() }",
        "make: { (model: Model) in model.values { self.reload() } }",
        "make: { (model: Model) in super.values() }",
        "make: { (model: Model) in model.values() }, refresh: { model, _ in self.reload() }",
        "make: { (model: Model) in model.values() }, receive: { _, value, sink in self.apply(value) }",
        "initial: { (model: Model) in self.initial() }, make: { model in model.values() }",
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

    @Test("Identity must be a key-path literal", arguments: ["identityPath", "{ model in model.id }"])
    func identityExpression(_ expression: String) {
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(id: \(expression), make: { (model: Self) in model.values() })
                var value: ViewData<Int>
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int>
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: "@ViewDataSource id must be a key-path literal",
                line: 2, column: "    @ViewDataSource(id: ".count + 1
            )],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Identity subscripts cannot capture instance self")
    func identityCapture() {
        let arguments = "id: \\.items[self.index], make: { (model: Model) in model.values() }"
        let token = arguments.range(of: "self")!
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
                message: "@ViewDataSource id must not capture instance self or super",
                line: 2,
                column: "    @ViewDataSource(".count + arguments.distance(from: arguments.startIndex, to: token.lowerBound) + 1
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
            diagnostics: [DiagnosticSpec(
                message: "@ViewDataSource requires one stored instance var explicitly typed as ViewData<Value> in a class",
                line: 2, column: 5
            )],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }

    @Test("Directs property initializers to the declaration's seed form", arguments: [false, true])
    func propertyInitializer(_ loadable: Bool) {
        let factory = loadable ? "updates: { (model: Self) in model.producer() }"
            : "make: { (model: Self) in model.values() }"
        let message = loadable ? "Supply the seed through the loadable producer's availability"
            : "Supply a seed with @ViewDataSource(initial:), not a property initializer"
        assertMacroExpansion(
            """
            class Model {
                @ViewDataSource(\(factory))
                var value: ViewData<Int> = ViewData(.available(7))
            }
            """,
            expandedSource: """
            class Model {
                var value: ViewData<Int> = ViewData(.available(7))
            }
            """,
            diagnostics: [DiagnosticSpec(
                message: message,
                line: 3, column: 30
            )],
            macroSpecs: ["ViewDataSource": MacroSpec(type: ViewDataSourceMacro.self)],
            failureHandler: { Issue.record(Comment(rawValue: $0.message)) }
        )
    }
}
