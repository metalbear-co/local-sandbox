FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 go build -o elasticsearch-app .

FROM alpine:3.19
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/elasticsearch-app .
EXPOSE 8080
CMD ["./elasticsearch-app"]
