# ADR-001 — Application Architecture

- **Status:** Accepted
- **Date:** 2026-10-03

## Context

The engine is a modular calculation platform exposed over HTTP. Three forces shape its structure:

1. **Business logic must be testable without a web framework or a database.** Calculation rules are the product;
   Vapor and PostgreSQL are delivery mechanisms.
2. **Framework concerns must not leak inward.** Vapor request types, Fluent models and Sentry payloads are volatile
   (Vapor 5 is already in beta); the domain must survive their replacement.
3. **A folder convention is not an architecture.** A rule such as "the domain never imports Vapor" is only real when
   the compiler or a test enforces it.

## Decision

Requests flow inward through explicit layers, and dependencies point only inward:

```text
HTTP            routes, middleware, DTOs                       ─┐
  ↓                                                             │  BorbaScientificEngine (Vapor)
Handlers        translate DTOs ⇄ use-case commands            ─┘
  ↓
Business        calculation modules, use cases, domain errors      BorbaScientificCore (pure Swift)
  ↓
Ports           repository, clock, event publisher, reporter      BorbaScientificCore
  ↓
Adapters        Fluent repositories, in-process event bus,         BorbaScientificPersistence
                Sentry client, JSON logger                         BorbaScientificEngine/Adapters
  ↓
Infrastructure  PostgreSQL, Sentry, stdout
```

The layers are realised as SwiftPM targets so the dependency rule is enforced by the build graph:

| Target                       | Responsibility                                                    | May depend on                       |
| ---------------------------- | ----------------------------------------------------------------- | ----------------------------------- |
| `BorbaScientificCore`        | Domain model, calculation modules, use cases, ports, domain errors | Swift standard library, Foundation  |
| `BorbaScientificPersistence` | Fluent/PostgreSQL adapters for the repository ports, migrations    | Core, FluentKit, PostgreSQL driver  |
| `BorbaScientificEngine`      | Vapor HTTP layer, observability adapters, configuration, wiring    | Core, Persistence, Vapor            |
| `Run`                        | Executable entry point                                             | Engine                              |

Supporting rules:

- **Imports are explicit.** Every target enables `InternalImportsByDefault`, so a framework type can only appear in a
  public API through a visible `public import`.
- **Architecture is tested.** A fitness test scans `Core` and `Persistence` sources and fails if they import Vapor,
  NIO or other forbidden modules.
- **Dependencies are injected.** There is no service locator and no global mutable state. The composition root
  (`ApplicationFactory`) builds every collaborator — repositories, clock, identifier generator, event publisher,
  error reporter — and hands it to the objects that need it through initializers.
- **Events leave the request path.** Use cases publish immutable event values through a port; subscribers run
  outside the request (see ADR-005).

Mapping of the terms used in the project brief to this structure:

| Brief                       | Here                                                         |
| --------------------------- | ------------------------------------------------------------ |
| `Handlers/HTTP`             | `BorbaScientificEngine/HTTP`                                  |
| `Handlers/Business/<Area>`  | `BorbaScientificCore/Modules/<Area>` plus `…/Application`     |
| `Repository`                | Ports in `BorbaScientificCore/Ports`, adapters in Persistence |
| `Adapters`, `Events`        | `BorbaScientificEngine/Adapters`, `BorbaScientificCore/Events` |
| `Configuration`, `Utils`    | `BorbaScientificEngine/Configuration`; no generic `Utils`     |

## Consequences

- Domain tests compile and run without Vapor, which keeps the unit suite fast.
- Cross-target types must be `public` and documented, which adds surface to maintain but makes the boundary visible.
- Replacing Vapor 4 with Vapor 5, or Fluent with another store, touches one target.
- The manifest is longer than a single-target package; this is the price of an enforceable boundary.

## Alternatives considered

- **One target with folders per layer.** Cheapest, but nothing stops an accidental `import Vapor` in domain code.
- **Textbook Clean Architecture** (interactors, presenters, boundaries for every call). Too much ceremony for a
  domain this size; ports exist only where a second implementation or a test double has real value.
- **A Fluent model as the domain model.** Couples business rules to the ORM and to PostgreSQL column types.
