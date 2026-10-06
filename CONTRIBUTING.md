# Contributing

## Set up

```bash
git clone https://github.com/AF2B/borba-scientific-engine.git && cd borba-scientific-engine
make setup      # checks the toolchain, creates .env, resolves packages
make up         # PostgreSQL, the migrations and the API, in containers
make ci         # everything the pipelines enforce, before you push
```

`make help` lists every target. The [README](README.md#developer-workflow) explains the common ones.

## Branches and commits

- **Branches** are `<type>/<short-description>`: `feat/`, `fix/`, `refactor/`, `perf/`, `test/`, `docs/`, `build/`, `ci/` or
  `chore/`, for example `fix/forged-cursor-crash`. One branch carries one intent.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/): a type, an optional scope, and an imperative
  title in lowercase without a final period, then a body of bullets that say what changed in the system and what that
  does. They are written in English, and they describe the code, never the process that produced it: no ticket numbers, no
  names, no "as discussed".
- **Commit what is finished**, in pieces that each build and pass: a fix with its test, a refactor on its own.

## What a change needs

- **Tests.** Behaviour has tests; a bug fix has a test that failed before the fix. Domain rules are written test-first.
  Persistence is tested against a real PostgreSQL, never a mock.
- **Types for failure.** Expected failures are typed values with stable codes, not strings and not `throws` from deep inside
  the domain. The error catalog and the OpenAPI document change together with the behaviour they describe.
- **Named constants** instead of unexplained numbers and strings; calls with three or more arguments, one per line.
- **Documentation** on every public declaration, parameter by parameter (`swift format` enforces it), and on anything whose
  reason is not obvious from the code. Comments say why.
- **No dead code**, no commented-out code, no `TODO` left behind.
- **A decision record** (`Documentation/ADR/`) when a change alters the architecture, a contract between components or the
  dependencies. A new dependency needs a reason, in the pull request at least.

## Where things are

[`CONTEXT.md`](CONTEXT.md) is the quickest orientation: the bounded contexts, the layers, the path of a request and the
decisions that are not obvious from the code. The [architecture overview](Documentation/Architecture/README.md) says what
is where.
[Adding a calculation module](Documentation/Development/adding-a-calculation-module.md) walks through the most common
extension, and the [testing guide](Documentation/Development/testing.md) explains the layers of tests and how to run each.

## Security

Report vulnerabilities privately, as [`SECURITY.md`](SECURITY.md) describes. Input is hostile: the hostile-input tests send
every operation and the API what a client that means harm would, and a new operation or endpoint joins them without extra
work, as long as it declares its parameters and has an example.
