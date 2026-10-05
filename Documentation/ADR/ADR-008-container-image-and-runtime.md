# ADR-008 — Container image and runtime

- **Status:** Accepted
- **Date:** 2026-10-05

## Context

The service ships as one container image, and that image is the unit that every environment runs: a developer's Compose
stack, CI, staging and production. What it contains and how it is started decide how much damage a compromised process can
do, whether an orchestrator can tell a sick instance from a healthy one, and whether stopping it loses requests. The
decisions below are cheap to make now and expensive to retrofit after something depends on the defaults.

## Decisions

### One image, built in two stages

The build stage compiles with the Swift toolchain image. The runtime stage is `ubuntu` with only what the binary needs:
certificates (TLS to PostgreSQL and the error tracker), time zone data, the Swift runtime libraries the binary links
against and the crash backtracer. The result is about 320 MB; the toolchain, sources and build products stay behind.

Dependencies are resolved in their own layer with `--force-resolved-versions`, so a build fails instead of silently moving
to newer versions, and the layer stays cached until `Package.swift` or `Package.resolved` changes. A cold build takes about
eight minutes, almost all of it compiling dependencies.

### The process is unprivileged and can change nothing

| Property | How | Why |
|---|---|---|
| Not root | `USER 10001:10001`, created without a home or a shell | A **numeric** identity: Kubernetes' `runAsNonRoot` cannot verify a user given by name |
| Cannot rewrite itself | The application files belong to root and are only readable by the service user | A compromised process cannot replace its own binary |
| No writable filesystem | `read_only: true`, with a `tmpfs` at `/tmp` | The service is stateless; whatever tries to persist something is a bug or an attacker |
| No capabilities | `cap_drop: [ALL]` | It listens on an unprivileged port and needs nothing else |
| Cannot gain privileges | `no-new-privileges`, and every setuid and setgid bit removed from the image | Two independent mechanisms; either is enough, so a mistake in one is not fatal |
| Bounded memory | `mem_limit`, 512 MiB unless `APP_MEMORY_LIMIT` says otherwise | A runaway calculation must not starve the host |

The runtime properties live in Compose because Docker has no way to put them in an image; other orchestrators must state
the same (`securityContext` in Kubernetes). The container smoke test verifies each of them against the running container
rather than trusting the file.

### The health check asks the executable, and asks about liveness

The image has no `curl`: adding one means another binary, its libraries and its vulnerabilities for the sake of one
request. Instead `borba-scientific-engine healthcheck` requests the instance's own `/health` using the configuration the
instance itself runs with (host, port) and exits `0` only on `200 OK`. It boots no application, so it creates no log
lines, metrics or error reports; it gives up after three seconds, which includes a refused connection.

It checks **liveness, not readiness**. Docker has one health status, and what an orchestrator does with an unhealthy
container is restart it. Restarting the service because its database is down does not bring the database back; it only
adds a restart storm to an outage. Readiness (`/ready`) is for load balancers and Kubernetes' `readinessProbe`, which can
stop sending traffic without killing anything. An instance that is draining for shutdown is likewise still alive. The
container smoke test stops PostgreSQL and checks all of it: `/ready` answers 503, `/health` answers 200 and Docker keeps
the container `healthy`.

The consequence to know about: in Compose, `depends_on: condition: service_healthy` on this service means "alive", not
"ready for traffic".

### Migrations are a separate, one-shot service

The application never migrates on startup (ADR-004). In Compose the `migrate` service runs the same image with
`migrate --yes`, and `app` starts only after it completed successfully. With several replicas, migrating on startup would
race, and a failed migration would take every replica down instead of failing one job. The image's health check is disabled
for that service, which would otherwise report a job as unhealthy while it runs.

### Stopping is a protocol

`STOPSIGNAL SIGTERM` is explicit, and Compose waits 30 seconds, twice the default shutdown timeout of 15 s, before it kills
the process. The process starts the graceful shutdown of ADR-005 on the signal and exits with status `0`; the container
smoke test requires `0`, because `137` would mean Docker had to kill it. The service needs no init process: it spawns no
children, so there is nothing to reap, and it handles the signal itself as the container's first process.

### Labels

The image carries the OCI annotations that do not depend on where it was built (title, description, license, base image)
and, from build arguments, the version, revision and creation time. The pipeline's metadata step adds the repository and
overrides the rest, which is what links a published image to its source.

## Consequences

- **A dependency became direct.** `AsyncHTTPClient` (and `NIOCore` for its timeout type) are declared in the manifest. Both
  were already in the dependency graph through Vapor at the same versions; the lockfile did not change.
- **The health check is a process per probe**, started every fifteen seconds. It costs a few milliseconds and no
  steady-state memory.
- **Read-only is a contract.** A future dependency that writes to disk will fail in the container and not in development;
  the container smoke test is what finds it, and the answer is `/tmp`, not turning `read_only` off.
- **Base images are tags, not digests.** A rebuild picks up upstream fixes, and also upstream surprises. The pipeline scans
  every image it builds and the dependency updater proposes new base versions (ADR-009).

## Alternatives considered

- **Distroless or the toolchain's `-slim` image as the base.** There is no maintained distroless image for Swift, and
  statically linking the standard library is not usable with the default build system of Swift 6.4. The `-slim` image is
  larger than this one and carries more than the binary needs.
- **`curl` or `wget` for the health check.** Rejected for the reasons above. It would also duplicate in a shell command
  the host and port the executable already knows.
- **Checking `/ready` from Docker.** Rejected: it turns a database outage into restarts.
- **`init: true`.** Not needed; see above.
- **Pinning base images by digest.** Reproducible, and stale within weeks without automation. Revisit when the pipeline
  has an updater that opens the pull requests.
