# ADR-009 — CI/CD

- **Status:** Accepted
- **Date:** 2026-10-05

## Context

A pipeline is where "it works on my machine" becomes "it works". It has to give fast feedback, be strict where strictness
buys something, run with the least privilege it can, and — the part most often missed — behave the way the commands a
developer runs behave, so that a red build can be reproduced and fixed without pushing to see. It also holds the keys: a
pipeline that can publish an image and deploy it is the most valuable target in the repository.

## Decisions

### Four pipelines, each answering one question

| Pipeline | Runs on | Answers | Gate |
|---|---|---|---|
| **Test** | Pull requests, pushes to the default branch, weekly, on demand | May this change be merged? | `Test / Quality gate` |
| **Build** | Pull requests, pushes to the default branch and to `v*.*.*` tags, on demand | Does it resolve to what is locked, compile, and does the release build behave? | `Build / Build gate` |
| **Registry** | Pushes to the default branch and to `v*.*.*` tags, pull requests that can change the image, on demand | Is the image correct and safe, and is it published? | Not a merge gate: it is path-filtered |
| **Deploy** | On demand only | May this version go to this environment, and did it get there? | The environment's own rules |

They differ in trigger, in what they may touch (only Registry writes packages, only Deploy sees an environment's secrets)
and in who should be able to run them, which is why they are separate files and not jobs of one. Each of Test and Build
ends in one job that requires all the others, so branch protection names two checks and survives the jobs changing.

### Pipelines contain no logic

Every check is a `make` target or a script that behaves the same on a laptop: `make lint`, `make audit`,
`make secret-scan`, `Scripts/coverage.sh`, `Scripts/smoke-container.sh`, `Scripts/deploy.sh`. The workflow files wire
things together — triggers, services, caches, permissions — and that is all. This is what makes a red pipeline
reproducible, and what lets the logic that matters most be tested: YAML cannot be tested without running it, a script can
(`make test-deploy` rehearses the deployment tooling, including its rollbacks). The scanners and linters run from container
images pinned in one place, the Makefile, so everyone and every pipeline use the same version.

### Quality gates

| Gate | Check | Fails when |
|---|---|---|
| Build | Package resolution, debug compile, release build and validation | The lockfile is not committed or complete; any compiler warning or error (warnings are errors); the release executable misses a library, does not start, does not migrate or does not shut down gracefully |
| Formatting | `swift format lint --strict` | Any difference |
| Lint | SwiftLint strict, ShellCheck, actionlint | Any finding |
| Tests | Unit, contract and integration suites against PostgreSQL | Any failure |
| Security | OSV (locked dependencies), gitleaks (whole history), Trivy (Dockerfile) | A known vulnerability, a committed secret, a HIGH or CRITICAL misconfiguration |
| Coverage | A floor per source target: Core 95 %, Persistence 90 %, Engine 90 % | Any target below its floor |
| Image | Container smoke test, deployment rehearsal, Trivy on the image | A hardening property is missing, a rollback does not work, a HIGH or CRITICAL vulnerability has a fix |

**Coverage is a floor per target, not a goal.** The three targets measured 96.5 %, 94.0 % and 93.0 % when the floors were
set a few points below, so a regression fails and noise does not. They differ because they differ: the pure domain is
covered almost completely, while the composition root and the process entry point are exercised by the smoke tests and
cannot be by unit tests.

**Slow tests are reported, not gated.** The job summary ranks tests and suites by time. A time limit on a shared runner
measures the runner; the unit suite finishes in a fraction of a second, so a test that starts to wait is visible in the
ranking long before it matters. Benchmarks run weekly and on demand, with budgets loosened for shared runners (ADR-007).

### The toolchain of the image, and a real database

Jobs run in `swift:6.4-noble`, the image the Dockerfile builds with, so the compiler that is tested is the one that
ships. PostgreSQL 18 runs as a service with its **default** connection limit, on purpose: the suites must not need more, and
they do not (verified against a default server).

### Supply chain

- **Actions are pinned by commit**, with the version in a comment, and Dependabot proposes updates weekly. A tag can be
  moved; a commit cannot.
- **Permissions are read-only by default** and widened per job only where used: packages and attestations in Registry's
  publication, packages read in Deploy's resolution.
- Checkouts do not persist credentials. Nothing runs on `pull_request_target`. Values from the event, which an attacker can
  choose (a branch name, an input), reach scripts only through the environment, never interpolated into them.
- **Published images carry provenance**, attested by GitHub for the exact digest, and an SBOM. Deploy refuses an image
  whose attestation does not name this repository's Registry workflow.
- **Static analysis of the Swift code** is the compiler (every warning is an error, existentials are explicit, imports are
  scoped), SwiftLint in strict mode and the test suites. CodeQL is not used; revisit it when it can analyze a SwiftPM build
  on Linux runners.

### Images and tags

| Tag | Moves? | For |
|---|---|---|
| `latest` | With the default branch | Looking at it; **never deploy it** |
| `main` | With the branch | The same |
| `v1.2.3` | Never, and the pipeline refuses to overwrite it | Releases |
| `v1.2` | With each patch of the line | Following a release line |
| `sha-1a2b3c4` | Never | A specific commit |

The registry cannot make a tag immutable, so the pipeline does: a release tag that is already published fails the build.
**Deployments use the digest**, resolved from the tag at deployment time. Pull requests build and verify the image but
never publish it.

The image is built for verification first and then published through the same cache, so every layer that was verified is
the one that is published. The build date is the commit's own time and the image configuration's timestamp is pinned to it,
so building one commit twice gives the same labels and the same configuration. Only `linux/amd64` is built: a Swift build
under emulation is too slow to be worth it, and `arm64` should come from a native runner when it is needed.

### Deployment

Deploy is **manual**, defaults to a **dry run**, and runs only from the default branch. It resolves a release or commit to a
digest, verifies the attestation, and hands the digest to a **provider** inside a GitHub environment, where approvals,
allowed branches and secrets live. A provider is a script with two commands, `current` and `apply`; the plan, the
verification from the outside and the rollback are written once, in `Scripts/deploy.sh`, because they are what makes a
deployment safe and must not depend on how a platform is driven. A rollback is a deployment of the previous reference.

**Migrations are forward-only and must keep the previous release working**, because that is what a rollback puts back. This
is a rule for writing migrations, not something the pipeline can check; it is stated here and in the deployment guide.

No platform is configured, so Deploy refuses to deploy and a dry run reports its plan. One provider ships, for a Docker
host running the Compose stack, because it can be exercised for real; every other platform starts from a template.

Deploy is not triggered by a merge. Continuous deployment needs a platform, a verification that suits it and an approval
policy, none of which this repository can know. Once a provider is configured, deploying staging after a Registry success
is one `workflow_run` trigger.

## Consequences

- **The workflows have not run on GitHub.** The repository had no remote when they were written. They were checked with
  actionlint and the published JSON schemas, and every command they run was executed locally, but expect small fixes on
  the first real run (cache keys, a permission, an input name).
- **Two pipelines compile the project.** Test and Build each need a build tree; caches keyed by the lockfile make that
  cheap after the first run. The Docker build in Registry is the slow one (about eight minutes cold).
- **Tool versions in the Makefile are updated by hand.** Dependabot covers actions, the Dockerfile and the Compose file,
  not those pins.
- **`amd64` only.**
- **Registry and Deploy depend on settings that are not code** (protected tags and environments, required reviewers,
  required checks). The deployment guide lists them; a repository without them is less safe than its pipelines suggest.

## Alternatives considered

- **One workflow with all the jobs.** One trigger, one set of permissions: a pull request would run with what a publication
  needs. Rejected.
- **Trivy's and the other scanners' official actions.** More convenient, and one more third-party action holding the
  token. The Make targets give the same checks locally and need no action.
- **Build once, verify, push the same image** (a retag and a push, not a second build). Exact, but it gives up the registry
  cache's attestations and the multi-tag push, and it is more to get wrong in a pipeline that cannot be run in advance. The
  cached second build was chosen; the layers are the verified ones.
- **Deploying every merge to the default branch.** See above.
- **Kubernetes manifests or a Helm chart in the repository.** There is no target platform to write them for, and an
  untested chart is worse than none.
