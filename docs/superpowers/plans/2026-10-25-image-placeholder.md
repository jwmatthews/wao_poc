# Placeholder Image References Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bash-generated Go image map with a stable `__WAO_<ENV>__:placeholder` sentinel baked into the embedded runtime objects, so `operands.yaml` feeds only `config/manager/manager.yaml`.

**Architecture:** The runtime kustomize overlays and the SNR/SBR env patches become static and emit the sentinel. `render.go` swaps `images.Placeholder(env)` for the `RELATED_IMAGE_*` runtime value the same way it already swaps `__WAO_NAMESPACE__`. The generator, `zz_generated.images.go`, `kustomizeName`, and all overlay syncing are deleted; the required-image list lives once in `internal/images.Required`.

**Tech Stack:** Go 1.2x, kustomize (`bin/kustomize`), yq (`bin/yq`), jq, bash, `go test`.

**Spec:** `docs/superpowers/specs/2026-10-25-image-placeholder-design.md`

## Global Constraints

- Do not modify, fork or rebuild the component operators; nothing under `config/operands/<k>/config/` changes.
- Every component stays `Disabled`; no runtime behavior changes other than the string the renderer searches for.
- `RELATED_IMAGE_*` env on the manager Deployment remains the only runtime image source. `images.FromEnv` and `:latest` pull-policy handling are untouched.
- Never change a component webhook `failurePolicy`.
- Repository/tag validation rules in `hack/operand-image-refs.sh` are kept verbatim.
- Run `make check` before each commit. Run `make bundle-reset` before `make test`.
- Offline tests (`go test ./test/offline/`) copy the tree and run `make`; they need `bin/kustomize` and `bin/yq` present (`make kustomize yq`).

## Review Focus

1. Two bindings configured to the same `repository:tag` (NHC manager and console both `:latest`). Each container must get its own env value. Task 1 adds `TestRenderIdenticalImagesResolveIndependently`.
2. An upstream operand adds a container whose image WAO does not map. The build must fail, not deploy the upstream default. Task 1 adds the `image:` grep in `make operand-manifests` and `TestOperandManifestsRejectsUnmappedImage`.
3. A runtime overlay `images[].name` stops matching after an upstream rename, so no sentinel lands in `objects.yaml`. `TestEveryDefinitionMatchesItsManifests` (Task 1) fails because the placeholder is absent.
4. `operands.yaml` drops or misspells one image key, leaving a stale value in `manager.yaml`. Task 2 adds `TestOperandsYAMLDeclaresExactlyRequiredImages`.
5. `make check` reports drift and leaves regenerated files in the working tree. Task 3 makes the verifier restore them and asserts that in `TestVerificationRejectsStaleRuntimeObjectsWithoutMutating`.

---

### Task 1: Placeholder image references end to end

**Files:**
- Modify: `internal/images/images.go`
- Modify: `internal/components/component.go` (delete `ImageBinding`, `imageBinding`)
- Modify: `internal/components/{nhc,snr,sbr,far,mdr,nmo}.go` (`Images` becomes `[]string`)
- Modify: `internal/operands/render.go:40-58`
- Modify: `config/operands/{nhc,snr,sbr,far,mdr,nmo}/overlays/runtime/kustomization.yaml` (`images:` block and its comment)
- Modify: `config/operands/snr/overlays/runtime/manager_image_env_patch.yaml`, `config/operands/sbr/overlays/runtime/agent_image_env_patch.yaml`
- Modify: `hack/sync-operand-images.sh` (manager.yaml only)
- Modify: `hack/operand-image-refs.sh` (drop runtime/patch destination preflight)
- Modify: `Makefile:183-191` (`operand-manifests` target)
- Regenerate: `internal/operands/manifests/*/objects.yaml`
- Test: `internal/components/components_test.go`, `internal/operands/render_test.go`, `test/offline/image_refs_test.go`, `test/offline/pipeline_test.go`

