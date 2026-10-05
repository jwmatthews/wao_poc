package operands

import (
	"embed"
	"fmt"
	"path"
	"sort"
)

//go:embed manifests
var manifests embed.FS

// Load returns the YAML files of one component directory keyed by file name.
func Load(dir string) (map[string][]byte, error) {
	entries, err := manifests.ReadDir(path.Join("manifests", dir))
	if err != nil {
		return nil, fmt.Errorf("manifest directory %q: %w", dir, err)
	}
	out := map[string][]byte{}
	for _, e := range entries {
		if e.IsDir() || path.Ext(e.Name()) != ".yaml" {
			continue
		}
		b, err := manifests.ReadFile(path.Join("manifests", dir, e.Name()))
		if err != nil {
			return nil, err
		}
		out[e.Name()] = b
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
