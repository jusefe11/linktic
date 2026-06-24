# Multi-stage build: compile static Go binary, run on distroless (no shell, minimal CVE surface).
FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /todo-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /todo-api /todo-api
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/todo-api"]
