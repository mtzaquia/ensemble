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

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private struct SourceDiagnostic: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "Ensemble.ViewDataSource", id: "invalid-property") }
    var severity: DiagnosticSeverity { .error }
}

// Inspect syntax rather than text so comments, strings, and metatype `.self` remain valid.
private final class InstanceCaptureVisitor: SyntaxVisitor {
    var reference: Syntax?

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.baseName.text == "self" || node.baseName.text == "`self`" else { return .visitChildren }
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            return .skipChildren
        }
        reference = reference ?? Syntax(node)
        return .skipChildren
    }

    override func visit(_ node: SuperExprSyntax) -> SyntaxVisitorContinueKind {
        reference = reference ?? Syntax(node)
        return .skipChildren
    }

    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        if ["self", "`self`"].contains(node.name.text) { reference = reference ?? Syntax(node.name) }
        return .visitChildren
    }
}

// `Self` in a closure parameter is useful at the declaration site, but Swift's
// getter body sees concrete `self`. Resolve that parameter in generated code.
private final class OwnerParameterRewriter: SyntaxRewriter {
    let owner: TypeSyntax

    init(owner: TypeSyntax) {
        self.owner = owner
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClosureParameterSyntax) -> ClosureParameterSyntax {
        guard node.type?.as(IdentifierTypeSyntax.self)?.name.text == "Self" else { return node }
        var parameter = node
        parameter.type = owner.with(\.trailingTrivia, node.type?.trailingTrivia ?? [])
        return parameter
    }
}

