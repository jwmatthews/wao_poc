// Package offline holds regression tests for local operand configuration copying,
// explicit tagged image settings, and offline generation. Tests drive the real
// Make targets and helpers in throwaway Git checkouts. No network or cluster is
// needed, but build tools and the Go module cache or vendor/ must be populated.
package offline
