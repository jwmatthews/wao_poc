package components

// ImageBinding maps an operator image variable to the tagged reference from release-set.yaml
// that the runtime overlay writes into the embedded manifests;
// the renderer replaces Original with the selected pull reference from the image set.
type ImageBinding struct {
	Env      string
	Original string
}

// imageBinding uses the generated release-set reference so tag updates need no manual Go edits.
func imageBinding(env string) ImageBinding {
	original := taggedImageReferences[env]
	if original == "" {
		panic("no generated image binding for " + env + "; run make operand-manifests")
	}
	return ImageBinding{Env: env, Original: original}
}

// WebhookConfiguration names an admission configuration rendered for the component.
type WebhookConfiguration struct {
	Kind string // ValidatingWebhookConfiguration or MutatingWebhookConfiguration
	Name string
}

// ResourceKind identifies a native API kind of a component.
type ResourceKind struct {
	Group, Version, Kind string
}

// Definition describes one operand component.
type Definition struct {
	Key         string // API key, e.g. nodeHealthCheck
	ShortName   string // nhc
	ManifestDir string // directory under internal/operands/manifests
	Deployments []string
	Images      []ImageBinding
	Webhooks    []WebhookConfiguration
	// AgentOwners are config kinds, in the install namespace, whose DaemonSets are node agents
	// that keep running after the manager is removed.
	AgentOwners []ResourceKind
	// ManagedKinds are native kinds the manager reconciles (and may hold finalizers on). Objects
	// of these kinds that exist anywhere in the cluster while the component is Disabled are
	// no longer reconciled and are reported as retained.
	ManagedKinds []ResourceKind
}

// All returns the POC operand set in reconcile order.
func All() []Definition { return []Definition{NHC(), SNR(), SBR(), FAR(), MDR(), NMO()} }

// ByKey finds a definition by API key.
func ByKey(key string) (Definition, bool) {
	for _, d := range All() {
		if d.Key == key {
			return d, true
		}
	}
	return Definition{}, false
}
