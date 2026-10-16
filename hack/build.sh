#!/bin/bash -ex
go version

VERSION=${VERSION:-$(sed -n 's/^DEFAULT_VERSION := //p' Makefile)}
: "${VERSION:?Makefile must define DEFAULT_VERSION}"

GIT_COMMIT=$(git rev-list -1 HEAD || true)
COMMIT=${CI_COMMIT:-${GIT_COMMIT}}
BUILD_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p bin
MODULE="github.com/medik8s/workload-availability-operator"

LDFLAGS_VALUE="-X ${MODULE}/version.Version=${VERSION} "
LDFLAGS_VALUE+="-X ${MODULE}/version.GitCommit=${COMMIT} "
LDFLAGS_VALUE+="-X ${MODULE}/version.BuildDate=${BUILD_DATE} "
# allow override for debugging flags
LDFLAGS_DEBUG="${LDFLAGS_DEBUG:-" -s -w"}"
LDFLAGS_VALUE+="${LDFLAGS_DEBUG}"
# must be single quoted for use in GOFLAGS, and for more options see https://pkg.go.dev/cmd/link
LDFLAGS="'-ldflags=${LDFLAGS_VALUE}'"

# add ldflags to goflags
export GOFLAGS+=" ${LDFLAGS}"
echo "goflags: ${GOFLAGS}"

# allow override and use zero by default- static linking
export CGO_ENABLED=${CGO_ENABLED:-0}
echo "cgo: ${CGO_ENABLED}"

# export in case it was set
export GOEXPERIMENT="${GOEXPERIMENT}"

# Use an explicitly supplied target platform, otherwise the builder platform.
GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-$(go env GOARCH)}"
GOOS="${GOOS}" GOARCH="${GOARCH}" go build -o bin/manager cmd/main.go
