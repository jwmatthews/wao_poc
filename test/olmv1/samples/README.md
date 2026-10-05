# exp0001 admission-webhook samples

Dry-run inputs for the OLM v1 experiment that installs the six medik8s / RHWA operators (NHC, SNR,
FAR, MDR, NMO, SBR) and exercises every admission webhook verb with
`oc create|apply|delete --dry-run=server`. `matrix.yaml` is the expectation table; this file
records how each sample was derived and the caveats. Nothing here was run against a cluster.

Target versions: NHC 0.12.x, SNR 0.13.x, FAR 0.8.x, MDR 0.7.x, NMO 5.7.x (upstream 0.21), SBR 0.3.x.
Source was read at upstream `main` in `RHWA_private/scratch_space/<repo>`; for every validator the
diff from the shipped tag (`v0.12.0`, `v0.13.0`, `v0.8.0`, `v0.21.0`, `v0.7.0`, `v0.3.0`) to HEAD
was checked and is refactor-only (controller-runtime generic `admission.Validator[T]`; FAR split one
`CustomValidator` into `FARValidator` + `FARTemplateValidator` with identical checks). The error
strings and checks below therefore apply to the shipped versions. Line numbers cite HEAD.

## Conventions

* Namespaced samples live in `openshift-workload-availability`. SNR's config webhook compares the
  namespace against the manager's `DEPLOYMENT_NAMESPACE` env (CSV fieldRef `metadata.namespace`), so if
  the operators are installed elsewhere, edit the `snrconfig-*.yaml` namespace too.
* Every name is prefixed `exp0001-` except the SNR config, whose name is forced by the webhook.
* `*-valid.yaml` and `*-invalid.yaml` of a CRD share `metadata.name` so that
  `oc apply --dry-run=server -f <invalid>` is an UPDATE of the valid object.
* Remediation CRs (`snr-*.yaml`, `far-*.yaml`, `mdr-*.yaml`) and `nm-*.yaml`, `sbrconfig-*.yaml`
  are **dry-run only**. They target `exp0001-no-such-node`, which does not exist, so even a real create
  could not act, but do not create them. Rows that would need them to exist are `expected: skip`.
* Templates (`snrtemplate`, `fartemplate`, `mdrtemplate`) and `nhc-valid.yaml` (selector matches no
  node) are inert and may be created for real to enable the UPDATE/DELETE rows.
* UPDATE uses `oc apply --dry-run=server`, not `oc replace`: CRDs do not allow unconditional updates,
  so a `replace` without `metadata.resourceVersion` is refused by storage before admission runs. Apply
  on a missing object silently becomes a CREATE; verify existence first.
* A webhook rejection reads `admission webhook "<name>" denied the request: <substring>`. Schema
  errors (CRD `required`, enum, pattern, CEL, unknown fields) do not carry that prefix; every invalid
  sample for a webhook-bearing CRD was chosen so that the CRD schema accepts it and only the webhook
  can reject it.

## Webhook inventory used

From `RHWA_private/docs/evidence/2026-10-02-audit-webhook-certs.md` section 1 and
`2026-10-02-reverify-findings-at-head.md` Part C (CSV `spec.webhookdefinitions`):

| operator | webhook | type | ops | failurePolicy |
|---|---|---|---|---|
| NHC | vnodehealthcheck.kb.io | Validating | CREATE, UPDATE, DELETE | Fail |
| SNR | mselfnoderemediationtemplate.kb.io | Mutating | CREATE, UPDATE | Fail |
| SNR | vselfnoderemediationtemplate.kb.io | Validating | CREATE, UPDATE | Fail |
| SNR | vselfnoderemediationconfig.kb.io | Validating | CREATE, UPDATE, DELETE | Fail |
| SNR | vselfnoderemediation.kb.io | Validating | CREATE, UPDATE | **Ignore** |
| FAR | mfenceagentsremediation.kb.io | Mutating | CREATE, UPDATE | Fail |
| FAR | vfenceagentsremediation.kb.io | Validating | CREATE, UPDATE | Fail |
| FAR | mfenceagentsremediationtemplate.kb.io | Mutating | CREATE, UPDATE | Fail |
| FAR | vfenceagentsremediationtemplate.kb.io | Validating | CREATE, UPDATE | Fail |
| NMO | vnodemaintenance.kb.io | Validating | CREATE, UPDATE | Fail |
| MDR | none | | | |
| SBR | none registered (vstoragebasedremediationconfig.kb.io exists in source, disabled) | | | |

