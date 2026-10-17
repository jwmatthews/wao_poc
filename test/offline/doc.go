// Package offline holds regression tests for the operand manifest pipeline
// (release-set.yaml, hack/generate-image-bindings.sh, hack/verify-operand-manifests.sh
// and the bump-operands Makefile target). They copy the pipeline inputs into a
// throwaway git checkout and drive make there. They need no network or cluster,
// but the Go module cache or vendor/ must already be populated.
package offline