**Interfaces:**
- Produces: `func Placeholder(env string) string` in package `images`, returning `"__WAO_" + env + "__:placeholder"`.
- Produces: `components.Definition.Images []string` (env names, e.g. `images.NHCManager`).
- Produces: `Render` returns an error containing `unresolved placeholder` when any `__WAO_` token survives substitution.
- `hack/operand-image-refs.sh` still emits `ENV<TAB>repository:tag` sorted by env. Its five-column TSV intermediate is unchanged in this task; Task 2 drops the `name` column.

- [ ] **Step 1: Write the failing Go tests**

In `internal/operands/render_test.go` replace `def.Images[0].Original` (line 48) with `images.Placeholder(def.Images[0])` and the loop at lines 224-226 with `for _, env := range def.Images { ph := images.Placeholder(env); if strings.Contains(string(b), ph) { t.Errorf(... ph) } }`. Add:

```go
func TestRenderRejectsUnresolvedImagePlaceholder(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	def.Images = def.Images[:1] // console placeholder stays in the manifests
	_, err := operands.Render(def, testNamespace, testImages())
	if err == nil || !strings.Contains(err.Error(), "unresolved placeholder") {
		t.Fatalf("err = %v", err)
	}
}

// Passes before and after this task; it pins Review Focus 1.
func TestRenderIdenticalImagesResolveIndependently(t *testing.T) {
	def, _ := components.ByKey(v1alpha1.ComponentKeyNodeHealthCheck)
	imgs := testImages()
	imgs[images.NHCConsole] = imgs[images.NHCManager]
	objs, err := operands.Render(def, testNamespace, imgs)
	if err != nil {
		t.Fatal(err)
	}
	console := find(t, objs, "Deployment", "node-healthcheck-node-remediation-console-plugin")
	c, _, _ := unstructured.NestedSlice(console.Object, "spec", "template", "spec", "containers")
	if got := c[0].(map[string]interface{})["image"]; got != imgs[images.NHCManager] {
		t.Fatalf("console image = %v", got)
	}
}
```

In `internal/components/components_test.go` change the loop at lines 47-50 to `for _, env := range d.Images { if !strings.Contains(text, images.Placeholder(env)) { ... } }` and delete `TestOriginalImagesMatchOperandInputs` (lines 93-120) and its `os`, `filepath`, `yaml` imports.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/components ./internal/operands -count=1`
Expected: compile errors on `images.Placeholder` and `def.Images[0]` type.

- [ ] **Step 3: Add `Placeholder` and switch `Definition.Images` to `[]string`**

`internal/images/images.go`: add `func Placeholder(env string) string` with a one-line doc comment saying it is the token kustomize bakes into embedded runtime objects and the renderer replaces. `internal/components/component.go`: delete `ImageBinding` and `imageBinding`; `Images []string // RELATED_IMAGE_* names; see images.Placeholder`. In each of the six definition files replace `imageBinding(images.X)` with `images.X`.

- [ ] **Step 4: Update `render.go`**

Replace the loop at lines 47-53 with `for _, env := range def.Images { img := imgs.Get(env); if img == "" { return ...no image configured... }; text = strings.ReplaceAll(text, images.Placeholder(env), img) }`. Replace the namespace-only check at lines 54-56 with `if strings.Contains(text, "__WAO_") { return nil, fmt.Errorf("%s/%s: unresolved placeholder", def.Key, name) }`. Leave the `latest` pull-policy map as is, iterating `def.Images` as env names.

- [ ] **Step 5: Make the runtime overlays static**

In each of the six `kustomization.yaml` set every `images[]` entry to `newName: __WAO_<ENV>__` and `newTag: placeholder`, where `<ENV>` is the env name whose `kustomizeName` in `operands.yaml` equals that entry's `name` (nhc: NHC_MANAGER and NHC_CONSOLE; snr, sbr, far, mdr, nmo: their `_MANAGER`). Replace the "newName and newTag are kept equal to operands.yaml" comment with one line: the `name` is the upstream image selector; the renderer replaces the placeholder with `RELATED_IMAGE_<...>` at reconcile time. Set the SNR patch value to `__WAO_RELATED_IMAGE_SNR_MANAGER__:placeholder` and the SBR patch value to `__WAO_RELATED_IMAGE_SBR_AGENT__:placeholder`, updating their comments the same way.

