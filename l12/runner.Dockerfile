FROM golang:1.26.7 AS go-toolchain

FROM code.forgejo.org/forgejo/runner:13.1.0

USER root
COPY --from=go-toolchain /usr/local/go /usr/local/go
ENV GOTOOLCHAIN=local
ENV PATH=/usr/local/go/bin:${PATH}
USER 1000:1000
