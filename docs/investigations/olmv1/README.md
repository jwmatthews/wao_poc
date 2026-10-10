# OLM v1 investigation

Research into what OLM v1 (operator-controller + catalogd) requires of an OpenShift
operator, gathered from primary sources (upstream operator-framework docs and code,
openshift/operator-framework-operator-controller, Red Hat OpenShift 4.18–4.22
documentation and release notes, Red Hat certification docs) on 2026-10-10.

## Start here

- [reports/OLM v1 operator requirements.md](reports/OLM%20v1%20operator%20requirements.md):
  the synthesized guidance for an agent building the FBC, bundle and metadata for
  OLM v1. Ends with a MUST / SHOULD / MAY checklist annotated with WAO's current
  status, and a list of open questions.

## Research notes

Raw per-topic notes behind the report. Each has Takeaway / Cited Findings /
Inferences / Gaps sections and a URL for every fact.

| File | Topic |
| --- | --- |
| [01-olmv1-architecture-and-apis.md](research_notes/OLM%20v1%20operator%20requirements/01-olmv1-architecture-and-apis.md) | ClusterExtension / ClusterCatalog APIs, conditions, resolution, OpenShift version matrix |
| [02-bundle-format-constraints.md](research_notes/OLM%20v1%20operator%20requirements/02-bundle-format-constraints.md) | What a registry+v1 bundle must and must not contain; CRD upgrade safety; single-owner rule |
| [03-fbc-catalog-building.md](research_notes/OLM%20v1%20operator%20requirements/03-fbc-catalog-building.md) | FBC schema, opm commands, catalog image, ClusterCatalog, upgrade graph, mirroring |
| [04-install-rbac-lifecycle-migration.md](research_notes/OLM%20v1%20operator%20requirements/04-install-rbac-lifecycle-migration.md) | Installer ServiceAccount RBAC, install/upgrade/delete semantics, OLM v0 coexistence |
| [05-openshift-best-practices-certification-webhooks.md](research_notes/OLM%20v1%20operator%20requirements/05-openshift-best-practices-certification-webhooks.md) | OpenShift CSV annotations, certification pipelines, PSA/FIPS/proxy, webhook cert provisioning |
| [06-developer-workflow-testing-troubleshooting.md](research_notes/OLM%20v1%20operator%20requirements/06-developer-workflow-testing-troubleshooting.md) | kind + operator-controller loop, tool versions, feature gates, verification, error messages |
| [07-live-cluster-ocp-5.0-rc5.md](research_notes/OLM%20v1%20operator%20requirements/07-live-cluster-ocp-5.0-rc5.md) | Read-only inspection of the OCP 5.0 rc5 test cluster (2026-10-10): build, gates, ClusterExtension schema, serviceAccount deprecation warning, catalogd API, Classic coexistence; maps the report's open questions to resolved / still open |

## Things to re-verify on a live cluster

See the "Open questions and gaps" section of the report. The largest unknown is
which OpenShift release adopts the upstream deprecation of
`ClusterExtension.spec.serviceAccount` (upstream v1.11.0, July 2026); every
shipped OpenShift release through 4.22 still requires it.