- [ ] **Step 6: Stop the scripts from touching the overlays**

`hack/sync-operand-images.sh`: delete the `key=` derivation, the `runtime=`/`kustomizeName` block and the SNR/SBR `case`; the loop body is `export WAO_IMAGE_ENV="$env" WAO_IMAGE_REF="$ref"; set_env config/manager/manager.yaml`. Update the header comment to "Synchronize RELATED_IMAGE_* values in config/manager/manager.yaml from operands.yaml." `hack/operand-image-refs.sh`: in the preflight loop keep only the `manager.yaml` `require_one`; delete the `runtime=`, `if [ -n "$name" ]` and `case "$env"` blocks. Leave the jq validation untouched in this task.

- [ ] **Step 7: Guard the embed against unmapped images**

In `Makefile` `operand-manifests`, after the existing `\${` grep inside the loop add:

```make
	  if grep -E '^\s*-?\s*image: ' internal/operands/manifests/$$k/objects.yaml | grep -qv '__WAO_'; then echo "$$k: image field is not a WAO placeholder"; exit 1; fi; \
```

Update the target's `##` help text to "Sync RELATED_IMAGE_* values and generate runtime manifests (offline)."

- [ ] **Step 8: Regenerate and run the Go tests**

Run: `make operand-manifests && grep -h 'image:' internal/operands/manifests/*/objects.yaml`
Expected: eight `image:` lines, all `__WAO_RELATED_IMAGE_*__:placeholder`; the SNR and SBR env `value:` lines also show their placeholders.
Run: `go test ./internal/... -count=1`
Expected: PASS.

- [ ] **Step 9: Update the offline tests**

`test/offline/image_refs_test.go`:
- `TestIndependentTaggedImagesStayAligned`: replace the `objects.yaml` contains-`want` assertion with `!strings.Contains(objects, want) && strings.Contains(objects, "__WAO_"+env+"__:placeholder")`; delete the `bindings` contains assertion.
- `TestImagePreflightRejectsMissingAndDuplicateDestinations`: delete the `selector`, `duplicate-selector`, `snr-self`, `sbr-agent` cases.

`test/offline/pipeline_test.go`: add

```go
func TestOperandManifestsRejectsUnmappedImage(t *testing.T) {
	tr := newTree(t)
	path := "config/operands/nhc/overlays/runtime/kustomization.yaml"
	tr.run("bin/yq", "-i", `del(.images[] | select(.name == "quay.io/medik8s/node-remediation-console"))`, path)
	out, err := tr.try("make", "-s", "operand-manifests")
	if err == nil || !strings.Contains(out, "not a WAO placeholder") {
		t.Fatalf("expected unmapped-image failure: %v\n%s", err, out)
	}
}
```

`test/offline/source_sync_test.go`: delete the `selector` case from `configureSourceFailure` and from the list in `TestUpdatePreflightPreservesAllDestinations`; the overlay is no longer a sync destination. Leave `reused-selector` for Task 2.

- [ ] **Step 10: Run offline tests and check**

Run: `make check && go test ./test/offline/ -count=1`
Expected: PASS. `git status --short` shows no change under `config/operands/*/config/`.

- [ ] **Step 11: Commit**

```bash
git add internal config/operands/*/overlays/runtime hack/sync-operand-images.sh hack/operand-image-refs.sh Makefile test/offline
git commit -m "Render operand images from __WAO_<ENV>__ placeholders instead of tagged references"
```

---

### Task 2: Delete the generator, `kustomizeName`, and the duplicated required-image list

