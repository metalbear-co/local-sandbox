FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 go build -o /env-patch-probe .

FROM gcr.io/distroless/static
COPY --from=build /env-patch-probe /env-patch-probe
ENTRYPOINT ["/env-patch-probe"]
