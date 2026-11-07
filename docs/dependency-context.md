# Keep dependencies in the intended context

Ensemble holds source callbacks for later use. It supplies the owner without retaining it between
calls, but does not capture or restore the dependency environment in which the model was created.
Main-actor isolation serializes access; it does not select task-local dependency values.

## Know when callbacks run

| Callback | Execution context |
| --- | --- |
| `initial` | Synchronously in the first property reader's context, even if the source stays dormant |
| `id` | When identity is evaluated for startup, a notification, or a subsequent result/reload check |
| `make` | The connection's startup or rebind context; a reload can start a connection directly |
| `receive` | The sequence-consumption task created for that connection |
| `refresh` | The task invoking reload; retry creates a task from the retry invocation |

Tasks inherit the task-local values present when they are created. Storing a closure does not pin
ambient task locals to the time it was declared or to the owner's initialization. Consequently,
creating a model in context A, first reading it in B, connecting in C, and reloading in D can run
`initial` in B, `make`/`receive` in C, and `refresh` in D.

An identity notification normally schedules rebinding from the mutator's context. A subsequent
callback or reload can check the identity sooner. Keep the projection pure and based on owner-held
observable inputs; do not use an ambient dependency environment as connection identity.

## Prefer collaborators already held by the owner

Use the owner parameter to access repositories, clients, and use cases that were injected or
constructed in the intended environment. Their own dependency-capture rules continue to apply.
The factory can then use the selected collaborator without consulting ambient dependency state.

If collaborators must be rebuilt, construct the replacement first and publish the complete model
update synchronously on the main actor. Do not suspend, reload, or invoke reentrant work between
assigning collaborators and their connection identity. Both assignment orders settle before a
scheduled rebind when the update is uninterrupted; keeping related state together makes that
invariant easier to maintain.

## Restore framework-specific context when constructing collaborators

For Point-Free's Dependencies library, restore the owner's dependencies when creating a child
collaborator that needs them:

```swift
import Dependencies

func apply(_ inputs: SectionInputs) {
  let replacement = withDependencies(from: self) {
    SectionUseCases(inputs: inputs)
  }
  sectionUseCases = replacement
  sectionInputs = inputs
}
```

Here `SectionInputs` and `SectionUseCases` are application types. The model must have dependencies
associated with it under that framework's rules, such as a stored `@Dependency` property or creation
through `withDependencies`. See its [dependency propagation implementation and API documentation](https://github.com/pointfreeco/swift-dependencies/blob/main/Sources/Dependencies/WithDependencies.swift).

Wrapping construction does not make an arbitrary returned sequence retain ambient dependencies.
The collaborator must capture what its later work needs, or explicitly propagate context into that
work. Ensemble does not depend on a particular dependency framework or provide a second environment.

## Set up tests before the relevant boundary

Install overrides before model construction when dependency-backed stored properties capture there.
Also account for seed dependencies evaluated on first read and new collaborators constructed later
by callbacks. Merely wrapping the model initializer does not restore that scope around every future
callback. Seed and source overrides may therefore need different setup boundaries.

Reload intentionally preserves the caller's task locals, including through `Ensemble.reload(...)`.
Use explicit owner-bound collaborators or your dependency framework's propagation helper when the
model's dependencies must take precedence over the request caller's environment.

Next: [Testing](testing.md) · [Sources and lifecycle](sources-and-lifecycle.md)
