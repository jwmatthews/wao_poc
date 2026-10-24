package operands

import (
	"bytes"
	"embed"
	"fmt"
	"path"
	"sort"

	"sigs.k8s.io/yaml"
)

//go:embed manifests
var manifests embed.FS

// Load returns the objects of one component's objects.yaml keyed by "<Kind>/<name>".
// The file is written by `make operand-manifests` from config/operands/<dir>/overlays/runtime.
func Load(dir string) (map[string][]byte, error) {
	b, err := manifests.ReadFile(path.Join("manifests", dir, "objects.yaml"))
	if err != nil {
		return nil, fmt.Errorf("manifests for %q: %w", dir, err)
	}
	out := map[string][]byte{}
	for _, doc := range bytes.Split(b, []byte("\n---\n")) {
		doc = bytes.TrimSpace(doc)
		if len(doc) == 0 {
			continue
		}
		var head struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		}
		if err := yaml.Unmarshal(doc, &head); err != nil {
			return nil, fmt.Errorf("manifests for %q: %w", dir, err)
		}
		key := head.Kind + "/" + head.Metadata.Name
		if _, dup := out[key]; dup {
			return nil, fmt.Errorf("manifests for %q: duplicate %s", dir, key)
		}
		out[key] = doc
	}
	return out, nil
}

func sortedNames(m map[string][]byte) []string {
	names := make([]string, 0, len(m))
	for n := range m {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}
