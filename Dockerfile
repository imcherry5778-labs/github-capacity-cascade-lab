FROM golang:1.26.7 AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/auth-sim ./cmd/auth-sim

FROM scratch
COPY --from=builder /out/auth-sim /auth-sim
USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/auth-sim"]