/// Expands a source property into private storage and lazy source configuration.
public struct ViewDataSourceMacro: AccessorMacro, PeerMacro {
    private static func isViewData(_ type: TypeSyntax) -> Bool {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.text == "ViewData" && identifier.genericArgumentClause?.arguments.count == 1
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.baseType.trimmedDescription == "Ensemble" && member.name.text == "ViewData"
                && member.genericArgumentClause?.arguments.count == 1
        }
        return false
    }

    private static func property(
        _ declaration: some DeclSyntaxProtocol,
        context: some MacroExpansionContext
    ) throws -> (VariableDeclSyntax, String, String) {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindingSpecifier.tokenKind == .keyword(.var),
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let type = binding.typeAnnotation?.type,
              isViewData(type),
              binding.accessorBlock == nil,
              !variable.modifiers.contains(where: { ["static", "class", "lazy", "weak", "unowned"].contains($0.name.text) }),
              context.lexicalContext.first?.is(ClassDeclSyntax.self) == true
        else {
            throw DiagnosticsError(diagnostics: [Diagnostic(
                node: Syntax(declaration),
                message: SourceDiagnostic(message: "@ViewDataSource requires one stored instance var explicitly typed as ViewData<Value> in a class")
            )])
        }
        if let initializer = binding.initializer {
            throw DiagnosticsError(diagnostics: [Diagnostic(
                node: Syntax(initializer),
                message: SourceDiagnostic(message: "Supply a seed with @ViewDataSource(initial:), not a property initializer")
            )])
        }
        return (variable, name, type.trimmedDescription)
    }

    private static func arguments(
        _ node: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> [String: String] {
        guard case .argumentList(let arguments) = node.arguments else { return [:] }
        let model = context.lexicalContext.first!.cast(ClassDeclSyntax.self)
        let generics = model.genericParameterClause.map { clause in
            "<" + clause.parameters.map {
                ($0.specifier?.text == "each" ? "repeat each " : "") + $0.name.text
            }.joined(separator: ", ") + ">"
        } ?? ""
        let owner: TypeSyntax = "\(raw: model.name.text + generics)"
        let rewriter = OwnerParameterRewriter(owner: owner)
        return Dictionary(uniqueKeysWithValues: arguments.compactMap { argument in
            argument.label.map { label in
                if ["initial", "make", "refresh", "receive"].contains(label.text),
                   var closure = argument.expression.as(ClosureExprSyntax.self),
                   let signature = closure.signature {
                    closure.signature = rewriter.rewrite(signature).as(ClosureSignatureSyntax.self)
                    return (label.text, closure.trimmedDescription)
                }
                return (label.text, argument.expression.trimmedDescription)
            }
        })
    }

    private static func validateCallbacks(_ node: AttributeSyntax) throws {
        guard case .argumentList(let arguments) = node.arguments else { return }
        if let identity = arguments.first(where: { $0.label?.text == "id" }) {
            guard identity.expression.is(KeyPathExprSyntax.self) else {
                throw DiagnosticsError(diagnostics: [Diagnostic(
                    node: Syntax(identity.expression),
                    message: SourceDiagnostic(message: "@ViewDataSource id must be a key-path literal")
                )])
            }
            let visitor = InstanceCaptureVisitor(viewMode: .sourceAccurate)
            visitor.walk(identity.expression)
            if let reference = visitor.reference {
                throw DiagnosticsError(diagnostics: [Diagnostic(
                    node: reference,
                    message: SourceDiagnostic(message: "@ViewDataSource id must not capture instance self or super")
                )])
            }
        }
        for argument in arguments where ["initial", "make", "refresh", "receive"].contains(argument.label?.text) {
            if argument.label?.text != "make", argument.expression.is(NilLiteralExprSyntax.self) { continue }
            guard let closure = argument.expression.as(ClosureExprSyntax.self) else {
                throw DiagnosticsError(diagnostics: [Diagnostic(
                    node: Syntax(argument.expression),
                    message: SourceDiagnostic(message: "@ViewDataSource callbacks must be inline closures so their captures can be checked")
                )])
            }
            let visitor = InstanceCaptureVisitor(viewMode: .sourceAccurate)
            visitor.walk(closure)
            if let reference = visitor.reference {
                throw DiagnosticsError(diagnostics: [Diagnostic(
                    node: reference,
                    message: SourceDiagnostic(message: "@ViewDataSource callbacks must not capture instance self or super")
                )])
            }
        }
    }

    private static func isObservable(_ context: some MacroExpansionContext) -> Bool {
        context.lexicalContext.first?.as(ClassDeclSyntax.self)?.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.split(separator: ".").last == "Observable"
        } == true
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        // The peer role diagnoses invalid declarations once; do not duplicate that diagnostic.
        guard let (variable, name, type) = try? property(declaration, context: context) else { return [] }
        guard (try? validateCallbacks(node)) != nil else { return [] }
        if isObservable(context), !variable.attributes.contains(where: {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.split(separator: ".").last == "ObservationIgnored"
        }) {
            throw DiagnosticsError(diagnostics: [Diagnostic(
                node: Syntax(node),
                message: SourceDiagnostic(message: "Add @ObservationIgnored to @ViewDataSource properties in an @Observable class")
            )])
        }
        let args = arguments(node, context: context)
        guard let make = args["make"] else { return [] }
        let receive = args["receive"].flatMap { $0 == "nil" ? nil : $0 }
            ?? "{ _, result, sink in sink.receive(result) }"
        let data = context.makeUniqueName("data")
        let owner = context.lexicalContext.first!.cast(ClassDeclSyntax.self).name.text
        let declaration = StringLiteralExprSyntax(content: "\(owner).\(name)")
        let identity: String
        if let id = args["id"] {
            identity = "{ $0[keyPath: \(id)] }"
        } else {
            identity = "{ _ in false }"
        }
        return [
            """
            get {
                let \(data) = \(raw: type)._source(
                    _\(raw: name),
                    owner: self,
                    declaration: \(declaration),
                    id: \(raw: identity),
                    initial: \(raw: args["initial"] ?? "nil"),
                    make: \(raw: make),
                    refresh: \(raw: args["refresh"] ?? "nil"),
                    allowsReload: \(raw: args["allowsReload"] ?? "true"),
                    receive: \(raw: receive)
                )
                _\(raw: name) = \(data)
                return \(data).data
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (_, name, type) = try property(declaration, context: context)
        try validateCallbacks(node)
        return ["@ObservationIgnored private var _\(raw: name): \(raw: type)._Source?"]
    }
}

@main
struct EnsemblePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ViewDataSourceMacro.self]
}
