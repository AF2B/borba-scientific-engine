# syntax=docker/dockerfile:1.7

ARG SWIFT_VERSION=6.4
ARG UBUNTU_CODENAME=noble

# --- Build stage ---------------------------------------------------------------------------------------
FROM swift:${SWIFT_VERSION}-${UBUNTU_CODENAME} AS build

WORKDIR /build

# Dependencies are resolved in their own layer, which stays cached until the manifest or lockfile changes.
# `--force-resolved-versions` makes the build fail instead of silently moving to newer dependencies.
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions

# SwiftPM validates every declared target, tests included, so the test tree is copied as well.
COPY Sources ./Sources
COPY Tests ./Tests

RUN swift build \
        --configuration release \
        --product borba-scientific-engine \
        --force-resolved-versions

# Assemble everything the runtime needs under /staging: the binary without debug info, the Swift runtime
# libraries it links against (the static standard library link is not usable with the default build system of
# Swift 6.4) and the crash backtracer.
RUN BINARY="$(swift build --configuration release --show-bin-path)/borba-scientific-engine" \
    && install -D "${BINARY}" /staging/borba-scientific-engine \
    && strip --strip-debug /staging/borba-scientific-engine \
    && mkdir -p /staging/lib \
    && ldd "${BINARY}" \
        | awk '/\/usr\/lib\/swift\/linux\// { print $3 }' \
        | xargs --no-run-if-empty cp --target-directory=/staging/lib \
    && install -D /usr/libexec/swift/linux/swift-backtrace-static /staging/swift-backtrace

# --- Runtime stage -------------------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_CODENAME} AS runtime

ARG UBUNTU_CODENAME
ARG APP_VERSION=0.0.0-dev
ARG APP_COMMIT=unknown
ARG APP_BUILD_DATE=

# A numeric identity, so that an orchestrator can verify that the container does not run as root: Kubernetes'
# `runAsNonRoot` cannot check a user that is given by name.
ARG APP_UID=10001
ARG APP_GID=10001

# Only what the engine needs at runtime: certificates (TLS to PostgreSQL and to the error tracker) and time zone data.
# Setuid and setgid bits are removed from everything, so that nothing in the image can raise privileges, whatever flags
# the container is started with.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid "${APP_GID}" engine \
    && useradd --system --uid "${APP_UID}" --gid engine --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin engine \
    && find / -xdev -perm /6000 -type f -exec chmod a-s {} +

# The application belongs to root and is only readable by the engine user: a compromised process cannot rewrite its own
# binary, and it needs no writable directory.
WORKDIR /app
COPY --from=build /staging/ /app/

# Dynamic values come from build arguments; the pipeline's metadata step overrides or extends them with the repository.
LABEL org.opencontainers.image.title="borba-scientific-engine" \
      org.opencontainers.image.description="Scientific calculation engine API: Swift, Vapor and PostgreSQL" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:${UBUNTU_CODENAME}" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${APP_COMMIT}" \
      org.opencontainers.image.created="${APP_BUILD_DATE}"

# Build metadata is read by the engine at startup. Credentials are never baked into the image.
ENV APP_ENV=production \
    APP_VERSION=${APP_VERSION} \
    APP_COMMIT=${APP_COMMIT} \
    APP_BUILD_DATE=${APP_BUILD_DATE} \
    HTTP_HOST=0.0.0.0 \
    HTTP_PORT=8080 \
    LD_LIBRARY_PATH=/app/lib \
    SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=/app/swift-backtrace

USER ${APP_UID}:${APP_GID}
EXPOSE 8080

# Liveness only, and answered by the executable itself because the image has no curl (see ADR-008). The probe gives up
# after 3 s, so 5 s covers a process that is slow to start; failures during the first 10 s are not counted.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/app/borba-scientific-engine", "healthcheck"]

# SIGTERM starts the graceful shutdown: readiness flips, accepted requests finish, then the database pool closes.
STOPSIGNAL SIGTERM

ENTRYPOINT ["/app/borba-scientific-engine"]
CMD ["serve"]
