# Running the container

How the image is built, what it promises to whoever runs it and how to tell when it is not keeping the promise. The
reasoning is in [ADR-008](../ADR/ADR-008-container-image-and-runtime.md).

## Build and run

```bash
make docker-build      # builds borba-scientific-engine:<git describe>; about eight minutes cold, seconds when only the last layers change
make up                # PostgreSQL, then the migrate job, then the API (Compose)
make smoke-container   # builds the image and verifies everything below against the running container
make down
```

The image is built from `Dockerfile` with three build arguments that become labels and the values reported by
`GET /version`: `APP_VERSION`, `APP_COMMIT` and `APP_BUILD_DATE`. `make` fills them from git and the clock.

To run the image without Compose, give it the same restrictions Compose does and a database:

```bash
docker run --rm --publish 127.0.0.1:8080:8080 \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --env-file production.env \
  borba-scientific-engine:<tag>
```

The environment file carries `DATABASE_URL` and the other settings of the [README](../../README.md#configuration). Credentials
are never baked into the image: pass them at run time, from the platform's secret store.

## What the container promises

| | |
|---|---|
| **User** | `10001:10001`, numeric, with no shell and no home directory |
| **Port** | `8080`, from `HTTP_PORT`; binds `0.0.0.0` unless `HTTP_HOST` says otherwise |
| **Filesystem** | Nothing is written. `/tmp` may be a `tmpfs`; the rest may be read-only |
| **State** | None. Replicas are interchangeable; every durable fact is in PostgreSQL |
| **Commands** | `serve` (default), `migrate [--yes]`, `healthcheck`, `routes` |
| **Signals** | `SIGTERM` or `SIGINT` starts the graceful shutdown (ADR-005); the exit status is `0` |
| **Exit status** | `0` after a clean shutdown; `1` when startup, the run or the shutdown failed |
| **Health** | `healthcheck` exits `0` only when `/health` answers `200` |

## Health: liveness for Docker, readiness for the platform

`borba-scientific-engine healthcheck` runs inside the container and asks `/health` of the instance configured by the
container's own environment. Docker runs it every 15 seconds (5 in the Compose stack), allows 5 seconds for an answer,
ignores failures during the first 10 seconds and calls the container unhealthy after 3 in a row.

```bash
docker inspect --format '{{json .State.Health}}' <container> | jq   # the last probes, with their output
docker exec <container> /app/borba-scientific-engine healthcheck    # ask by hand
```

Docker's single status means *alive*. A platform that distinguishes the two should probe the endpoints directly:

```yaml
# Kubernetes
livenessProbe:  { httpGet: { path: /health, port: 8080 }, periodSeconds: 15, failureThreshold: 3 }
readinessProbe: { httpGet: { path: /ready,  port: 8080 }, periodSeconds: 5 }
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities: { drop: ["ALL"] }
terminationGracePeriodSeconds: 30
```

`/ready` is what stops traffic when the database is unreachable or the instance is draining; it must not restart anything.

## Verifying a built image

`make smoke-container` starts the Compose stack from the image on free ports and checks, against the running container:

- the image runs as `10001:10001`, defines a health check, carries OCI labels and contains no setuid or setgid file;
- Docker reports the container healthy; it runs as uid 10001, cannot write to `/app`, can write to `/tmp`, holds no
  capabilities and cannot gain privileges;
- the `migrate` service is idempotent;
- `/health`, `/ready` and `/version` answer, and a calculation is recorded in PostgreSQL and read back;
- with PostgreSQL stopped, `/ready` answers 503, `/health` answers 200 and Docker still reports the container healthy; the
  database coming back makes `/ready` answer 200 again;
- `docker stop` ends the process with status 0.

It takes about thirty seconds, needs Docker with the Compose plugin, `curl`, `jq` and `python3`, and removes everything it
created.

## When something is wrong

| Symptom | Likely cause and what to do |
|---|---|
| `unhealthy: no answer: … Connection refused` | The process is not listening: still starting, or it crashed. `docker logs <container>` |
| `unhealthy: Invalid configuration` | The probe reads the same variables as the server, so the server could not start either. The message names the variable |
| `unhealthy: answered with status N` | The process is up but `/health` fails, which only a bug causes: it checks nothing external |
| `app` never starts under Compose | The `migrate` job failed. `docker compose logs migrate` |
| `Read-only file system` in the logs | Something writes outside `/tmp`. Fix the writer; do not make the filesystem writable |
| Exit status `137` after a stop | The shutdown outlasted the grace period. Keep `stop_grace_period` above `SHUTDOWN_TIMEOUT_SECONDS` |
| `OOMKilled` in `docker inspect` | The memory limit (`APP_MEMORY_LIMIT`, 512 MiB by default) is below what the workload needs |
