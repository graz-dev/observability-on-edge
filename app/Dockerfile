FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum* ./
RUN go mod download

# Copy source code
COPY *.go ./

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -o edge-demo-app .

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /root/

# Create log directory
RUN mkdir -p /var/log/app

# Copy binary from builder
COPY --from=builder /app/edge-demo-app .

EXPOSE 8080

CMD ["./edge-demo-app"]
