FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod ./
# Add go.sum generation if needed, skipping for brevity but `go mod tidy` in build is safer
COPY main.go ./

RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o noise-generator main.go

FROM scratch
COPY --from=builder /app/noise-generator /noise-generator
# We need CA certificates for OTLP TLS? We disabled TLS in code (WithInsecure).
ENTRYPOINT ["/noise-generator"]
