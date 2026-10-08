FROM golang:1.24-alpine AS build
WORKDIR /src
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /klk-server ./cmd/klk-server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /klk-server /klk-server
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/klk-server"]
