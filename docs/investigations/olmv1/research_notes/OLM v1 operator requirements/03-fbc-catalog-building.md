# Building, validating, publishing and serving a File-Based Catalog (FBC) for OLM v1 / OpenShift (state as of 2026-10-10)

Scope note: all Red Hat facts below come from the `html-single` books for OpenShift 4.18, 4.19, 4.20 and 4.21 (downloaded 2026-10-10 and grepped locally because the fetcher truncated them). Section numbers quoted (e.g. "4.3.2") are those of the 4.20 *Extensions* book unless stated. Upstream facts come from olm.operatorframework.io, operator-framework.github.io/operator-controller and the operator-registry / operator-controller source on GitHub.

Source URL shorthand used throughout:
- RH-EXT-4.20 = https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index (4.18/4.19/4.21 = same path with the version changed)
- RH-OPS-4.20 = https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/operators/index
- RH-DISC-4.20 = https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index
- RH-CLI-4.20 = https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/cli_tools/index (chapter 8 "opm CLI")
- OLM-FBC = https://olm.operatorframework.io/docs/reference/file-based-catalogs/
- OLM-TPL = https://olm.operatorframework.io/docs/reference/catalog-templates/

---

## Key question 1: FBC schema (olm.package / olm.channel / olm.bundle / olm.deprecations, properties, file layout) and which properties OLM v1 consumes

### Takeaway
An FBC is a directory of JSON or YAML "blobs"; every package needs exactly one `olm.package`, at least one `olm.channel` and one or more `olm.bundle` blobs, with the optional `olm.deprecations` blob. OLM v1 (operator-controller) reads the bundle `olm.package` property for the version, rejects bundles that carry `olm.package.required` / `olm.gvk.required` / `olm.constraint`, surfaces `olm.deprecations` as ClusterExtension conditions, and treats `olm.csv.metadata` as the replacement for the deprecated `olm.bundle.object`.

### Cited Findings

**Schema definitions (Go source, authoritative field list)**

- Schema constants: `SchemaPackage = "olm.package"`, `SchemaChannel = "olm.channel"`, `SchemaBundle = "olm.bundle"`, `SchemaDeprecation = "olm.deprecations"` — [operator-registry alpha/declcfg/declcfg.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/declcfg/declcfg.go)
- `olm.package` Go struct (verbatim JSON tags): `Schema string json:"schema"`, `Name string json:"name"`, `DefaultChannel string json:"defaultChannel"`, `Icon *Icon json:"icon,omitempty"`, `Description string json:"description,omitempty"`, `Properties []property.Property json:"properties,omitempty"` — [declcfg.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/declcfg/declcfg.go)
- `olm.channel` Go struct: `Schema`, `Name json:"name"`, `Package json:"package"`, `Entries []ChannelEntry json:"entries"`, `Properties ... omitempty`; `ChannelEntry`: `Name json:"name"`, `Replaces json:"replaces,omitempty"`, `Skips []string json:"skips,omitempty"`, `SkipRange json:"skipRange,omitempty"` — [declcfg.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/declcfg/declcfg.go)
- `olm.bundle` Go struct: `Schema`, `Name json:"name,omitempty"`, `Package json:"package,omitempty"`, `Image json:"image"`, `Properties []property.Property json:"properties,omitempty"`, `RelatedImages []RelatedImage json:"relatedImages,omitempty"`, plus non-serialized `CsvJSON string json:"-"` and `Objects []string json:"-"` — [declcfg.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/declcfg/declcfg.go)
- `olm.deprecations` Go struct: `Schema`, `Package json:"package"`, `Entries []DeprecationEntry json:"entries"`; `DeprecationEntry`: `Reference PackageScopedReference json:"reference"`, `Message string json:"message"` — [declcfg.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/declcfg/declcfg.go)
- Generic `Meta` type (what catalogd serves): `Schema`, `Package`, `Name`, `Blob json.RawMessage` — [declcfg.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/declcfg/declcfg.go)

**Schema definitions (CUE form as documented by Red Hat 4.20, section 4.1.3)**

