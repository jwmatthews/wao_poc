package images

import (
	"fmt"
	"sort"
	"strings"
)

const (
	NHCManager = "RELATED_IMAGE_NHC_MANAGER"
	NHCConsole = "RELATED_IMAGE_NHC_CONSOLE"
	SNRManager = "RELATED_IMAGE_SNR_MANAGER"
	SBRManager = "RELATED_IMAGE_SBR_MANAGER"
	SBRAgent   = "RELATED_IMAGE_SBR_AGENT"
	FARManager = "RELATED_IMAGE_FAR_MANAGER"
	MDRManager = "RELATED_IMAGE_MDR_MANAGER"
	NMOManager = "RELATED_IMAGE_NMO_MANAGER"
)

// Required lists every image environment variable the operator needs at startup.
var Required = []string{NHCManager, NHCConsole, SNRManager, SBRManager, SBRAgent, FARManager, MDRManager, NMOManager}

// Set maps RELATED_IMAGE_* names to selected image pull references.
type Set map[string]string

// FromEnv builds a Set from the given lookup, failing if any required value is absent or blank.
func FromEnv(lookup func(string) (string, bool)) (Set, error) {
	s := Set{}
	var missing []string
	for _, k := range Required {
		v, ok := lookup(k)
		if !ok || strings.TrimSpace(v) == "" {
			missing = append(missing, k)
			continue
		}
		s[k] = v
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("missing required image environment variables: %s", strings.Join(missing, ", "))
	}
	return s, nil
}

// Get returns the image for an environment variable name, or "".
func (s Set) Get(env string) string { return s[env] }

// Sorted returns the variable names in sorted order.
func (s Set) Sorted() []string {
	keys := make([]string, 0, len(s))
	for k := range s {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
