# syntax=docker/dockerfile:1
# Hivefin production image: multi-stage mix release + ffmpeg runtime.

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20250113-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Hex/Rebar via GitHub avoids TLS key_usage issues against builds.hex.pm
# on some OTP/Debian CA combinations in Docker Desktop.
RUN mix archive.install github hexpm/hex branch latest --force \
  && git clone --depth 1 https://github.com/erlang/rebar3.git /tmp/rebar3 \
  && cd /tmp/rebar3 && ./bootstrap \
  && mkdir -p /root/.mix \
  && cp /tmp/rebar3/rebar3 /root/.mix/rebar3 \
  && chmod +x /root/.mix/rebar3 \
  && rm -rf /tmp/rebar3

# Point Mix at the local rebar3 so deps.get does not call builds.hex.pm
ENV MIX_REBAR3=/root/.mix/rebar3
ENV MIX_ENV=prod

# Dependencies (layer-cached unless mix files change)
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod \
  && mix deps.compile

# App source + assets
COPY config/runtime.exs config/
COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Pre-fetch Tailwind/esbuild with curl — OTP :httpc hits TLS key_usage errors
# against GitHub release assets on some Docker Desktop/CA setups.
ARG TARGETARCH
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) TW=x64; ES=x64 ;; \
    arm64) TW=arm64; ES=arm64 ;; \
    *) echo "unsupported arch: ${TARGETARCH}"; exit 1 ;; \
  esac; \
  mkdir -p /app/_build; \
  curl -fsSL -o "/app/_build/tailwind-linux-${TW}-4.3.0" \
    "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-linux-${TW}"; \
  chmod +x "/app/_build/tailwind-linux-${TW}-4.3.0"; \
  curl -fsSL -o /tmp/esbuild.tgz \
    "https://registry.npmjs.org/@esbuild/linux-${ES}/-/linux-${ES}-0.25.4.tgz"; \
  tar -xzf /tmp/esbuild.tgz -C /tmp; \
  cp "/tmp/package/bin/esbuild" "/app/_build/esbuild-linux-${ES}-0.25.4"; \
  chmod +x "/app/_build/esbuild-linux-${ES}-0.25.4"; \
  rm -rf /tmp/esbuild.tgz /tmp/package

# Compile, digest static assets, assemble release (overlays include docker-entrypoint)
RUN mix compile \
  && mix assets.deploy \
  && mix release hivefin

# ---- Runtime ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    ca-certificates \
    curl \
    ffmpeg \
    tini \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV PORT=4000
ENV HIVEFIN_HTTP_IP=0.0.0.0
ENV HIVEFIN_IMAGE_CACHE_DIR=/data/image-cache
ENV HIVEFIN_TRANSCODE_DIR=/data/transcode

WORKDIR /app

RUN useradd --create-home --shell /bin/bash --uid 1000 hivefin \
  && mkdir -p /data/image-cache /data/transcode \
  && chown -R hivefin:hivefin /data

COPY --from=builder --chown=hivefin:hivefin /app/_build/prod/rel/hivefin ./

RUN chmod +x /app/bin/docker-entrypoint /app/bin/hivefin

USER hivefin

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/readyz" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/docker-entrypoint"]
CMD ["start"]
