#syntax=docker/dockerfile-upstream:1.4


# Base image for builds and cache
ARG RUSTUP_TOOLCHAIN
FROM docker.io/lukemathwalker/cargo-chef:latest-rust-${RUSTUP_TOOLCHAIN}-bookworm as cargo-chef
WORKDIR /build


# Stores source cache and cargo chef recipe
FROM cargo-chef as chef-planner
WORKDIR /src
COPY . .

# Select only the essential files for copying into next steps
# so that changes to miscellaneous files don't trigger a new cargo-chef cook.
# Beware that .dockerignore filters files before they get here.
RUN find . \( \
    -name "*.rs" -or \
    -name "*.toml" -or \
    -name "Cargo.lock" -or \
    -name "*.sql" -or \
    -name "README.md" -or \
    # Used for local TLS testing, as described in admin/README.md
    -name "*.pem" \
    \) -type f -exec install -D \{\} /build/\{\} \;
WORKDIR /build
# Remove patch.unused entries as they trigger unnecessary rebuilds (don't ask how long it took to write)
RUN N="$(grep -bPzo '(?s)\n\[\[patch.unused.*' Cargo.lock | grep -a : | cut -d: -f1)"; [ -z $N ] && exit 0; head -c $N Cargo.lock > Cargo.lock.nopatch && mv Cargo.lock.nopatch Cargo.lock
RUN cargo chef prepare --recipe-path /recipe.json


# Builds crate according to cargo chef recipe.
# This step is skipped if the recipe is unchanged from previous build (no dependencies changed).
FROM cargo-chef AS chef-builder
ARG CARGO_PROFILE
COPY --from=chef-planner /recipe.json /
# https://i.imgflip.com/2/74bvex.jpg
RUN cargo chef cook \
    $(if [ "$CARGO_PROFILE" = "release" ]; then echo --release; fi) \
    --recipe-path /recipe.json \
    --bin shuttle-auth \
    --bin shuttle-deployer \
    --bin shuttle-gateway \
    --bin shuttle-logger \
    --bin shuttle-provisioner \
    --bin shuttle-resource-recorder
COPY --from=chef-planner /build .
# Building all at once to share build artifacts in the "cook" layer
RUN cargo build \
    $(if [ "$CARGO_PROFILE" = "release" ]; then echo --release; fi) \
    --bin shuttle-auth \
    --bin shuttle-deployer \
    --bin shuttle-gateway \
    --bin shuttle-logger \
    --bin shuttle-provisioner \
    --bin shuttle-resource-recorder


####### Helper step

