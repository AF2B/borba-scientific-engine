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

ARG APP_VERSION=0.0.0-dev
ARG APP_COMMIT=unknown
ARG APP_BUILD_DATE=

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --skel /dev/null --home-dir /app --shell /usr/sbin/nologin engine

WORKDIR /app
COPY --from=build --chown=engine:engine /staging/ /app/

# Build metadata is read by the engine at startup. Credentials are never baked into the image.
ENV APP_ENV=production \
    APP_VERSION=${APP_VERSION} \
    APP_COMMIT=${APP_COMMIT} \
    APP_BUILD_DATE=${APP_BUILD_DATE} \
    HTTP_HOST=0.0.0.0 \
    HTTP_PORT=8080 \
    LD_LIBRARY_PATH=/app/lib \
    SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=/app/swift-backtrace

USER engine
EXPOSE 8080

ENTRYPOINT ["/app/borba-scientific-engine"]
CMD ["serve"]