- "Each Operator package requires one `olm.package` blob, at least one `olm.channel` blob, and one or more `olm.bundle` blobs." — [RH-EXT-4.20 §4.1.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- `olm.package` CUE (verbatim):
  ```
  #Package: {
    schema: "olm.package"
    // Package name
    name: string & !=""
    // A description of the package
    description?: string
    // The package's default channel
    defaultChannel: string & !=""
    // An optional icon
    icon?: {
      base64data: string
      mediatype:  string
    }
  }
  ```
  — [RH-EXT-4.20 §4.1.3.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- `olm.channel` CUE (verbatim):
  ```
  #Channel: {
    schema: "olm.channel"
    package: string & !=""
    name: string & !=""
    entries: [...#ChannelEntry]
  }
  #ChannelEntry: {
    // name is required. It is the name of an `olm.bundle` that
    // is present in the channel.
    name: string & !=""
    // replaces is optional. It is the name of bundle that is replaced
    // by this entry. It does not have to be present in the entry list.
    replaces?: string & !=""
    // skips is optional. It is a list of bundle names that are skipped by
    // this entry. The skipped bundles do not have to be present in the
    // entry list.
    skips?: [...string & !=""]
    // skipRange is optional. It is the semver range of bundle versions
    // that are skipped by this entry.
    skipRange?: string & !=""
  }
  ```
  — [RH-EXT-4.20 §4.1.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Channel invariants: "If a bundle entry represents an edge in multiple `olm.channel` blobs, it can only appear once per channel." and "It is valid for an entry's `replaces` value to reference another bundle name that cannot be found in this catalog or another catalog. However, all other channel invariants must hold true, such as a channel not having multiple heads." — [RH-EXT-4.20 §4.1.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- `olm.bundle` CUE (verbatim):
  ```
  #Bundle: {
    schema: "olm.bundle"
    package: string & !=""
    name: string & !=""
    image: string & !=""
    properties: [...#Property]
    relatedImages?: [...#RelatedImage]
  }
  #Property: {
    // type is required
    type: string & !=""
    // value is required, and it must not be null
    value: !=null
  }
  #RelatedImage: {
    // image is the image reference
    image: string & !=""
    // name is an optional descriptive name for an image that
    // helps identify its purpose in the context of the bundle
    name?: string & !=""
  }
  ```
  — [RH-EXT-4.20 §4.1.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Upstream required/optional summary: `olm.package` required `schema`, `name`; optional `description`, `defaultChannel`, `icon`. `olm.channel` required `schema`, `package`, `name`, `entries`; entry `name` required, `replaces`/`skips`/`skipRange` optional. `olm.bundle` required `schema`, `package`, `name`, `image`; optional `relatedImages`, `properties`. `olm.deprecations` required `schema`, `package`, `entries`. — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- Upstream `olm.channel` example (verbatim):
  ```yaml
  schema: olm.channel
  package: foo
  name: candidate-v0
  entries:
  - name: foo.v0.3.1
    replaces: foo.v0.2.1
    skips:
    - foo.v0.3.0
    skipRange: ">=0.2.0-0 <0.3.1-0"
  - name: foo.v0.3.0
    replaces: v0.2.1
  - name: foo.v0.2.1
  ```
  — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- Upstream `olm.bundle` example (verbatim):
  ```yaml
  schema: olm.bundle
  package: foo
  name: foo.v0.3.0
  image: quay.io/example-com/foo-bundle:v0.3.0
  relatedImages:
   - name: bundle
     image: quay.io/example-com/foo-bundle:v0.3.0
   - name: operator
     image: quay.io/example-com/foo-operator:v0.3.0
  properties:
  - type: olm.package
    value:
      packageName: foo
      version: 0.3.0
  ```
  — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)

**olm.deprecations**

- Red Hat 4.20 verbatim example with all three reference types:
  ```yaml
  schema: olm.deprecations
  package: my-operator
  entries:
    - reference:
        schema: olm.package
      message: |
      The 'my-operator' package is end of life. Please use the
      'my-operator-new' package for support.
    - reference:
        schema: olm.channel
        name: alpha
      message: |
      The 'alpha' channel is no longer supported. Please switch to the
      'stable' channel.
    - reference:
        schema: olm.bundle
        name: my-operator.v1.68.0
      message: |
      my-operator.v1.68.0 is deprecated. Uninstall my-operator.v1.68.0 and
      install my-operator.v1.72.0 for support.
  ```
  Rules: "Each deprecation schema must have a `package` value, and that package reference must be unique across the catalog. There must not be an associated `name` field." / "The `olm.package` schema must not include a `name` field, because it is determined by the `package` field defined earlier in the schema." / "All `message` fields, for any reference type, must be a non-zero length and represented as an opaque text blob." / "The `name` field for the `olm.channel` schema is required." / "The `name` field for the `olm.bundle` schema is required." / Note: "The deprecation feature does not consider overlapping deprecation, for example package versus channel versus bundle." — [RH-EXT-4.20 §4.1.3.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Deprecation reference type → status condition table: `olm.package` → `PackageDeprecated`, `olm.channel` → `ChannelDeprecated`, `olm.bundle` → `BundleDeprecated` — [RH-EXT-4.20 §4.1.3.4, Table 4.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat says deprecations.yaml placement: "To add or update deprecation messages for an Operator, ensure there is a `deprecations.yaml` file in the same directory as the package's `index.yaml` file." — [RH-EXT-4.20 §4.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- OLM v1 ClusterExtension condition constants (verbatim): `TypeDeprecated = "Deprecated"`, `TypePackageDeprecated = "PackageDeprecated"`, `TypeChannelDeprecated = "ChannelDeprecated"`, `TypeBundleDeprecated = "BundleDeprecated"`; doc comment: "TypeDeprecated is a rollup condition that is present when any of the deprecated conditions are present." — [operator-controller api/v1/clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- Catalog priority resolution: "Bundles that are not deprecated are prioritized over bundles that are deprecated." — [RH-EXT-4.20 §4.4.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**Property types (Go source and upstream docs)**

- Property type constants (verbatim): `TypePackage = "olm.package"`, `TypePackageRequired = "olm.package.required"`, `TypeGVK = "olm.gvk"`, `TypeGVKRequired = "olm.gvk.required"`, `TypeBundleObject = "olm.bundle.object"`, `TypeCSVMetadata = "olm.csv.metadata"`, `TypeConstraint = "olm.constraint"`, `TypeChannel = "olm.channel"` — [operator-registry alpha/property/property.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/property/property.go)
- `olm.package` property struct: `PackageName json:"packageName"`, `Version json:"version"`, `Release json:"release,omitzero"` — [property.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/property/property.go); upstream docs: `packageName` "required, non-empty", `version` "required, valid semver", `release` "optional, alphanumeric with hyphens/dots, max 20 chars" and "When `release` field is present, bundle name must follow: `<package-name>-v<version>-<release>`" — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- Red Hat: "The `olm.package` property defines the package name and version. This is a required property on bundles, and there must be exactly one of these properties. The `packageName` field must match the bundle's first-class `package` field, and the `version` field must be a valid semantic version." — [RH-EXT-4.20 §4.1.4.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- `olm.gvk` / `olm.gvk.required` structs: `Group`, `Kind`, `Version` (all required, non-empty) — [property.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/property/property.go); [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- `olm.package.required` struct: `PackageName json:"packageName"`, `VersionRange json:"versionRange"` ("valid semver range") — [property.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/property/property.go); [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- `olm.csv.metadata` struct fields (verbatim JSON tags): `annotations`, `apiServiceDefinitions`, `crdDescriptions`, `description`, `displayName`, `installModes`, `keywords`, `labels`, `links`, `maintainers`, `maturity`, `minKubeVersion`, `nativeAPIs`, `provider` — [property.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/property/property.go)
- `olm.bundle.object`: "This property is _deprecated_ because it causes major performance issues when loading and serving file-based catalogs." Value: `data: string (required, base64-encoded manifest)`. `olm.csv.metadata` "should be used instead" and is "Required by OLM Package Server for channel heads." — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- The `olm.channel` property type: "The Channel properties are for internal use only. DO NOT use it for any public-facing functionalities. This API is in alpha stage and it is subject to change." — [property.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/property/property.go)
- `olm.constraint` property shape: `failureMessage` optional plus exactly one of `gvk`, `package`, `cel: {rule}`, or compound `all`/`any`/`not` — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- `olm.bundle.mediatype` (bundle-schema-level property, not in property.go constants): "the experimental olm.bundle.mediatype property of the olm.bundle schema object differentiates a plain bundle (plain+v0) from a regular (registry+v1) bundle" — [OKD 4.20 "Operator Framework packaging format"](https://docs.okd.io/4.20/operators/understanding/olm-packaging-format.html) (same text is in the Red Hat Operators book). It appears in operator-controller only in a catalogd GraphQL discovery test fixture (`internal/catalogd/graphql/discovery_test.go`) — [operator-controller repo code search](https://github.com/operator-framework/operator-controller)

**Which properties OLM v1 actually consumes**

- operator-controller reads the bundle version from `property.TypePackage` (`internal/operator-controller/bundleutil/bundle.go`: `if p.Type == property.TypePackage {`) — [operator-controller bundleutil/bundle.go](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/bundleutil/bundle.go)
- operator-controller's resolver validation rejects bundles carrying `property.TypePackageRequired` (in `internal/operator-controller/resolve/validation.go`), with tests for `olm.package.required` content being rejected regardless of value — [operator-controller resolve/validation.go](https://github.com/operator-framework/operator-controller/blob/main/internal/operator-controller/resolve/validation.go)
- Upstream limitations page: operators "cannot declare dependencies using: `olm.gvk.required`, `olm.package.required`, `olm.constraint`"; "only supports installing operators packaged in OLM v0 bundles, also known as `registry+v1` bundles"; must support `AllNamespaces`; "must not define `APIService`s in the `ClusterServiceVersion`"; `OperatorConditions` not supported; "OLM v1 verifies these criteria at install time and reports violations through the `ClusterExtensions`'s status conditions." — [operator-controller limitations](https://operator-framework.github.io/operator-controller/project/olmv1_limitations/)
- Red Hat 4.20 §5.1.1 "Supported extensions": registry+v1; AllNamespaces (SingleNamespace/OwnNamespace Technology Preview in 4.20); "must not use webhooks" ("You can install extensions that use webhooks as a Technology Preview feature in OpenShift Container Platform 4.20"); must not declare dependencies via `olm.gvk.required`, `olm.package.required`, `olm.constraint` — [RH-EXT-4.20 §5.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- `olm.csv.metadata` is used by the documented client-side queries (install modes / webhooks) both upstream and in Red Hat docs: `select(.type == "olm.csv.metadata").value.installModes[] | select(.type == "AllNamespaces" and .supported == true)` — [operator-controller catalog-queries](https://operator-framework.github.io/operator-controller/howto/catalog-queries/); [RH-EXT-4.20 §5.1.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- operator-controller's `hack/tools/catalogs/list-compatible-bundles` notes older bundles may "declare nothing at all (older released bundles sans "olm.csv.metadata" property)" — [operator-controller repo](https://github.com/operator-framework/operator-controller/blob/main/hack/tools/catalogs/list-compatible-bundles)
- Red Hat 4.1.4 "Properties" in the OLM v1 Extensions book documents only `olm.package`, `olm.gvk`, `olm.package.required`, `olm.gvk.required` — [RH-EXT-4.20 §4.1.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**JSON vs YAML, file layout**

- "File-based catalogs can be stored and loaded from directory-based file systems. The `opm` CLI loads the catalog by walking the root directory and recursing into subdirectories. The CLI attempts to load every file it finds and fails if any errors occur." / "Non-catalog files can be ignored using `.indexignore` files, which have the same rules for patterns and precedence as `.gitignore` files." — [RH-EXT-4.20 §4.1.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Example `.indexignore` (verbatim):
  ```
  # Ignore everything except non-object .json and .yaml files
  **/*
  !*.json
  !*.yaml
  **/objects/*.json
  **/objects/*.yaml
  ```
  — [RH-EXT-4.20 §4.1.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- "Catalog maintainers have the flexibility to choose their layout, but it is recommended to store each package's file-based catalog blobs in separate subdirectories. Each individual file can be either JSON or YAML; it is not necessary for every file in a catalog to use the same format." Basic recommended structure (verbatim):
  ```
  catalog
  ├── packageA
  │   └── index.yaml
  ├── packageB
  │   ├── .indexignore
  │   ├── index.yaml
  │   └── objects
  │       └── packageB.v0.1.0.clusterserviceversion.yaml
  └── packageC
      └── index.json
      └── deprecations.yaml
  ```
  "This recommended structure has the property that each subdirectory in the directory hierarchy is a self-contained catalog, which makes catalog composition, discovery, and navigation trivial file system operations." — [RH-EXT-4.20 §4.1.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Upstream recommended layout uses `catalog/pkgA/operator.yaml`, `catalog/pkgB/{.indexignore,operator.yaml,README.md}`, `catalog/pkgC/{package.json,channels.yaml,bundles.json}` — i.e. any file names, one or many files — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)

### Inferences
- For a single-package catalog the minimal viable content is three blobs (`olm.package`, one `olm.channel`, one `olm.bundle`) in one `catalog/<package>/index.yaml`, optionally a sibling `deprecations.yaml`. Multi-document YAML (`---` separators) is what `opm init`/`opm render --output yaml` produce and what Red Hat's procedure appends to.
- Because operator-controller takes the version from the `olm.package` property and compares versions semantically, every bundle's `olm.package.value.version` must be valid semver (the same requirement `opm validate` enforces). `olm.csv.metadata` is what tooling and UIs use for install modes / description; `olm.bundle.object` works but is deprecated for size/performance reasons, so render with `--migrate-level bundle-object-to-csv-metadata` (see Q2).
- `olm.gvk` (provided API) is harmless in OLM v1; the `*.required` and `olm.constraint` properties make a bundle uninstallable in OLM v1 (upstream and OpenShift 4.18–4.21), so an operator that previously relied on OLM v0 dependency resolution must not carry them if it targets OLM v1.

### Gaps
- No primary source enumerates, in one place, every FBC property operator-controller reads or ignores; the findings above are assembled from code-search hits (`bundleutil/bundle.go`, `resolve/validation.go`) and documentation. I could not confirm from source whether operator-controller reads `olm.csv.metadata` itself (vs. only unpacking the bundle image's CSV at install time) — code search for non-test usage returned only docs and hack scripts.
- Whether `olm.bundle.mediatype: plain+v0` is honored by current operator-controller releases could not be confirmed (only a test fixture references it; the limitations page says only `registry+v1` is supported).

---

## Key question 2: opm tooling (render, init, validate, templates, generate dockerfile, serve/cache, alpha list / render-graph) and opm ↔ OpenShift versions

### Takeaway
`opm init` → `opm render <bundle-image> --output yaml` → hand-write the `olm.channel` → `opm validate` → `opm generate dockerfile` → `podman build`/`push` is the documented end-to-end path on both upstream and OpenShift; the semver/basic templates (`opm alpha render-template …`) can generate the channel graph for you. The `opm serve --cache-only` step baked into the generated Dockerfile is for the gRPC server (OLM v0); catalogd does not run `opm serve`.

### Cited Findings

**opm render**

- Usage: `render [catalog-image | catalog-directory | bundle-image | bundle-directory]...`; short: "Generate a stream of file-based catalog objects from catalogs and bundles"; flags: `--output, -o` (string, default `json`, "Output format of the streamed file-based catalog objects (json|yaml)"), `--migrate-level` (string, "Name of the last migration to run", default none), `--migrate` (bool, "Perform all available schema migrations on the rendered FBC"), `--alpha-image-ref-template` ("When bundle image reference information is unavailable, populate it with this template", variables `{{.Package}}`, `{{.Name}}`, `{{.Version}}`); `--migrate` and `--migrate-level` are mutually exclusive — [operator-registry cmd/opm/render/cmd.go](https://github.com/operator-framework/operator-registry/blob/master/cmd/opm/render/cmd.go)
- Migration name (verbatim): `newMigration("bundle-object-to-csv-metadata", `migrates bundles' "olm.bundle.object" to "olm.csv.metadata"`, bundleObjectToCSVMetadata)` — [operator-registry alpha/action/migrations/migrations.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/action/migrations/migrations.go)
- Red Hat procedure: `$ opm render <registry>/<namespace>/<bundle_image_name>:<tag> --output=yaml >> <catalog_dir>/index.yaml` ("Specifies the pull spec for the bundle image"; note "Channels must contain at least one bundle.") — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat extract-an-existing-catalog: `$ opm render <registry>/<namespace>/<catalog_image_name>:<tag> -o yaml > <catalog_dir>/index.yaml` ("Alternatively, you can use the `-o json` flag to output in JSON format.") — [RH-EXT-4.20 §4.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat's rendered-catalog example shows the Red Hat index still carrying `olm.bundle.object` entries: `- type: olm.bundle.object\n  value:\n    data: <base64_string>` — [RH-EXT-4.20 §4.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**opm init**

- Usage `opm init <packageName> [flags]`; flags `-c/--default-channel`, `-d/--description`, `-i/--icon`, `-o/--output` (json|yaml) — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- Red Hat (verbatim):
  ```
  $ opm init <operator_name> \
      --default-channel=preview \
      --description=./README.md \
      --icon=./operator-icon.svg \
      --output yaml \
      > <catalog_dir>/index.yaml
  ```
  "This command generates an `olm.package` declarative config blob in the specified catalog configuration file." — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Channel entry to hand-add (verbatim):
  ```yaml
  ---
  schema: olm.channel
  package: <operator_name>
  name: preview
  entries:
    - name: <operator_name>.v0.1.0
  ```
  "Ensure that you include the period (.) after the `<operator_name>` variable but before the `v` in the version. Otherwise, the entry fails to pass the `opm validate` command." — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**opm validate**

- `opm validate <directory> [flags]`; `-o/--output` (json|yaml for structured results); "Returns exit code 0 for valid catalogs, 1 for invalid"; structured output "includes `passed` (boolean) and optional `error` object with `message` field" — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- Red Hat: `$ opm validate <catalog_dir>` then `$ echo $?` → `0` — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- "opm validate command returns an error if any duplicates are found." (context: duplicate package names across composed catalogs) — [RH-EXT-4.20 §4.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**Catalog templates**

- Basic template (verbatim):
  ```yaml
  schema: olm.template.basic
  entries:
    - schema: olm.package
      name: example-operator
      defaultChannel: stable
    - schema: olm.channel
      package: example-operator
      name: stable
      entries:
        - name: example-operator.v0.1.0
        - name: example-operator.v0.2.0
          replaces: example-operator.v0.1.0
    - schema: olm.bundle
      image: docker.io/example/example-operator-bundle:0.1.0
    - schema: olm.bundle
      image: docker.io/example/example-operator-bundle:0.2.0
  ```
  Command: `opm alpha render-template basic [flags] <filename>` — [OLM-TPL](https://olm.operatorframework.io/docs/reference/catalog-templates/)
- Semver template (verbatim):
  ```yaml
  Schema: olm.semver
  GenerateMajorChannels: true
  GenerateMinorChannels: true
  Candidate:
    Bundles:
    - Image: quay.io/foo/olm:testoperator.v0.1.0
  Fast:
    Bundles:
    - Image: quay.io/foo/olm:testoperator.v1.0.1
  Stable:
    Bundles:
    - Image: quay.io/foo/olm:testoperator.v1.0.1
  ```
  Command: `opm alpha render-template semver [flags] <filename>`; common flags `-o, --output` (`yaml` or `json`), `--skip-tls-verify`, `--use-http` (mutually exclusive) — [OLM-TPL](https://olm.operatorframework.io/docs/reference/catalog-templates/)
- Semver semantics: "`GenerateMinorChannels` defaults to true if unspecified"; `GenerateMinorChannels: true` creates Y-stream channels (e.g. `candidate-v0.1`, `candidate-v0.2`); `GenerateMajorChannels: true` creates X-stream channels (e.g. `candidate-v0`, `candidate-v1`); "This template supports channel names `Candidate`, `Fast`, and `Stable`, in order of increasing channel stability."; default channel preference Stable > Fast > Candidate, then higher bundle version; within channels bundles get `skips` edges to intermediate versions, `replaces` edges connect across minor transitions within major channels, "Major version boundaries are never transgressed within a single channel"; "The semver template depends on the optional `csv.spec.version` field. If you want to use the semver catalog template, you must specify a version in your extension's CSV."; "since version build metadata MUST be ignored when determining version precedence...if any bundles differ only by build metadata the render attempt will generate a fatal error." — [OLM-TPL](https://olm.operatorframework.io/docs/reference/catalog-templates/)
- Semver render output formats: `json|yaml|mermaid` (default json) — [OLM-TPL](https://olm.operatorframework.io/docs/reference/catalog-templates/)
- `opm alpha` subcommands registered: `bundle`, `list`, `render-graph`, `template`, `convert-template` — [operator-registry cmd/opm/alpha/cmd.go](https://github.com/operator-framework/operator-registry/blob/master/cmd/opm/alpha/cmd.go)

**opm alpha list / render-graph**

- `opm alpha list packages <indexRef>` ("List packages in an index"), `opm alpha list channels <indexRef> [packageName]`, `opm alpha list bundles <indexRef> <packageName>` ("Bundles appearing in multiple channels are shown multiple times (once per channel)"); all carry the note that they are for human convenience and "automation should use the "render" subcommand instead" — [operator-registry cmd/opm/alpha/list/cmd.go](https://github.com/operator-framework/operator-registry/blob/master/cmd/opm/alpha/list/cmd.go)
- `opm alpha render-graph [index-image | fbc-dir]`: "mermaid-formatted view of upgrade graph of operators in an index"; flags `--minimum-edge`, `--package-name`/`-p`, `--draw-v0-semantics` — [operator-registry cmd/opm/alpha/render-graph/cmd.go](https://github.com/operator-framework/operator-registry/blob/master/cmd/opm/alpha/render-graph/cmd.go)

**opm generate dockerfile**

- `opm generate dockerfile <dcRootDir> [flags]`; flags `-i/--binary-image`, `-l/--extra-labels` — [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- Red Hat: `$ opm generate dockerfile <catalog_dir> -i registry.redhat.io/openshift4/ose-operator-registry-rhel9:v4.20` — "Specify the official Red Hat base image by using the `-i` flag, otherwise the Dockerfile uses the default upstream image." The Dockerfile "must be in the same parent directory as the catalog directory":
  ```
  .
  ├── <catalog_dir>
  └── <catalog_dir>.Dockerfile
  ```
  — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- The same note appears per version in the opm CLI reference: "To build with the official Red Hat image, use the `registry.redhat.io/openshift4/ose-operator-registry-rhel9:v4.18` value with the `-i` flag." (4.18), `...:v4.20` (4.20), `...:v4.21` (4.21) — [RH-CLI-4.18 §8.2.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/cli_tools/index), [RH-CLI-4.20](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/cli_tools/index), [RH-CLI-4.21](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/cli_tools/index)
- Generated Dockerfile template (from source): builder stage `FROM {{.BuilderImage}} as builder`, `ADD {{.IndexDir}} /configs`, `RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]`; final stage `FROM {{.BaseImage}}`, and only for non-`scratch` base images `ENTRYPOINT ["/bin/opm"]` + `CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]`; `COPY --from=builder /configs /configs`; `COPY --from=builder /tmp/cache /tmp/cache`; `LABEL` with `containertools.ConfigsLocationLabel=/configs` plus optional extra labels; `BaseImage`, `BuilderImage`, `IndexDir` are required — [operator-registry alpha/action/generate_dockerfile.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/action/generate_dockerfile.go)
- Build and push (Red Hat, verbatim): `$ podman build . -f <catalog_dir>.Dockerfile -t <registry>/<namespace>/<catalog_image_name>:<tag>`; `$ podman login <registry>`; `$ podman push <registry>/<namespace>/<catalog_image_name>:<tag>` — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Composite catalog script example (Red Hat, verbatim excerpt): `opm render "$image" > "$file"` per package subdirectory, then `opm generate dockerfile "$name"`, `docker build -t "$indexImage" -f "$name.Dockerfile" .`, `docker push "$indexImage"` — [RH-EXT-4.20 §4.1.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**opm serve and the cache**

- `serve <source_path>`: "This command serves declarative configs via a GRPC server. NOTE: The declarative config directory is loaded by the serve command at startup. Changes made to the declarative config after the this command starts will not be reflected in the served content."; flags: `--debug`, `--termination-log/-t` (default `/dev/termination-log`), `--port/-p` (default `50051`), `--pprof-addr` (default `localhost:6060`), `--pprof-capture-profiles`, `--cache-dir` ("Sync and persist server cache directory if set"), `--cache-only` ("Sync cache and exit without serving"), `--cache-enforce-integrity` ("Exit with error if cache missing/invalidated"; defaults true when `--cache-dir` set and `--cache-only` false, otherwise false) — [operator-registry cmd/opm/serve/serve.go](https://github.com/operator-framework/operator-registry/blob/master/cmd/opm/serve/serve.go)
- Red Hat reference table repeats: `--cache-enforce-integrity` "Exits with an error if the cache is not present or is invalidated. The default value is true when the `--cache-dir` flag is set and the `--cache-only` flag is false. Otherwise, the default is false." — [RH-CLI-4.20 §8.2 Table 8.13](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/cli_tools/index)
- catalogd does not run `opm serve`; it extracts only the labelled directory from the image (see Q3) and "Unpacks file-based catalog (FBC) content and hosts metadata so users can discover installable extensions." — [RH-EXT-4.20 §2.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index); [operator-controller cache.go](https://github.com/operator-framework/operator-controller/blob/main/internal/shared/util/image/cache.go)

**Versions**

- operator-registry releases listed on 2026-10-10: `v2.0.0-alpha-1` (Sept 3; "BREAKING CHANGE: drop all sqlite support"), `v1.74.0` (Sept 1), `v1.73.0` (July 23), `v1.72.0` (June 11), `v1.71.0`, `v1.70.0`, `v1.69.0`, `v1.68.0`, `v1.67.0`, `v1.66.0` — [operator-registry releases](https://github.com/operator-framework/operator-registry/releases)
- Red Hat: "The `opm` subcommands, flags, and functionality related to the SQLite database format are also deprecated and will be removed in a future release." and "Many of the `opm` subcommands and flags for working with the SQLite database format, such as `opm index prune`, do not work with the file-based catalog format." — [RH-EXT-4.20 §4.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat's opm CLI reference chapters for 4.18/4.20/4.21 do not document `opm alpha`, `render-template`, or `--migrate-level` (zero matches in the downloaded books) — [RH-CLI-4.18/4.20/4.21 ch. 8](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/cli_tools/index)

### Inferences
- End-to-end, single-package recipe (assembled from the cited Red Hat 4.20 procedure plus upstream flags):
  ```
  mkdir wao-catalog
  opm generate dockerfile wao-catalog -i registry.redhat.io/openshift4/ose-operator-registry-rhel9:v4.20   # or omit -i for quay.io/operator-framework/opm:latest
  opm init workload-availability-operator --default-channel=stable --description=./README.md --icon=./icon.svg --output yaml > wao-catalog/index.yaml
  opm render quay.io/<org>/wao-bundle@sha256:<digest> --output yaml --migrate-level bundle-object-to-csv-metadata >> wao-catalog/index.yaml
  cat >> wao-catalog/index.yaml <<'EOF'
  ---
  schema: olm.channel
  package: workload-availability-operator
  name: stable
  entries:
    - name: workload-availability-operator.v0.1.0
  EOF
  opm validate wao-catalog && echo $?
  podman build . -f wao-catalog.Dockerfile -t quay.io/<org>/wao-catalog:v0.1.0
  podman push quay.io/<org>/wao-catalog:v0.1.0
  ```
  Alternatively put the bundle image(s) into an `olm.semver` template and run `opm alpha render-template semver -o yaml wao.semver.yaml > wao-catalog/index.yaml` to get `candidate-v0.1`/`stable-v0.1` style channels generated with `skips`/`replaces` edges.
- The `RUN opm serve --cache-only` layer in the generated Dockerfile is only consumed by the gRPC `opm serve` entrypoint (OLM v0 CatalogSource pods); catalogd ignores `/tmp/cache`. Keeping the standard Dockerfile keeps the same image usable by both OLM v0 `CatalogSource` and OLM v1 `ClusterCatalog`.
- Red Hat's base-image note ties the opm *image* to the cluster minor version (`ose-operator-registry-rhel9:v4.x`), but no doc states the embedded opm version per OpenShift release.

### Gaps
- No primary source maps opm release numbers to OpenShift 4.18–4.21 (the Red Hat docs only prescribe the `ose-operator-registry-rhel9:v4.x` image tag; `opm version` output per release is not documented). Treat the base-image tag as the compatibility contract.
- Upstream's catalog-templates page documents `--skip-tls-verify`/`--use-http` but I could not fetch the `cmd/opm/alpha/template/basic.go` source (404) to confirm whether `--migrate-level` is also accepted on `render-template`.
- The `opm alpha convert-template` subcommand exists in the alpha command tree but its usage text was not fetched.

---

## Key question 3: Catalog image layout (Dockerfile, `/configs`, labels, scratch images, multi-arch)

### Takeaway
catalogd reads the image config label `operators.operatorframework.io.index.configs.v1` and extracts only that directory; the label is mandatory (its absence is an error) while the opm binary, entrypoint and cache are not needed, so a `FROM scratch` image containing just `/configs` plus the label is sufficient for OLM v1.

### Cited Findings
- Label constant (verbatim): `const ConfigDirLabel = "operators.operatorframework.io.index.configs.v1"`; read via `dirToUnpack, ok := image.Config.Labels[ConfigDirLabel]`; when absent an error is returned, and "If the spec is a tagged keep, retries could end up resolving a new digest, where the label might show up. If the spec is canonical, no amount of retries will make the label appear." (canonical/digest refs make the error terminal); extraction applies `allFilters(onlyPath(dirToUnpack), forceOwnershipRWX())`, i.e. only the labelled directory is unpacked — [operator-controller internal/shared/util/image/cache.go](https://github.com/operator-framework/operator-controller/blob/main/internal/shared/util/image/cache.go)
- operator-controller's own e2e test catalog Dockerfile uses `LABEL operators.operatorframework.io.index.configs.v1=/configs` (`test/extension-developer-e2e/setup.sh`) and the test catalog builder sets `"operators.operatorframework.io.index.configs.v1": "/configs"` (`test/internal/catalog/catalog.go`) — [operator-controller repo](https://github.com/operator-framework/operator-controller)
- The upstream Dockerfile template emits `LABEL` with `containertools.ConfigsLocationLabel=/configs` and omits `ENTRYPOINT`/`CMD` when the base image is `scratch`; `/configs` and `/tmp/cache` are copied from the builder stage — [operator-registry alpha/action/generate_dockerfile.go](https://github.com/operator-framework/operator-registry/blob/master/alpha/action/generate_dockerfile.go)
- Red Hat: "Specify the official Red Hat base image by using the `-i` flag, otherwise the Dockerfile uses the default upstream image." — [RH-EXT-4.20 §4.5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat catalog tagging guidance: "Build and push the catalog image. Use a consistent tagging taxonomy, such as `:latest` or `:<target_cluster_version>`, so that users can receive updates to a catalog as they become available." — [RH-EXT-4.20 §4.1.6.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- catalogd: "Currently, catalogd unpacks catalog content that is packaged and distributed as container images." — [RH-EXT-4.20 §4.3.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- ClusterCatalog `source.type` only supports `Image` ("Enum: Image") — [operator-controller API reference](https://operator-framework.github.io/operator-controller/api-reference/olmv1-api-reference/)

### Inferences
- A minimal OLM v1-only catalog Dockerfile is therefore:
  ```
  FROM scratch
  ADD catalog /configs
  LABEL operators.operatorframework.io.index.configs.v1=/configs
  ```
  (This is exactly what `opm generate dockerfile -i scratch` produces minus the builder/cache stage.) Using the `ose-operator-registry-rhel9` base instead keeps the image usable by OLM v0 `CatalogSource` on the same cluster.
- Because catalogd only reads the image config label and one directory, a catalog image contains no architecture-specific content; the only arch-sensitive bytes are the `opm` binary in a non-scratch base. A scratch-based FBC image is inherently arch-neutral; an opm-based one must be built as a manifest list if OLM v0 CatalogSource pods will run it on multiple node architectures.

### Gaps
- No Red Hat or upstream OLM v1 document explicitly discusses multi-arch catalog images or scratch-based catalogs for catalogd; the scratch conclusion is inferred from the Dockerfile template and catalogd's extraction code.
- Whether catalogd honours an image *index* (manifest list) by selecting the node platform or any platform was not confirmed from source.

---

## Key question 4: ClusterCatalog API (spec/status/labels) and how to inspect catalog contents on the cluster

### Takeaway
`ClusterCatalog` (`olm.operatorframework.io/v1`, cluster-scoped) takes an `Image` source with `ref` (tag or digest) and optional `pollIntervalMinutes` (forbidden with digests), plus `priority` and `availabilityMode`; status exposes `Serving`/`Progressing` conditions, `resolvedSource.image.ref` (digest) and `urls.base`. Upstream documents the catalogd HTTPS API (`/api/v1/all` and the filtered `/api/v1/metas`), while Red Hat 4.18–4.21 docs state you "cannot query on-cluster catalogs managed by catalogd" and instead document `opm render <index> | jq`.

### Cited Findings

**Spec**

- `source` "is a required field that defines the source of a catalog"; `source.type` required, "Enum: Image"; `source.image.ref` required, max 1000 chars, format domain/name with tag (`:`) or digest (`@sha256:...`), examples `quay.io/operatorhubio/catalog:latest` or digest-based; `source.image.pollIntervalMinutes` optional, "sets the interval, in minutes, at which the image source is polled", minimum 1, "Cannot use with digest-based refs"; `priority` optional default 0, range -2147483648..2147483647, "Clients use the priority as a tie-breaker"; `availabilityMode` optional default `Available`, enum `Available`/`Unavailable`, "When set to "Unavailable", the catalog contents are no longer served over the catalog content HTTP server." — [operator-controller API reference](https://operator-framework.github.io/operator-controller/api-reference/olmv1-api-reference/)
- Source-level validation: `ref` tag must start with a word character, max 127 chars; digest `algorithm:hex` with at least 32 hex chars; `image` "Required when type is Image; forbidden otherwise" — [operator-controller api/v1/clustercatalog_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clustercatalog_types.go)
- Label constant: `MetadataNameLabel = "olm.operatorframework.io/metadata.name"` — [clustercatalog_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clustercatalog_types.go); Red Hat: "The catalog is automatically labeled with the value of the `metadata.name` field when it is applied to the cluster." — [RH-EXT-4.20 §4.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Upstream sample (verbatim):
  ```yaml
  apiVersion: olm.operatorframework.io/v1
  kind: ClusterCatalog
  metadata:
    name: operatorhubio
  spec:
    source:
      type: Image
      image:
        ref: quay.io/operatorhubio/catalog:latest
        pollIntervalMinutes: 10
  ```
  and `kubectl wait --for=condition=Serving=True clustercatalog/operatorhubio --timeout=60s` — [operator-controller getting started](https://operator-framework.github.io/operator-controller/getting-started/olmv1_getting_started/)

**Status**

- Conditions: `Serving` "represents whether the catalog contents are being served via the HTTP(S) web server" with reasons `Available` (True), `Unavailable` (False), `UserSpecifiedUnavailable` (False); `Progressing` "represents whether the ClusterCatalog is progressing or is ready to progress" with reasons `Retrying` (True), `Succeeded` (True), `Blocked` (False, "error requiring manual intervention"); `resolvedSource`; `urls.base` "cluster-internal URL that provides endpoints for accessing the catalog content" ("Append path `/api/v1` for endpoints", "`/all` endpoint returns entire catalog in FBC format"); `lastUnpacked` "represents the last time the catalog contents were extracted from their source format" — [operator-controller API reference](https://operator-framework.github.io/operator-controller/api-reference/olmv1-api-reference/); constants `TypeServing = "Serving"`, `ReasonAvailable`, `ReasonUnavailable`, `ReasonUserSpecifiedUnavailable` — [clustercatalog_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clustercatalog_types.go)
- Finalizer `olm.operatorframework.io/delete-server-cache` is set on every catalog — [operator-controller add-catalog tutorial](https://operator-framework.github.io/operator-controller/tutorials/add-catalog/); [RH-EXT-4.20 §4.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat `oc get clustercatalog` output columns (verbatim): `NAME  LASTUNPACKED  SERVING  AGE` — [RH-EXT-4.20 §4.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat `oc describe clustercatalog my-redhat-operators` (verbatim excerpt): `Labels: olm.operatorframework.io/metadata.name=my-redhat-operators` … `Finalizers: olm.operatorframework.io/delete-server-cache` … `Status: Conditions: … Message: Successfully unpacked and stored content from resolved source / Reason: Succeeded / Status: True / Type: Progressing` and `Message: Serving desired content from resolved source / Reason: Available / Status: True / Type: Serving` … `Resolved Source: Image: Ref: registry.redhat.io/redhat/community-operator-index@sha256:11627ea6…` … `Urls: Base: https://catalogd-service.openshift-catalogd.svc/catalogs/my-redhat-operators` — [RH-EXT-4.20 §4.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index) (identical in 4.21)

**catalogd HTTP API (upstream)**

- "Responses are encoded as a JSON Lines stream of File-Based Catalog (FBC) Meta objects delimited by newlines", content type `application/jsonl`; methods GET and HEAD; gzip on `Accept-Encoding: gzip` only when the body > 1400 bytes; `Last-Modified` / `If-Modified-Since` supported; example base `https://catalogd-service.olmv1-system.svc/catalogs/operatorhubio/api/v1/all` — [catalogd web server reference](https://operator-framework.github.io/operator-controller/api-reference/catalogd-webserver/)
- `/api/v1/metas` (documented in the draft docs in the repo): "The metas endpoint accepts parameters which are one of the sub-types of the `Meta` definition, following the pattern `/api/v1/metas?<parameter>[&<parameter>...]`. e.g. `schema=<schema_name>&package=<package_name>`, `schema=<schema_name>&name=<name>`, and `package=<package_name>&name=<name>` are all valid parameter combinations. However `schema=<schema_name>&version=<version_string>` is not a valid parameter combination, since version is not a first class FBC meta field."; example `https://catalogd-service.olmv1-system.svc/catalogs/operatorhubio/api/v1/metas?schema=olm.package` — [operator-controller docs/draft/api-reference/catalogd-webserver-metas-endpoint.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/api-reference/catalogd-webserver-metas-endpoint.md); [docs/draft/howto/catalog-queries-metas-endpoint.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/howto/catalog-queries-metas-endpoint.md)
- metas query examples (verbatim): `curl -k 'https://localhost:8443/catalogs/operatorhubio/api/v1/metas?schema=olm.package'`; `...?schema=olm.package&name=<package_name>`; `...?package=<package_name>`; `...?schema=olm.channel&package=<package_name>`; `...?schema=olm.channel&package=zoperator&name=alpha' | jq -s '.[] | .entries | .[] | .name'`; `...?schema=olm.bundle&package=<package_name>`; `...?schema=olm.bundle&name=<bundle_name>' | jq -s '.[] | .properties[] | select(.type=="olm.gvk")'` — [catalog-queries-metas-endpoint.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/howto/catalog-queries-metas-endpoint.md)
- A GraphQL endpoint (`/api/v1/graphql`) is also described in draft docs comparing it with metas — [operator-controller docs/draft/howto/catalog-queries-graphql-endpoint.md](https://github.com/operator-framework/operator-controller/blob/main/docs/draft/howto/catalog-queries-graphql-endpoint.md); operator-controller release notes mention "catalogd graphql shift to file-based cache" — [operator-controller releases](https://github.com/operator-framework/operator-controller/releases)
- Published (non-draft) query how-to: `kubectl -n olmv1-system port-forward svc/catalogd-service 8443:443`; "By default, Catalogd is installed with TLS enabled for the catalog webserver." (`-k` used "for simplicity's sake"); examples: `curl -k https://localhost:8443/catalogs/operatorhubio/api/v1/all | jq -s '.[] | select(.schema == "olm.package") | .name'`; AllNamespaces-without-webhooks filter: `curl -k https://localhost:8443/catalogs/operatorhubio/api/v1/all | jq -cs '[.[] | select(.schema == "olm.bundle" and (.properties[] | select(.type == "olm.csv.metadata").value.installModes[] | select(.type == "AllNamespaces" and .supported == true)) and .spec.webhookdefinitions == null) | .package] | unique[]'`; package metadata: `... | jq -s '.[] | select(.schema == "olm.package") | select(.name == "<package_name>")'` — [catalog queries](https://operator-framework.github.io/operator-controller/howto/catalog-queries/); [explore available content](https://operator-framework.github.io/operator-controller/tutorials/explore-available-content/)

**Inspecting contents on OpenShift (Red Hat docs)**

- "Currently in Operator Lifecycle Manager (OLM) v1, you cannot query on-cluster catalogs managed by catalogd. In OLM v1, you must use the `opm` and `jq` CLI tools to query the catalog registry." Command syntax `$ opm render <catalog_registry_url>:<tag> | <jq_request>`; example `$ opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -cs '[.[] | select(.schema == "olm.bundle" and (.properties[] | select(.type == "olm.csv.metadata").value.installModes[] | select(.type == "AllNamespaces" and .supported == true)) and .spec.webhookdefinitions == null) | .package] | unique[]'`; package metadata `$ opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .schema == "olm.package") | select( .name == "openshift-pipelines-operator-rh")'` — [RH-EXT-4.20 §5.1.2 / §5.1.2.1 "Common catalog queries"](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index) (same statement in 4.21)
- The 4.18, 4.19, 4.20 and 4.21 Extensions books contain zero occurrences of `api/v1/metas` or `port-forward`; the on-cluster service hostname that does appear is `catalogd-service.openshift-catalogd.svc` (in the `oc describe` output) — [RH-EXT-4.18…4.21](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index)
- Red Hat 4.20/4.21 overview: "For OpenShift Container Platform 4.21, documented procedures for OLM v1 are CLI-based only. Alternatively, administrators can create and view related objects in the web console by using normal methods, such as the Import YAML and Search pages. However, the existing Software Catalog and Installed Operators pages do not yet display OLM v1 components." — [RH-EXT-4.21 ch. 1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index)
- OLM v1 highlight: "OLM v1 uses HTTPS encryption for catalogd server responses." — [RH-EXT-4.20 §1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

### Inferences
- On OpenShift the equivalent of the upstream port-forward is `oc -n openshift-catalogd port-forward svc/catalogd-service 8443:443` followed by `curl -k https://localhost:8443/catalogs/<name>/api/v1/all` (service name and namespace taken from the `status.urls.base` value Red Hat prints); this is unsupported by Red Hat docs but is the same catalogd web server. Use `--cacert` with the serving CA instead of `-k` in evidence collection.
- Red Hat's recommended `opm render <index-ref> | jq …` works for any registry-hosted catalog image, including a custom one, and does not need cluster access.
- `oc get clustercatalog -o jsonpath='{.status.resolvedSource.image.ref}'` gives the digest that catalogd actually unpacked, which is what should be recorded in evidence for determinism.

### Gaps
- No Red Hat KCS (access.redhat.com/solutions) article on catalogd/ClusterCatalog surfaced in searches limited to primary sources; none is cited here.
- The `/api/v1/metas` endpoint is documented only in operator-controller *draft* docs; whether it is enabled by default on OpenShift 4.18–4.21 (and whether a feature gate guards it) could not be verified (the `gh` code-search hit the API rate limit before confirming a gate name).
- Red Hat docs contain no `oc`/`kubectl` plugin for browsing OLM v1 catalogs; none was found upstream either.

---

## Key question 5: OpenShift specifics — default Red Hat ClusterCatalogs, adding/disabling catalogs, oc-mirror v2 and disconnected clusters, pull secrets, channel/version structure guidance

### Takeaway
OpenShift 4.18–4.21 ship four default `ClusterCatalog`s (`openshift-redhat-operators` priority -100, `openshift-certified-operators` -200, `openshift-redhat-marketplace` -300, `openshift-community-operators` -400) pointing at `registry.redhat.io/redhat/*-index:v4.x` with `pollIntervalMinutes: 10`; custom catalogs are plain `oc apply` of a `ClusterCatalog`, defaults are disabled with `availabilityMode: Unavailable`, and oc-mirror plugin v2 generates IDMS/ITMS and `ClusterCatalog` resources under `working-dir/cluster-resources` for disconnected clusters.

### Cited Findings

**Default Red Hat catalogs (verbatim, 4.20)**

- Red Hat Operators catalog:
  ```yaml
  apiVersion: olm.operatorframework.io/v1
  kind: ClusterCatalog
  metadata:
    name: openshift-redhat-operators
  spec:
    priority: -100
    source:
      image:
        pollIntervalMinutes: <poll_interval_duration>
        ref: registry.redhat.io/redhat/redhat-operator-index:v4.20
      type: Image
  ```
  "Replace `<poll_interval_duration>` with the interval in minutes for polling the remote registry for newer image digests. To disable polling, do not set the field." — [RH-EXT-4.20 §4.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Certified: `name: openshift-certified-operators`, `priority: -200`, `pollIntervalMinutes: 10`, `ref: registry.redhat.io/redhat/certified-operator-index:v4.20` (the doc's YAML for this one contains a stray `type: image` line above `image:` in addition to `type: Image` — a documentation typo present in 4.18–4.21) — [RH-EXT-4.20 §4.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Marketplace: `name: openshift-redhat-marketplace`, `priority: -300`, `pollIntervalMinutes: 10`, `ref: registry.redhat.io/redhat/redhat-marketplace-index:v4.20` — [RH-EXT-4.20 §4.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Community: `name: openshift-community-operators`, `priority: -400`, `pollIntervalMinutes: 10`, `ref: registry.redhat.io/redhat/community-operator-index:v4.20` — [RH-EXT-4.20 §4.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- The same four definitions appear in 4.18 (`:v4.18`), 4.19 (`:v4.19`) and 4.21 (`:v4.21`), all with `apiVersion: olm.operatorframework.io/v1` and the field name `pollIntervalMinutes` (no `v1alpha1`, no `pollInterval` in any of the four books) — [RH-EXT-4.18](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/extensions/index), [RH-EXT-4.19](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html-single/extensions/index), [RH-EXT-4.21](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index)
- OLM v1 status by release: 4.20 book states "OpenShift Container Platform 4.20 includes components for a next-generation iteration of OLM as a Generally Available (GA) feature, known during this phase as OLM v1." — [RH-EXT-4.20 ch. 1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index); 4.19: SingleNamespace/OwnNamespace Technology Preview; 4.20: SingleNamespace/OwnNamespace and webhooks Technology Preview; 4.21: "As a Technology Preview feature, you can configure an extension to watch a specific namespace." — [RH-EXT-4.19 §5.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html-single/extensions/index), [RH-EXT-4.20 §5.1.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index), [RH-EXT-4.21 §5.2.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/extensions/index)

**Adding / deleting / disabling catalogs**

- Example custom catalog (verbatim):
  ```yaml
  apiVersion: olm.operatorframework.io/v1
  kind: ClusterCatalog
  metadata:
    name: my-redhat-operators
  spec:
    priority: 1000
    source:
      image:
        pollIntervalMinutes: 10
        ref: registry.redhat.io/redhat/community-operator-index:v4.20
      type: Image
  ```
  `$ oc apply -f my-redhat-operators.yaml` → `clustercatalog.olm.operatorframework.io/my-redhat-operators created`; verify with `$ oc get clustercatalog` and `$ oc describe clustercatalog my-redhat-operators` — [RH-EXT-4.20 §4.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Delete: `$ oc delete clustercatalog <catalog_name>` → `clustercatalog.olm.operatorframework.io "my-redhat-operators" deleted` — [RH-EXT-4.20 §4.3.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Disable a default catalog: `$ oc patch clustercatalog openshift-certified-operators -p '{"spec": {"availabilityMode": "Unavailable"}}' --type=merge` — [RH-EXT-4.20 §4.3.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index) (identical in 4.18, 4.19, 4.21)

**Catalog selection (ClusterExtension side)**

- By name label (verbatim):
  ```yaml
  source:
    sourceType: Catalog
    catalog:
      packageName: <example_extension>-operator
      selector:
        matchLabels:
          olm.operatorframework.io/metadata.name: openshift-redhat-operators
  ```
  — [RH-EXT-4.20 §4.4.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- By custom labels: ClusterCatalog with `labels: example.com/support: "true"` selected via `matchLabels: example.com/support: "true"`, or `matchExpressions: - key: example.com/support / operator: In / values: ["production","supported"]`; "If you use both the `matchLabels` and `matchExpressions` fields, the selected catalog must satisfy all specified criteria."; exclusion with `NotIn` / `DoesNotExist` — [RH-EXT-4.20 §4.4.2–4.4.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index); upstream equivalents at [controlling catalog selection](https://operator-framework.github.io/operator-controller/concepts/controlling-catalog-selection/)
- Priority: "If unspecified, catalogs have a default priority value of 0. The priority can be any positive or negative 32-bit integer."; "During bundle resolution, catalogs with higher priority values are selected over catalogs with lower priority values."; "Bundles that are not deprecated are prioritized over bundles that are deprecated."; "If multiple bundles exist in catalogs with the same priority and the catalog selection is ambiguous, an error is printed." — [RH-EXT-4.20 §4.4.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**Disconnected / oc-mirror v2**

- "Depending on your oc-mirror plugin version, OLM v1 uses one of the following resource sets: oc-mirror plugin v1 — Automatically generates `ImageContentSourcePolicy` resources and requires manually created `ClusterCatalog` resources. oc-mirror plugin v2 — Automatically generates `ImageDigestMirrorSet`, `ImageTagMirrorSet`, and `ClusterCatalog` resources." / "The oc-mirror plugin v2 is the recommended version for mirroring." — [RH-EXT-4.20 §4.6.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Generated resources: IDMS ("Generated if at least one image of the image set is mirrored by digest"), ITMS ("…mirrored by tag"), CatalogSource ("Used by Operator Lifecycle Manager (OLM) Classic"), ClusterCatalog ("Retrieves information about the available cluster extensions (which includes Operators) in the mirror registry. Used by OLM v1."), UpdateService — [RH-DISC-4.20 §5.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index)
- Fields that must not be modified in generated resources: ClusterCatalog `apiVersion`, `kind`, `spec.source.image.ref` — [RH-DISC-4.20 §5.5.1, Table 5.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index)
- Apply: `$ oc apply -f <path_to_oc_mirror_workspace>/working-dir/cluster-resources`; verify `$ oc get clustercatalog` and `$ oc get clustercatalog -o jsonpath='{.items[?(@.metadata.annotations.createdBy=="oc-mirror v2")].metadata.name}'` — [RH-DISC-4.20 §5.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index)
- "All custom resources to be applied to the disconnected cluster are generated in the `<workspace_path>/working-dir/cluster-resources` directory" (lists IDMS, ITMS, CatalogSource, ClusterCatalog, UpdateService) — [RH-DISC-4.20 "Migrating to oc-mirror plugin v2"](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index)
- Example ImageSetConfiguration (verbatim excerpt):
  ```yaml
  kind: ImageSetConfiguration
  apiVersion: mirror.openshift.io/v2alpha1
  mirror:
    platform:
      channels:
      - name: stable-4.20
        minVersion: 4.20.2
        maxVersion: 4.20.2
      graph: true
    operators:
      - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20
        packages:
         - name: aws-load-balancer-operator
         - name: 3scale-operator
         - name: node-observability-operator
    additionalImages:
     - name: registry.redhat.io/ubi8/ubi:latest
  ```
  "In oc-mirror plugin v2, you must use explicit registry hostnames for all images listed under `additionalImages`." Local OCI catalogs are referenced as `catalog: oci:///test/redhat-operator-index` — [RH-DISC-4.20 §5.4](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index)
- Dry run: `$ oc mirror -c <image_set_config_yaml> file://<oc_mirror_workspace_path> --dry-run --v2` — [RH-DISC-4.20 §5.7.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/disconnected_environments/index)
- Red Hat's "Updating or filtering a file-based catalog image" note: "if you already have a catalog image on a mirror registry, you can use the oc-mirror CLI plugin to automatically prune any removed images from an updated source version of that catalog image while mirroring it to the target registry." — [RH-EXT-4.20 §4.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

**Channel/version structuring guidance from Red Hat**

- Immutable bundles: "If a broken bundle has been pushed to a catalog, you must assume that at least one of your users has upgraded to that bundle. Based on that assumption, you must release another bundle with an upgrade path from the broken bundle … OLM will not reinstall an installed bundle if the contents of that bundle are updated in the catalog." Allowed metadata changes: "Channel promotion: … add an entry for your bundle in another `olm.channel` blob." and "New upgrade paths: If you release a new 1.2.z bundle version, for example 1.2.4, but 1.3.0 is already released, you can update the catalog metadata for 1.3.0 to skip 1.2.4." — [RH-EXT-4.20 §4.1.6.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Source control: "Catalog metadata should be stored in source control and treated as the source of truth." — [RH-EXT-4.20 §4.1.6.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- "After a bundle has been published in a catalog, assume that one of your users has installed it. Ensure that all previously published bundles in a catalog have an update path to the current or newer channel head to avoid stranding users that have that version installed." — [RH-EXT-4.20 §4.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- skipRange warning: "When using the `skipRange` field, the skipped Operator versions are pruned from the update graph and are longer installable by users with the `spec.startingCSV` property of `Subscription` objects. You can update an Operator incrementally while keeping previously installed versions available to users for future installation by using both the `skipRange` and `replaces` field. Ensure that the `replaces` field points to the immediate previous version of the Operator version in question." — [RH-EXT-4.20 §4.1.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Red Hat's example of a real channel block (verbatim):
  ```yaml
  entries:
  - name: example-operator.v2.7.0
    skipRange: '>=2.6.0 <2.7.0'
  - name: example-operator.v2.7.1
    replaces: example-operator.v2.7.0
    skipRange: '>=2.6.0 <2.7.1'
  - name: example-operator.v2.7.2
    replaces: example-operator.v2.7.1
  ```
  with `defaultChannel: release-2.7` — [RH-EXT-4.20 §4.5.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Automation: catalog maintainers should "Check that the catalog updates pass the `opm validate` command." and "Check that the updated bundle or catalog image references exist, the catalog images run successfully in a cluster, and Operators from that package can be successfully installed." — [RH-EXT-4.20 §4.1.8](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)

### Inferences
- A custom catalog added by `oc apply` with no `priority` gets 0, which already outranks all four Red Hat defaults (-100…-400); Red Hat's own example uses `priority: 1000`. This matters if the custom catalog's package name collides with one in a default catalog.
- For a disconnected WAO install the supported path is: put the custom catalog image in the ImageSetConfiguration `operators[].catalog` (registry or `oci://` path), run oc-mirror v2, then `oc apply -f working-dir/cluster-resources` — do not hand-edit the generated `ClusterCatalog.spec.source.image.ref`.
- Red Hat's channel conventions in the OLM v1 books are inherited verbatim from the OLM v0 FBC chapter (`release-2.7` channel names, `replaces` + `skipRange`), so a WAO catalog that follows those conventions will be valid for both OLM v0 and v1.

### Gaps
- Pull secrets for private catalog registries: a search snippet (from an OKD "Managing catalogs" page) says "you must have a pull secret scoped to the `openshift-catalogd` namespace, and catalogd can read references to secrets only in the namespace where it is deployed", but that paragraph is not present in the current 4.20/4.21 Red Hat or OKD 4.20 catalog chapters I downloaded (zero matches for "secret"). I could not cite a current primary source for how OpenShift's catalogd authenticates to `registry.redhat.io` (global pull secret vs. namespace secret), so treat as unverified.
- oc-mirror v2 ClusterCatalog file naming (e.g. `cc-*.yaml`) is not documented in the 4.20 Disconnected book (zero matches); only the directory `working-dir/cluster-resources` is.
- No Red Hat document specifically about "structuring channels for OLM v1" exists beyond the shared FBC guidelines quoted above.

---

## Key question 6: Upgrade-graph best practices for OLM v1 (replaces/skips/skipRange vs semver, CatalogProvided evaluation, pitfalls) and testing a catalog locally

### Takeaway
With the default `upgradeConstraintPolicy: CatalogProvided`, OLM v1 honours `replaces`/`skips`/`skipRange` but has no replaces *chain*: any channel entry whose `replaces`, `skips` or `skipRange` covers the installed version is a successor and the highest semver successor wins; `SelfCertified` ignores the graph entirely. Bundle versions must be valid semver (needed for `olm.package`, version ranges and the semver template), and a kind cluster with `install.sh` from operator-controller releases is the documented local test loop.

### Cited Findings
- Upstream upgrade semantics: OLM v1 honours `replaces`, `skips`, `skipRange`; "when multiple successors exist … legacy OLM selects the version closest to the channel head, while 'OLM v1 detects the upgrade edge because OLM v1 does not have a concept of a `replaces` chain' and instead chooses the highest semantic version"; `CatalogProvided` (default) "Only allows the next version to come from the successors list."; `SelfCertified` "Does not limit the next version to the set of successors, and instead allows for any downgrade, sidegrade, or upgrade." — [operator-controller upgrade support](https://operator-framework.github.io/operator-controller/concepts/upgrade-support/)
- Red Hat 4.20 §5.3 "Update paths" (verbatim): "Operator Lifecycle Manager (OLM) v1 supports OLM (Classic) semantics for update paths, also known as upgrade edges or upgrade constraints. Support includes `replaces`, `skips`, and `skipRange` directives, with a few noted differences." Differences: "In OLM (Classic), the successor closest to the channel head is chosen. In OLM v1, the successor with the highest semantic version (semver) is chosen." Example:
  ```yaml
  # ...
  - name: example.v3.0.0
    skips: ["example.v2.0.0"]
  - name: example.v2.0.0
    skipRange: >=1.0.0 <2.0.0
  ```
  "If 1.0.0 is installed … OLM (Classic) will not detect an update path to v2.0.0 because v2.0.0 is skipped and not on the replaces chain. OLM v1 will detect the update path because OLM v1 does not have a concept of a replaces chain. OLM v1 finds all entries that have a replace, skip, or skipRange value that covers the currently installed version." — [RH-EXT-4.20 §5.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- `upgradeConstraintPolicy` doc: "optional and controls whether the upgrade paths defined in the catalog are enforced. Allowed values: 'CatalogProvided' (default) or 'SelfCertified'." — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go); Red Hat: "The `CatalogProvided` setting only updates if the new version satisfies the upgrade constraints set by the package author. To force an update or rollback, set the field to `SelfCertified`." — [RH-EXT-4.20 §5.1.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- SelfCertified example (verbatim):
  ```yaml
  apiVersion: olm.operatorframework.io/v1
  kind: ClusterExtension
  metadata:
    name: extension-sample
  spec:
    source:
      sourceType: Catalog
      catalog:
        packageName: argocd-operator
        version: 0.6.0
        upgradeConstraintPolicy: SelfCertified
  ```
  — [upgrade support](https://operator-framework.github.io/operator-controller/concepts/upgrade-support/)
- Major-version-zero caveat: "You cannot automatically upgrade from one patch version to another when both major and minor versions are `0`" (e.g. `0.0.1` → `0.0.2`), while `0.1.0` → `0.1.5` is allowed; "Manual verification is required for blocked upgrades." — [upgrade support](https://operator-framework.github.io/operator-controller/concepts/upgrade-support/)
- `version` field: "optional semver constraint (a specific version or range of versions). When unspecified, the latest version available is installed" (max 64 chars); `channels`: "optional and specifies a set of channels belonging to the package … A channel is a package-author-defined stream of updates" (max 256) — [clusterextension_types.go](https://github.com/operator-framework/operator-controller/blob/main/api/v1/clusterextension_types.go)
- Version range syntax: operators `=`, `!=`, `>`, `<`, `>=`, `<=`; range `version: ">=3.0, <3.6"`; wildcards `1.2.x` = `>= 1.2.0, < 1.3.0`, `>= 1.2.x` = `>= 1.2.0`, `<= 2.x` = `< 3`, `*` = `>= 0.0.0`; tilde `~1.2.3` = `>= 1.2.3, < 1.3.0`, `~1` = `>= 1, <2`, `~2.3` = `>= 2.3, < 2.4`; caret `^1.2.3` = `>= 1.2.3, < 2.0.0`, `^0.2.3` = `>=0.2.3 <0.3.0`, `^0.0.3` = `>=0.0.3 <0.0.4`; OR via `||` — [operator-controller version ranges](https://operator-framework.github.io/operator-controller/concepts/version-ranges/); Red Hat tables 5.4–5.6 give the same operators, wildcards (`1.11.x` → `>=1.11.0, <1.12.0`, `>=1.12.X` → `>=1.12.0`, `<=2.x` → `<3`, `*` → `>=0.0.0`) and tilde examples — [RH-EXT-4.20 §5.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Z-stream pinning how-to: `version: "~2.3"` ("Automatically upgrade patch releases for v2.3") — [z-stream upgrades](https://operator-framework.github.io/operator-controller/howto/how-to-z-stream-upgrades/)
- Channel-based how-to: `channels: [dev-preview, preview]`; combining `channels: [stable]` with `version: "!=1.3.2"`; the system upgrades to "the latest version found in" the chosen channels — [channel-based upgrades](https://operator-framework.github.io/operator-controller/howto/how-to-channel-based-upgrades/)
- Red Hat ClusterExtension example with `version: "1.14.x"` and `channels` documented as "channel names as an array, such as `pipelines-1.14` or `latest`"; `version` "such as `1.14.0`, `1.14.x`, or `>=1.16`" — [RH-EXT-4.20 §5.1.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Semver requirement on bundles: `olm.package.value.version` "must be a valid semantic version" (Red Hat) / "required, valid semver" (upstream); semver template requires `csv.spec.version` and fails fatally if two bundles differ only by build metadata — [RH-EXT-4.20 §4.1.4.1](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index); [OLM-FBC](https://olm.operatorframework.io/docs/reference/file-based-catalogs/); [OLM-TPL](https://olm.operatorframework.io/docs/reference/catalog-templates/)
- operator-controller v1.5.0 release note: "Add support for build metadata precedence in bundle version comparison" — [operator-controller releases](https://github.com/operator-framework/operator-controller/releases)
- Channel invariants enforced by the schema/validate: one head per channel, each bundle at most once per channel — [RH-EXT-4.20 §4.1.3.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Catalog digest pinning: `pollIntervalMinutes` "Cannot use with digest-based refs" and `status.resolvedSource.image.ref` reports the digest actually unpacked — [operator-controller API reference](https://operator-framework.github.io/operator-controller/api-reference/olmv1-api-reference/); [RH-EXT-4.20 §4.3.3](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/extensions/index)
- Local testing, upstream: `curl -L -s https://github.com/operator-framework/operator-controller/releases/latest/download/install.sh | bash -s` ("Operator-Controller depends on cert-manager. Running the following command may affect an existing installation of cert-manager and cause cluster instability."); then apply the ClusterCatalog and `kubectl wait --for=condition=Serving=True clustercatalog/operatorhubio --timeout=60s`; sample extension `kubectl apply -f https://raw.githubusercontent.com/operator-framework/operator-controller/main/config/samples/olm_v1_clusterextension.yaml`; upgrade via `kubectl patch clusterextension argocd --type='merge' -p '{"spec": {"source": {"catalog": {"version": "0.11.0"}}}}'` — [getting started](https://operator-framework.github.io/operator-controller/getting-started/olmv1_getting_started/)
- From source: `make run` "builds a local container image, creates a new KIND cluster, and deploys the operator-controller along with catalogd and cert-manager dependencies"; `make docker-build docker-push IMG=<some-registry>/operator-controller:tag`, `make deploy IMG=…`, `kubectl apply -f config/samples/`, `tilt up` (`DOCKER_BUILDKIT=0 tilt up` for Podman) — [operator-controller developer guide](https://operator-framework.github.io/operator-controller/contribute/developer/)
- Latest operator-controller release listed on 2026-10-10: `v1.12.0` (then v1.11.0, v1.10.0, v1.9.0 …); v1.11.0 "Deprecate ClusterExtension spec.serviceAccount"; v1.9.0 "Add feature gate for registry+v1 bundle deploymentConfig"; v1.6.0 "move to a helm-based configuration" — [operator-controller releases](https://github.com/operator-framework/operator-controller/releases)

### Inferences
- Practical graph rules for an OLM v1-first catalog: (1) every bundle version is strict semver with no build-metadata-only duplicates; (2) one channel head; (3) for each new version add `replaces: <immediately previous>` plus a `skipRange` covering older versions you want to leapfrog (Red Hat's `release-2.7` example), which yields a valid graph for both OLM v0 (replaces chain) and v1 (any covering edge); (4) avoid a `0.0.z` series because OLM v1 will not auto-upgrade between `0.0.x` patches; (5) if you want X.Y channels, the semver template's `GenerateMinorChannels` output (`stable-v0.1`, …) is the ready-made convention.
- "z-stream" behaviour in OLM v1 is a consumer-side concern: users pin with `version: "~X.Y"` or `"X.Y.x"`; the catalog only needs edges that cover the installed version. A single `stable` channel with semver-ordered entries is sufficient for z-stream pinning.
- Determinism: publish the catalog image by tag for polling, but record `status.resolvedSource.image.ref` (digest) in evidence; a digest `ref` makes the ClusterCatalog immutable (polling forbidden) and makes a missing `configs.v1` label a terminal error.
- Local loop: `kind create cluster` → `install.sh` from the operator-controller release → `kind load docker-image <catalog>` or push to a reachable registry → apply `ClusterCatalog` (`pollIntervalMinutes` for iterative rebuilds) → `kubectl wait --for=condition=Serving=True` → port-forward `svc/catalogd-service` in `olmv1-system` and query `/api/v1/all` (or `/metas`) → apply a `ClusterExtension` with `version` pinned.

### Gaps
- No primary source documents `kind load docker-image` for catalogs specifically; the developer page only states that `make run` creates the kind cluster. The kind-based loop above is an inference.
- The exact per-release feature-gate list for the `/api/v1/metas` and GraphQL endpoints, and whether OpenShift 4.18–4.21 ship them enabled, was not found in Red Hat docs.
- I found no Red Hat statement on handling pre-release suffixes (`-rc1`) in OLM v1 version resolution; the only prerelease-related upstream text is the semver template's `skipRange` example using `-0` bounds.