**Files:**
- Delete: `hack/generate-image-bindings.sh`, `internal/components/zz_generated.images.go`
- Modify: `Makefile:186`, `hack/verify-operand-manifests.sh:16`
- Modify: `operands.yaml` (remove the seven `kustomizeName` keys)
- Modify: `hack/operand-image-refs.sh` (jq program)
- Test: `internal/images/images_test.go`, `test/offline/image_refs_test.go`, `test/offline/pipeline_test.go`, `test/offline/source_sync_test.go`

**Interfaces:**
- Consumes: `images.Required` (existing).
- Produces: `hack/operand-image-refs.sh` requires only: top-level `operands` has exactly the six keys; each has nonempty `source.path`/`source.branch` and a non-empty `images` map; env names unique; repository/tag rules unchanged. It no longer knows which env belongs to which operand.

- [ ] **Step 1: Write the failing Go test**

In `internal/images/images_test.go`:

```go
func TestOperandsYAMLDeclaresExactlyRequiredImages(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "operands.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Operands map[string]struct {
			Images map[string]map[string]any `json:"images"`
		} `json:"operands"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	var got []string
	for key, op := range doc.Operands {
		for env, fields := range op.Images {
			got = append(got, env)
			if _, ok := fields["kustomizeName"]; ok {
				t.Errorf("%s/%s: kustomizeName is no longer used; the runtime overlays are static", key, env)
			}
		}
	}
	want := slices.Clone(Required)
	slices.Sort(got)
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("operands.yaml images = %v, want %v", got, want)
	}
}
```

Imports: `os`, `path/filepath`, `slices`, `sigs.k8s.io/yaml`.

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/images -run TestOperandsYAMLDeclaresExactlyRequiredImages -count=1`
Expected: FAIL naming `kustomizeName`.

- [ ] **Step 3: Remove `kustomizeName` from `operands.yaml` and its validation**

Delete the seven `kustomizeName:` lines and the header comment sentence about it. In `hack/operand-image-refs.sh` jq: delete the `$required` object and both checks that use it (the `keys != ($required | keys)` check becomes a literal `["far","mdr","nhc","nmo","sbr","snr"]` comparison); delete the `RELATED_IMAGE_SBR_AGENT` branch, the `missing kustomizeName` branch and the `$reused` selector check; emit `[.key, .env, .image.repository, .image.tag] | @tsv`. Update both `read` loops to four fields (`key env repository tag`). Update the header comment ("six operands, eight images" becomes "six operands; the image set is checked in Go against images.Required").

- [ ] **Step 4: Delete the generator**

`git rm hack/generate-image-bindings.sh internal/components/zz_generated.images.go`. Remove `Makefile:186`. In `hack/verify-operand-manifests.sh:16` drop `internal/components/zz_generated.images.go` from `generated`.

- [ ] **Step 5: Update the offline tests**

- `test/offline/pipeline_test.go`: delete `const bindings` and `TestGeneratorRejectsMissingTagWithoutOverwriting`, `TestGeneratorRejectsDuplicateEnvironmentNames`. Rename `TestTagChangesRegenerateBindingsWithoutEditingDefinitions` to `TestTagChangesEditOnlyManagerYAML`: after `changeTags` and `make -s operand-manifests`, snapshot `internal` and `config/operands` before and after and assert equal; assert `manager.yaml` changed. Replace `TestVerificationRejectsStaleBindings` with `TestVerificationRejectsStaleRuntimeObjects`: write `example.test/nhc:stale` over the first `__WAO_RELATED_IMAGE_NHC_MANAGER__:placeholder` in `internal/operands/manifests/nhc/objects.yaml`, run `make -s verify-operand-manifests`, expect failure containing `generated`.
- `test/offline/image_refs_test.go`: delete the `missing-env`, `missing-selector`, `reused-selector` cases; drop `bindings` from the two `snapshot` calls.
- `test/offline/source_sync_test.go`: delete the `reused-selector` case and remove `bindings` from both `paths` slices.

- [ ] **Step 6: Run everything**

