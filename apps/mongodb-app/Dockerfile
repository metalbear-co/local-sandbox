FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 go build -o mongodb-app .

FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/mongodb-app .
CMD ["./mongodb-app"]