FROM docker.io/library/debian:bookworm-20230904-slim AS bookworm-20230904-slim-plus
RUN apt update && apt install -y curl ca-certificates; rm -rf /var/lib/apt/lists/*

####### Targets for each crate

#### AUTH
FROM bookworm-20230904-slim-plus AS shuttle-auth
ARG SHUTTLE_SERVICE_VERSION
ENV SHUTTLE_SERVICE_VERSION=${SHUTTLE_SERVICE_VERSION}
ARG CARGO_PROFILE
COPY --from=chef-builder /build/target/${CARGO_PROFILE}/shuttle-auth /usr/local/bin
ENTRYPOINT ["/usr/local/bin/shuttle-auth"]
FROM shuttle-auth AS shuttle-auth-dev


#### DEPLOYER
ARG RUSTUP_TOOLCHAIN
FROM docker.io/library/rust:${RUSTUP_TOOLCHAIN}-bookworm AS shuttle-deployer
ARG SHUTTLE_SERVICE_VERSION
ENV SHUTTLE_SERVICE_VERSION=${SHUTTLE_SERVICE_VERSION}
ARG CARGO_PROFILE
ARG prepare_args
# Fixes some dependencies compiled with incompatible versions of rustc
ARG RUSTUP_TOOLCHAIN
ENV RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN}
COPY gateway/ulid0.so /usr/lib/
COPY gateway/ulid0_aarch64.so /usr/lib/
ENV LD_LIBRARY_PATH=/usr/lib/
ARG TARGETPLATFORM
RUN for target_platform in "linux/arm64" "linux/arm64/v8"; do \
    if [ "$TARGETPLATFORM" = "$target_platform" ]; then \
      mv /usr/lib/ulid0_aarch64.so /usr/lib/ulid0.so; fi; done
# Used as env variable in prepare script
ARG SHUTTLE_ENV
# Easy way to check if you are running in Shuttle's container
ARG SHUTTLE=true
ENV SHUTTLE=${SHUTTLE}
COPY deployer/prepare.sh /prepare.sh
COPY scripts/apply-patches.sh /scripts/apply-patches.sh
COPY scripts/patches.toml /scripts/patches.toml
RUN /prepare.sh "${prepare_args}"
COPY --from=chef-builder /build/target/${CARGO_PROFILE}/shuttle-deployer /usr/local/bin
ENTRYPOINT ["/usr/local/bin/shuttle-deployer"]
FROM shuttle-deployer AS shuttle-deployer-dev
# Source code needed for compiling local deploys with [patch.crates-io]
COPY --from=chef-planner /build /usr/src/shuttle/


#### GATEWAY
FROM bookworm-20230904-slim-plus AS shuttle-gateway
ARG SHUTTLE_SERVICE_VERSION
ENV SHUTTLE_SERVICE_VERSION=${SHUTTLE_SERVICE_VERSION}
ARG CARGO_PROFILE
COPY gateway/ulid0.so /usr/lib/
COPY gateway/ulid0_aarch64.so /usr/lib/
ENV LD_LIBRARY_PATH=/usr/lib/
ARG TARGETPLATFORM
RUN for target_platform in "linux/arm64" "linux/arm64/v8"; do \
    if [ "$TARGETPLATFORM" = "$target_platform" ]; then \
      mv /usr/lib/ulid0_aarch64.so /usr/lib/ulid0.so; fi; done
COPY --from=chef-builder /build/target/${CARGO_PROFILE}/shuttle-gateway /usr/local/bin
ENTRYPOINT ["/usr/local/bin/shuttle-gateway"]
FROM shuttle-gateway AS shuttle-gateway-dev
# For testing certificates locally
COPY --from=chef-planner /build/*.pem /usr/src/shuttle/


#### LOGGER
FROM docker.io/library/debian:bookworm-20230904-slim AS shuttle-logger
ARG SHUTTLE_SERVICE_VERSION
ENV SHUTTLE_SERVICE_VERSION=${SHUTTLE_SERVICE_VERSION}
ARG CARGO_PROFILE
COPY --from=chef-builder /build/target/${CARGO_PROFILE}/shuttle-logger /usr/local/bin
ENTRYPOINT ["/usr/local/bin/shuttle-logger"]
FROM shuttle-logger AS shuttle-logger-dev


#### PROVISIONER
ARG RUSTUP_TOOLCHAIN
FROM bookworm-20230904-slim-plus AS shuttle-provisioner
ARG SHUTTLE_SERVICE_VERSION
ENV SHUTTLE_SERVICE_VERSION=${SHUTTLE_SERVICE_VERSION}
RUN apt update && apt install -y postgresql-client-15; rm -rf /var/lib/apt/lists/*
ARG CARGO_PROFILE
COPY --from=chef-builder /build/target/${CARGO_PROFILE}/shuttle-provisioner /usr/local/bin
ENTRYPOINT ["/usr/local/bin/shuttle-provisioner"]
FROM shuttle-provisioner AS shuttle-provisioner-dev


#### RESOURCE RECORDER
FROM docker.io/library/debian:bookworm-20230904-slim AS shuttle-resource-recorder
ARG SHUTTLE_SERVICE_VERSION
ENV SHUTTLE_SERVICE_VERSION=${SHUTTLE_SERVICE_VERSION}
ARG CARGO_PROFILE
COPY --from=chef-builder /build/target/${CARGO_PROFILE}/shuttle-resource-recorder /usr/local/bin
ENTRYPOINT ["/usr/local/bin/shuttle-resource-recorder"]
FROM shuttle-resource-recorder AS shuttle-resource-recorder-dev
