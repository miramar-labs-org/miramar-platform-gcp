# Build: statically-linked, stripped Go binary (no cgo, no external modules).
FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /nsight-ape-webhook .

# Runtime: distroless static, non-root.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /nsight-ape-webhook /nsight-ape-webhook
USER 65532:65532
EXPOSE 8443
ENTRYPOINT ["/nsight-ape-webhook"]