DELETE is registered only by NHC and SNR config, so those are the only `delete` rows.

## Per-CRD derivation

### NHC `nodehealthchecks` (`nhc-valid.yaml`, `nhc-invalid.yaml`)
Validator: `node-healthcheck-operator/internal/webhook/v1alpha1/nodehealthcheck_webhook.go:100-113`
aggregates `ValidateMinHealthyMaxUnhealthy`, selector, mutual remediation, escalating remediations and
control-plane topology. Invalid trigger: both `minHealthy` and `maxUnhealthy` set, rejected at
`api/v1alpha1/validation.go:33-35` with
`minHealthy and maxUnhealthy cannot be specified at the same time`. The CRD has no CEL rule for it
(bundle CRD has no `x-kubernetes-validations`), and the same probe passes in
`wao_poc/test/cluster/05-enable-nhc.sh:16-34`. The valid sample's `matchLabels` key
`exp0001.example.com/never-matches` selects nothing; the webhook does not check that the referenced
template exists. DELETE is admitted unless remediating (`:92-98`). Caveat: the webhook also rejects
everything with `Unsupported control plane topology` (`:115-120`) when the cluster's
`Infrastructure.status.controlPlaneTopology` is not HighlyAvailable/SingleReplica/Arbiter/External.

### SNR `selfnoderemediationconfigs` (`snrconfig-valid.yaml`, `snrconfig-invalid.yaml`, `snrconfig-invalid-name.yaml`)
Validator: `self-node-remediation/internal/webhook/v1alpha1/selfnoderemediationconfig_webhook.go`.
CREATE runs `validateTimes`, tolerations, node selectors and `validateSingleton` (`:81-93`); UPDATE
omits the singleton check (`:96-106`); DELETE returns a warning
`The default configuration is deleted, Self Node Remediation is now disabled` for the default config
(`:109-120`). Invalid trigger: `apiServerTimeout: 1ms` (CRD only has a duration pattern) rejected at
`:48,:152` with `ApiServerTimeout cannot be less than 10ms`; works for CREATE and UPDATE. The extra
`snrconfig-invalid-name.yaml` reuses `wao_poc/test/cluster/06-enable-snr.sh:35-44` and is rejected
on CREATE only at `:295-296` (`a name other than self-node-remediation-config is not allowed`).
Caveat: SNR creates the default config itself (`api/v1alpha1/selfnoderemediationconfig_types.go:189`),
so a dry-run CREATE of the valid sample is admitted by the webhook and then fails with
`AlreadyExists` from storage; the matrix row documents how to read that.

### SNR `selfnoderemediationtemplates` (`snrtemplate-*.yaml`) and `selfnoderemediations` (`snr-*.yaml`)
The only validating check is `validateStrategy`
(`selfnoderemediationtemplate_webhook.go:88-93`, used by both CRDs): it rejects
`OutOfServiceTaint` only when `utils.IsOutOfServiceTaintSupported` is false, i.e. k8s < 1.26. Any
other strategy value is a CRD enum error (bundle CRDs `selfnoderemediations.yaml:57-61`,
`selfnoderemediationtemplates.yaml:66-70`). **No webhook-level rejection is constructible on the
target cluster**; the `-invalid.yaml` files carry `OutOfServiceTaint` and are expected to be admitted.
Signals instead: the mutating webhook adds
`remediation.medik8s.io/multiple-templates-support: "true"` to templates (`:52-60`; key from
`vendor/github.com/medik8s/common/pkg/annotations/annotations.go:8`), visible in
`--dry-run=server -o yaml` (same as `06-enable-snr.sh:58-59`); for the SNR CR (failurePolicy
Ignore) the only evidence is the manager log line `validate create` from logger
`selfnoderemediation-resource` (`selfnoderemediation_webhook.go:30,47`).

