FROM golang:1.26.7 AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/auth-sim ./cmd/auth-sim
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/proxy-metrics-exporter ./cmd/proxy-metrics-exporter
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/l05-custom-metrics-adapter ./cmd/l05-custom-metrics-adapter

FROM scratch
COPY --from=builder /out/auth-sim /auth-sim
COPY --from=builder /out/proxy-metrics-exporter /proxy-metrics-exporter
COPY --from=builder /out/l05-custom-metrics-adapter /l05-custom-metrics-adapter
USER 65532:65532
EXPOSE 8080 9090 18081 8443
ENTRYPOINT ["/auth-sim"]
