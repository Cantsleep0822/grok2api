ARG NODE_VERSION=22
ARG GO_VERSION=1.26
ARG ALPINE_VERSION=3.23

FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS frontend-builder

WORKDIR /src/frontend
RUN corepack enable

COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN --mount=type=cache,id=grok2api-pnpm,target=/pnpm/store \
    pnpm config set store-dir /pnpm/store && \
    pnpm fetch --frozen-lockfile

RUN --mount=type=cache,id=grok2api-pnpm,target=/pnpm/store \
    pnpm config set store-dir /pnpm/store && \
    pnpm install --offline --frozen-lockfile

COPY frontend/index.html frontend/vite.config.ts frontend/tsconfig.json frontend/tsconfig.app.json frontend/tsconfig.node.json ./
COPY frontend/public ./public
COPY frontend/src ./src
RUN --mount=type=cache,id=grok2api-tsc,target=/src/frontend/.cache,sharing=locked \
    pnpm build


FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS backend-builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src/backend
RUN apk add --no-cache ca-certificates git

COPY backend/go.mod backend/go.sum ./
RUN --mount=type=cache,id=grok2api-go-mod,target=/go/pkg/mod,sharing=locked \
    go mod download

COPY backend/cmd ./cmd
COPY backend/internal ./internal
COPY backend/docs/docs.go ./docs/docs.go
RUN --mount=type=cache,id=grok2api-go-mod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=grok2api-go-build,target=/root/.cache/go-build,sharing=locked \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -buildvcs=false -trimpath -ldflags="-s -w" -o /out/grok2api ./cmd/grok2api


FROM alpine:${ALPINE_VERSION}

ARG TARGETARCH=amd64
ARG CLOUDFLARED_VERSION=2026.10.0

ENV TZ=Asia/Shanghai \
    GROK2API_CONFIG_SOURCE=/run/grok2api/config.yaml \
    PORT=8000

RUN apk add --no-cache ca-certificates su-exec tzdata tini wget && \
    addgroup -S -g 10001 grok2api && \
    adduser -S -D -H -u 10001 -G grok2api grok2api && \
    mkdir -p /app/data /run/grok2api /var/lib/grok2api-quality-guard && \
    chown -R grok2api:grok2api \
      /app/data \
      /run/grok2api \
      /var/lib/grok2api-quality-guard && \
    chmod 0700 /var/lib/grok2api-quality-guard

# cloudflared is optional at runtime: it starts only when TUNNEL_TOKEN is set.
RUN set -eux; \
    arch="${TARGETARCH}"; \
    case "${arch}" in \
      amd64|x86_64) arch=amd64; sha256=d33ff2d14475178d2012c2c56beba87389ac5ded27649519f198a7d3134a99db ;; \
      arm64|aarch64) arch=arm64; sha256=e6422b9d4f72d3194bc5a38676f13667c06666523217b842a877d72a80b5ac08 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -qO /tmp/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${arch}"; \
    echo "${sha256}  /tmp/cloudflared" | sha256sum -c -; \
    mv /tmp/cloudflared /usr/local/bin/cloudflared; \
    chmod 0755 /usr/local/bin/cloudflared

WORKDIR /app

COPY --from=backend-builder --chmod=0755 /out/grok2api /app/grok2api
COPY --from=frontend-builder /src/frontend/dist /app/frontend/dist
COPY VERSION /app/VERSION
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/grok2api-entrypoint

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/bin/sh", "-c", "wget -qO- http://127.0.0.1:${PORT:-8000}/healthz >/dev/null"]

ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/grok2api-entrypoint"]
CMD ["/app/grok2api", "--config", "/app/config.yaml"]