### FAR `fenceagentsremediationtemplates` (`fartemplate-*.yaml`) and `fenceagentsremediations` (`far-*.yaml`)
Validator: `fence-agents-remediation/api/v1alpha1/fenceagentsremediation_params.go`, `validateSpec`
(`:144-152`) = agent name (`:154-166`, `os.Stat` of the agent binary), strategy (`:168-173`),
template syntax (`:176-187`) and `validateFenceAgentForNodes` (`:191-232`), which rejects a spec with
no parameters at all (`invalid spec: mandatory parameters are missing`, `:46,:199-203`) and otherwise
builds parameters for each node named in `nodeparameters`/`nodeSecretNames` (`:234-246`). Sample
shape follows `wao_poc/test/cluster/08-enable-far.sh:28-50`: lower-case CRD keys, `fence_ipmilan`,
one `--ipport` entry for `exp0001-no-such-node`. No secrets are referenced, so no Secret lookups.
Triggers: template uses an unsupported agent (`unsupported fence agent: fence_exp0001_does_not_exist`,
`:163`; CRD pattern is just `fence_.+`); the FAR CR uses `--action: status`
(`FAR doesn't support any other action than \`reboot\` or \`off\``, `:48`, raised `:319-328` via
`:257`). The triggers suggested in the brief do not reach the webhook: a missing `agent` is a CRD
`required` field, and a CR-name/node-name mismatch is not validated (`GetNodeNamesFromSpec` takes
node names from the spec, not from `metadata.name`). Caveat: the mutating webhooks GET the Secret
`fence-agents-credentials-shared` in the namespace (`internal/webhook/v1alpha1/
fenceagentsremediationtemplate_webhook.go:99-126`); if it exists, `sharedSecretName` is defaulted on
CREATE. `08-enable-far.sh:20-26` notes the FAR SA needs cluster-wide Secret list/watch or the
template webhook times out.

### NMO `nodemaintenances` (`nm-valid.yaml`, `nm-invalid.yaml`)
Validator: `node-maintenance-operator/internal/webhook/v1beta1/nodemaintenance_webhook.go`.
CREATE checks node existence (`:78-83,:116-123`), then duplicate NodeMaintenance (`:125-138`), then
etcd quorum via the `openshift-etcd` PDB (`:140-167`). A nonexistent node is rejected with
`invalid nodeName, no node with name <name> found` (`:38,:120`), so the "valid" sample is rejected by
design and that string is the proof of life (same as `wao_poc/test/cluster/10-enable-nmo.sh:20-30`).
The quorum and duplicate checks need a real node name, which is forbidden, so the invalid sample
differs only in node name. UPDATE only rejects `spec.nodeName` changes (`:41,:101-108`) and needs an
existing NodeMaintenance, which can only exist for a real node; those rows are `skip`.

### MDR `machinedeletionremediations`, `machinedeletionremediationtemplates` (controls)
No webhook: CSV has no `spec.webhookdefinitions`, no `config/webhook/`, `cmd/main.go` sets no
webhook server. Spec is empty (`api/v1alpha1/machinedeletionremediation_types.go:33-37`). The
"invalid" controls trip API-server validation only: an unknown field (strict field validation) and a
missing `spec.template` (bundle CRD `required`, `:57-58`). Their error text lacks the
`admission webhook ... denied` prefix, which is the point of the control.

### SBR `storagebasedremediationconfigs` (control)
`api/v1alpha1/storagebasedremediationconfig_webhook.go:31` declares
`vstoragebasedremediationconfig.kb.io`, but `config/default/kustomization.yaml` keeps `../webhook`
commented out and the CSV runs the manager with `--enable-webhooks=false` (CSV line 330;
`cmd/main.go:102` default true). `sbrconfig-invalid.yaml` would fail `ValidateSharedStorageClass`
(`storagebasedremediationconfig_types.go:295`) if the webhook were on; on the shipped bundle both
samples are admitted (`07-enable-sbr.sh:31-34` observed the same). Both carry `detectOnlyMode:
Enabled` and a never-matching `nodeSelector` (fields present in the v0.3.0 CRD) as belt and braces,
but they are still dry-run only. The SBR remediation and template CRDs have no webhook in source
either and are not sampled.

## Where there is no webhook-level rejection
* SNR template and SNR CR: only a k8s<1.26 version gate; admitted on any supported OpenShift.
* SNR CR additionally has `failurePolicy: Ignore`, so admission cannot distinguish a dead webhook.
* NMO: a true admit is not constructible without a real node; the rejection is the signal.
* NMO/FAR CR/SNR CR UPDATE rows: require a persisted object, which policy forbids.