Run: `make check && go test ./internal/... ./test/offline/ -count=1`
Expected: PASS. `grep -rn 'kustomizeName\|zz_generated.images\|generate-image-bindings' --exclude-dir=docs --exclude-dir=.tools .` returns nothing.

- [ ] **Step 7: Commit**

```bash
git add -A operands.yaml hack Makefile internal test/offline
git commit -m "Drop generated image bindings and kustomizeName; images.Required is the single list"
```

---

### Task 3: Verifier leaves the tree untouched

**Files:**
- Modify: `hack/verify-operand-manifests.sh:14-27`
- Test: `test/offline/pipeline_test.go`

**Interfaces:**
- Produces: on drift, `verify-operand-manifests` prints the existing `generated files differ in <path>` message, restores `<path>` from its pre-regeneration copy, and exits non-zero.

- [ ] **Step 1: Extend the failing test**

In `TestVerificationRejectsStaleRuntimeObjects` (Task 2) rename to `TestVerificationRejectsStaleRuntimeObjectsWithoutMutating` and, after the failed verify, assert `tr.read("internal/operands/manifests/nhc/objects.yaml")` still contains `example.test/nhc:stale`.

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./test/offline/ -run TestVerificationRejectsStaleRuntimeObjectsWithoutMutating -count=1`
Expected: FAIL, the stale string was overwritten.

- [ ] **Step 3: Restore on drift**

In the `for path in "${generated[@]}"` comparison loop, inside the `if ! diff -qr` branch add `rm -rf "$path"; cp -R "$work/$path" "$path"` after `problem`. Change the header comment and the Makefile `##` help for `verify-operand-manifests` to say it regenerates into place, compares, and restores the originals on drift.

- [ ] **Step 4: Run tests**

Run: `make check && go test ./test/offline/ -count=1`
Expected: PASS; `git status --short` is clean after `make check`.

- [ ] **Step 5: Commit**

```bash
git add hack/verify-operand-manifests.sh Makefile test/offline/pipeline_test.go
git commit -m "verify-operand-manifests restores generated files when it reports drift"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md:65-67, 83-100, 108-136, 142-145`
- Modify: `docs/updating-operand-manifests.md:19, 42-71, 112-120, 140-146`
- Modify: `docs/superpowers/specs/2026-10-24-simplify-operand-updates-design.md` (one line under "Layout and ownership" pointing to the 2026-10-25 note)

- [ ] **Step 1: README**

Table: merge the `generate-image-bindings.sh` row into the `verify-operand-manifests.sh` row. Quick-start comment: "Prepare runtime objects for the WAO binary." Render bullet: `operand-manifests` synchronizes `RELATED_IMAGE_*` in `config/manager/manager.yaml` and generates `internal/operands/manifests/<key>/objects.yaml`; the objects carry `__WAO_<ENV>__:placeholder` image tokens that the renderer replaces at reconcile time. Remove `kustomizeName` from the YAML example and the paragraph sentence about it. Replace "Never hand-edit generated runtime objects or Go bindings" with "Never hand-edit generated runtime objects", and the verification sentence with the restore behavior from Task 3.

- [ ] **Step 2: Developer guide**

Same edits in `docs/updating-operand-manifests.md`: quick-start comment, YAML example, the `kustomizeName` bullet (delete), the "What to expect" table row for `make operand-manifests`, the verify paragraph. Add one sentence under "Configure the source and images": the runtime overlays are static and never need editing when a tag changes.

- [ ] **Step 3: Verify and commit**

Run: `grep -rn 'kustomizeName\|zz_generated\|Go bindings\|Go image bindings' README.md docs/updating-operand-manifests.md AGENTS.md`
Expected: no output.

```bash
git add README.md docs
git commit -m "Document placeholder image references"
```

---

### Final verification

Run on a clean tree: `make bundle-reset && make check && make test-offline && make test`.
Expected: all PASS; `git status --short` empty. The bundle CSV `relatedImages` is unchanged.
