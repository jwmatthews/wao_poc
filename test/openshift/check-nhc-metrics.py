#!/usr/bin/env python3
"""Read-only, OpenShift-specific verification of the pinned NHC metrics contract.

Only sanitized booleans, counts and named conditions leave this process. Pod
names, discovery labels, certificate data and command diagnostics stay in memory.
"""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlencode

DEPLOYMENT = "node-healthcheck-controller-manager"
SERVICE = DEPLOYMENT + "-metrics-service"
MONITOR = DEPLOYMENT + "-metrics-monitor"
CA_CONFIGMAP = "node-healthcheck-ca-bundle"
SCRAPE_CLASS = "tls-client-certificate-auth"
MONITORING_NAMESPACE = "openshift-monitoring"
CORE_CONDITIONS = ("ca_populated", "service_matches", "certificate_wired",
                   "mtls_enabled", "scrape_class_present", "monitor_accepted")
LOG_LIMIT = 4 * 1024 * 1024


def target_failures(expected, targets, up_count):
    """Compare one Prometheus replica with all ready NHC pods, never a subset."""
    expected = set(expected)
    failures = []
    if not expected or {target.get("pod_id") for target in targets} != expected:
        failures.append("target_coverage")
    if len(targets) != len(expected):
        failures.append("target_count")
    if any(target.get("health") != "up" or target.get("lastError") for target in targets):
        failures.append("target_health")
    if up_count != len(expected):
        failures.append("scrape_samples")
    return failures


def evaluate(snapshot: dict) -> list[str]:
    """Evaluate the normalized fixture contract without performing any I/O."""
    failures = [key for key in CORE_CONDITIONS if not snapshot.get(key, False)]
    failures.extend(target_failures(snapshot.get("ready_pod_ids", []),
                                    snapshot.get("nhc_targets", []),
                                    snapshot.get("nhc_up_count")))
    for key in ("replica_readiness", "namespace_monitored", "permissions",
                "prometheus_queries", "rejection_checks"):
        if key in snapshot and not snapshot[key]:
            failures.append(key)
    if snapshot.get("prometheus_replicas_unavailable", 0):
        failures.append("prometheus_replica_unavailable")
    for index, replica in enumerate(snapshot.get("replicas", [])):
        for failure in replica.get("failures", []):
            failures.append(f"prometheus_replica_{index}_{failure}")
    return list(dict.fromkeys(failures))


class CollectionError(Exception):
    """A named, sanitized collection failure; never wrap command output."""


class Oc:
    def __init__(self, kubeconfig, deadline=None):
        self.kubeconfig = str(kubeconfig)
        self.deadline = deadline

    def text(self, args, stage, allow_no=False):
        limit = 10.0
        if self.deadline is not None:
            limit = min(limit, self.deadline - time.monotonic())
        if limit <= 0:
            raise CollectionError("collection_timeout")
        split = args.index("--") if "--" in args else len(args)
        command = ["oc", *args[:split], "--kubeconfig", self.kubeconfig,
                   f"--request-timeout={max(1, math.ceil(limit))}s", *args[split:]]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=limit)
        except (OSError, subprocess.TimeoutExpired, UnicodeError):
            raise CollectionError(stage + "_unavailable") from None
        if result.returncode:
            if allow_no and result.returncode == 1 and result.stdout.strip() == "no":
                return "no"
            raise CollectionError(stage + "_unavailable")
        return result.stdout

    def json(self, args, stage):
        try:
            value = json.loads(self.text(args, stage))
        except (ValueError, TypeError):
            raise CollectionError(stage + "_malformed") from None
        if not isinstance(value, dict):
            raise CollectionError(stage + "_malformed")
        return value

    def get(self, resource, name, namespace, stage):
        args = ["get", resource, name, "-o", "json"]
        if namespace:
            args += ["-n", namespace]
        return self.json(args, stage)

    def listing(self, resource, namespace, stage, selector=None):
        args = ["get", resource, "-n", namespace, "-o", "json"]
        if selector is not None:
            args += ["-l", selector]
        value = self.json(args, stage).get("items")
        if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
            raise CollectionError(stage + "_malformed")
        return value

    def logs(self, pod, namespace, container, stage, since=None):
        args = ["logs", pod, "-n", namespace, "-c", container,
                "--tail=-1", f"--limit-bytes={LOG_LIMIT}"]
        if since:
            args.append("--since-time=" + since)
        value = self.text(args, stage)
        if len(value.encode("utf-8")) >= LOG_LIMIT:
            raise CollectionError(stage + "_incomplete")
        return value

    def allowed(self, verb, resource, namespace, service_account):
        return self.text(["auth", "can-i", verb, resource, "-n", namespace,
                          "--as=system:serviceaccount:" + service_account],
                         "permissions", allow_no=True).strip() == "yes"

    def prometheus(self, pod, path, params):
        url = "http://localhost:9090/api/v1/" + path + "?" + urlencode(params)
        value = self.json(["exec", pod, "-n", MONITORING_NAMESPACE, "-c", "prometheus", "--",
                           "curl", "-fsS", "--max-time", "5", url], "prometheus_query")
        if not isinstance(value, dict) or value.get("status") != "success" or not isinstance(value.get("data"), dict):
            raise CollectionError("prometheus_query_unsuccessful")
        return value["data"]


def ready(pod):
    return (not pod.get("metadata", {}).get("deletionTimestamp") and
            pod.get("status", {}).get("phase") == "Running" and
            any(condition.get("type") == "Ready" and condition.get("status") == "True"
                for condition in pod.get("status", {}).get("conditions", [])))


def certificate_wired(pod_spec):
    for volume in pod_spec.get("volumes", []):
        secret = volume.get("secret", {})
        if secret.get("secretName") != "node-healthcheck-tls" or secret.get("optional", False):
            continue
        items = secret.get("items", [])
        if {item.get("key"): item.get("path") for item in items} != {"tls.crt": "tls.crt", "tls.key": "tls.key"}:
            continue
        manager = next((c for c in pod_spec.get("containers", []) if c.get("name") == "manager"), {})
        if any(mount.get("name") == volume.get("name") and mount.get("mountPath") == "/etc/tls/private"
               and mount.get("readOnly") is True and not mount.get("subPath") and not mount.get("subPathExpr")
               for mount in manager.get("volumeMounts", [])):
            return True
    return False


def labels_match(labels, selector):
    if not selector.get("matchLabels"):
        return False
    if any(labels.get(key) != value for key, value in selector["matchLabels"].items()):
        return False
    # The pinned NHC monitor uses matchLabels only. Fail closed on other selectors.
    return not selector.get("matchExpressions")


def service_matches(service, monitor, namespace, deployment):
    metadata, spec = service.get("metadata", {}), monitor.get("spec", {})
    endpoints = spec.get("endpoints", [])
    if len(endpoints) != 1:
        return False
    endpoint = endpoints[0]
    tls = endpoint.get("tlsConfig", {})
    namespace_selector = spec.get("namespaceSelector", {})
    selected_namespace = (not namespace_selector or
                          namespace in namespace_selector.get("matchNames", []))
    owner = any(ref.get("kind") == "Deployment" and ref.get("name") == DEPLOYMENT
                and ref.get("uid") == deployment.get("metadata", {}).get("uid")
                for ref in monitor.get("metadata", {}).get("ownerReferences", []))
    return bool(owner and selected_namespace and
                labels_match(metadata.get("labels", {}), spec.get("selector", {})) and
                metadata.get("labels", {}).get("app.kubernetes.io/instance") == "metrics" and
                metadata.get("annotations", {}).get("service.beta.openshift.io/serving-cert-secret-name") == "node-healthcheck-tls" and
                service.get("spec", {}).get("selector") == deployment.get("spec", {}).get("selector", {}).get("matchLabels") and
                any(port.get("name") == "https" and port.get("port") == 8443 and port.get("targetPort") == "https"
                    for port in service.get("spec", {}).get("ports", [])) and
                endpoint.get("port") == "https" and endpoint.get("scheme") == "https" and
                tls.get("ca", {}).get("configMap") == {"name": CA_CONFIGMAP, "key": "service-ca.crt"} and
                tls.get("serverName") == f"{SERVICE}.{namespace}.svc" and not tls.get("insecureSkipVerify", False) and
                spec.get("scrapeClass") == SCRAPE_CLASS)


def scrape_class_present(prometheus):
    return any(item.get("name") == SCRAPE_CLASS and
               all(item.get("tlsConfig", {}).get(key) for key in ("caFile", "certFile", "keyFile")) and
               not item.get("tlsConfig", {}).get("insecureSkipVerify", False)
               for item in prometheus.get("spec", {}).get("scrapeClasses", []))


def event_time(event):
    return (event.get("series", {}).get("lastObservedTime") or event.get("lastTimestamp") or
            event.get("eventTime") or event.get("metadata", {}).get("creationTimestamp"))


def recent_rejection(event, namespace, started):
    involved = event.get("involvedObject", event.get("regarding", {}))
    message = (event.get("message", "") + " " + event.get("reason", "")).lower()
    is_monitor = (involved.get("kind") == "ServiceMonitor" and involved.get("name") == MONITOR and
                  involved.get("namespace", namespace) == namespace)
    # Some operators attach the event to another object and identify the monitor in its message.
    is_monitor = is_monitor or (MONITOR in message and namespace in message)
    if not is_monitor or (event.get("type") != "Warning" and "reject" not in message):
        return False
    timestamp = event_time(event)
    if not timestamp:
        return True  # Cannot prove a monitor-specific rejection predates this run.
    try:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")) >= started
    except (ValueError, TypeError):
        return True


def rejection_checks(oc, namespace, started):
    events = oc.listing("events", namespace, "monitor_events")
    events += oc.listing("events", MONITORING_NAMESPACE, "monitor_events")
    rejected = any(recent_rejection(event, namespace, started) for event in events)
    operators = oc.listing("pods", MONITORING_NAMESPACE, "monitor_operator",
                           "app.kubernetes.io/name=prometheus-operator")
    if not operators or not all(ready(pod) for pod in operators):
        raise CollectionError("monitor_operator_unavailable")
    for pod in operators:
        log = oc.logs(pod["metadata"]["name"], MONITORING_NAMESPACE, "prometheus-operator",
                      "monitor_operator_logs", started.isoformat().replace("+00:00", "Z"))
        for line in log.splitlines():
            lowered = line.lower()
            if MONITOR in lowered and namespace in lowered and any(word in lowered for word in (
                    "reject", "skipping servicemonitor", "failed", "error")):
                rejected = True
    return not rejected


def vector(data):
    if data.get("resultType") != "vector" or not isinstance(data.get("result"), list):
        raise CollectionError("prometheus_query_malformed")
    result = data["result"]
    if any(not isinstance(sample, dict) or not isinstance(sample.get("metric"), dict) or
           not isinstance(sample.get("value"), list) or len(sample["value"]) != 2 for sample in result):
        raise CollectionError("prometheus_query_malformed")
    try:
        if any(not math.isfinite(float(sample["value"][1])) for sample in result):
            raise ValueError()
    except (ValueError, TypeError):
        raise CollectionError("prometheus_query_malformed") from None
    return result


def collect(oc, namespace, started):
    cm = oc.get("configmap", CA_CONFIGMAP, namespace, "ca_configmap")
    service = oc.get("service", SERVICE, namespace, "metrics_service")
    monitor = oc.get("servicemonitor", MONITOR, namespace, "metrics_monitor")
    deployment = oc.get("deployment", DEPLOYMENT, namespace, "nhc_deployment")
    monitor_labels = monitor.get("spec", {}).get("selector", {}).get("matchLabels", {})
    selected_services = oc.listing("services", namespace, "metrics_service_discovery",
                                  ",".join(f"{key}={value}" for key, value in sorted(monitor_labels.items())))
    exactly_one_service = (len(selected_services) == 1 and
                           selected_services[0].get("metadata", {}).get("name") == SERVICE)
    ns = oc.get("namespace", namespace, None, "operand_namespace")
    prometheus = oc.get("prometheus", "k8s", MONITORING_NAMESPACE, "platform_prometheus")
    selector = deployment.get("spec", {}).get("selector", {}).get("matchLabels", {})
    if not selector:
        raise CollectionError("nhc_deployment_malformed")
    pods = oc.listing("pods", namespace, "nhc_pods", ",".join(f"{k}={v}" for k, v in sorted(selector.items())))
    pods = [pod for pod in pods if ready(pod)]
    pod_ids = [pod["metadata"]["name"] for pod in pods]
    mode = []
    for pod in pods:
        log = oc.logs(pod["metadata"]["name"], namespace, "manager", "nhc_startup_logs")
        mode.append("Configuring secure metrics with mTLS" in log and
                    "mTLS certificate not present, skipping mTLS configuration" not in log and
                    "Using bearer-token authn/authz via controller-runtime" not in log and
                    certificate_wired(pod.get("spec", {})))
    prom_pods = oc.listing("pods", MONITORING_NAMESPACE, "prometheus_pods", "prometheus=k8s")
    prom_pods = sorted(prom_pods, key=lambda pod: pod.get("metadata", {}).get("name", ""))
    available = [pod for pod in prom_pods if ready(pod)]
    expected_prom = prometheus.get("spec", {}).get("replicas", 1)
    unavailable = max(len(prom_pods) - len(available), expected_prom - len(available), 0)
    permissions = []
    manager_sa = namespace + ":" + deployment.get("spec", {}).get("template", {}).get("spec", {}).get("serviceAccountName", "default")
    prometheus_sa = MONITORING_NAMESPACE + ":" + prometheus.get("spec", {}).get("serviceAccountName", "prometheus-k8s")
    discovery_role = (monitor.get("spec", {}).get("serviceDiscoveryRole") or
                      prometheus.get("spec", {}).get("serviceDiscoveryRole") or "Endpoints")
    if discovery_role not in ("Endpoints", "EndpointSlice"):
        raise CollectionError("discovery_role_unsupported")
    endpoint_resource = "endpointslices.discovery.k8s.io" if discovery_role == "EndpointSlice" else "endpoints"
    for verb in ("get", "list", "watch"):
        permissions.append(oc.allowed(verb, "configmaps", "kube-system", manager_sa))
        for resource in ("services", endpoint_resource, "pods"):
            permissions.append(oc.allowed(verb, resource, namespace, prometheus_sa))
    accepted = rejection_checks(oc, namespace, started)
    snapshot = {
        "ca_populated": bool(str(cm.get("data", {}).get("service-ca.crt", "")).strip()) and
                        cm.get("metadata", {}).get("annotations", {}).get("service.beta.openshift.io/inject-cabundle") == "true",
        "service_matches": exactly_one_service and service_matches(service, monitor, namespace, deployment),
        "certificate_wired": certificate_wired(deployment.get("spec", {}).get("template", {}).get("spec", {})),
        "mtls_enabled": bool(mode) and all(mode),
        "scrape_class_present": scrape_class_present(prometheus),
        "monitor_accepted": accepted,
        "ready_pod_ids": pod_ids, "nhc_targets": [], "nhc_up_count": 0,
        "replica_readiness": bool(pods) and len(pods) == deployment.get("spec", {}).get("replicas", 1),
        "namespace_monitored": ns.get("metadata", {}).get("labels", {}).get("openshift.io/cluster-monitoring") == "true",
        "permissions": all(permissions), "rejection_checks": True,
        "prometheus_queries": bool(available), "prometheus_replicas_unavailable": unavailable,
        "replicas": [], "aggregate_rejection_alert": {"firing": 0, "pending": 0},
    }
    first_source = True
    for pod in prom_pods:
        replica = {"available": bool(ready(pod)), "query_succeeded": False,
                   "nhc_targets": [], "nhc_up_count": 0, "failures": []}
        if not replica["available"]:
            replica["failures"] = ["unavailable"]
            snapshot["replicas"].append(replica)
            continue
        try:
            name = pod["metadata"]["name"]
            targets = oc.prometheus(name, "targets", {"state": "active"}).get("activeTargets")
            if not isinstance(targets, list) or any(not isinstance(t, dict) for t in targets):
                raise CollectionError("prometheus_targets_malformed")
            selected = [target for target in targets if target.get("scrapePool") == f"serviceMonitor/{namespace}/{MONITOR}/0"]
            normalized = []
            for target in selected:
                if not isinstance(target.get("labels"), dict) or not isinstance(target.get("discoveredLabels"), dict) or "lastError" not in target:
                    raise CollectionError("prometheus_targets_malformed")
                normalized.append({"pod_id": target["discoveredLabels"].get("__meta_kubernetes_pod_name") or target["labels"].get("pod"),
                                   "health": target.get("health"), "lastError": target["lastError"]})
            samples = vector(oc.prometheus(name, "query", {"query": f'up{{namespace="{namespace}",service="{SERVICE}"}}'}))
            # Instant queries may retain old pod series during the lookback window.
            # Verify the current ready pods; active target checks remain exact.
            samples = [sample for sample in samples if sample["metric"].get("pod") in pod_ids]
            sample_ids = [sample["metric"].get("pod") for sample in samples]
            samples_match = (set(sample_ids) == set(pod_ids) and len(sample_ids) == len(set(sample_ids)) and
                             all(sample["metric"].get("namespace") == namespace and sample["metric"].get("service") == SERVICE
                                 and float(sample["value"][1]) == 1 for sample in samples))
            up_count = len(samples) if samples_match else 0
            alerts = vector(oc.prometheus(name, "query", {"query": 'ALERTS{alertname="PrometheusOperatorRejectedResources"}'}))
            for state in ("firing", "pending"):
                count = sum(sample["metric"].get("alertstate") == state and float(sample["value"][1]) > 0 for sample in alerts)
                snapshot["aggregate_rejection_alert"][state] = max(snapshot["aggregate_rejection_alert"][state], count)
            replica.update(query_succeeded=True, nhc_targets=normalized, nhc_up_count=up_count,
                           failures=target_failures(pod_ids, normalized, up_count))
            if first_source:
                snapshot["nhc_targets"], snapshot["nhc_up_count"] = normalized, up_count
                first_source = False
        except CollectionError as error:
            replica["failures"].append(str(error))
            snapshot["prometheus_queries"] = False
        snapshot["replicas"].append(replica)
    if first_source:
        snapshot["prometheus_queries"] = False
    snapshot["monitor_accepted"] = accepted and not first_source and all(
        replica["query_succeeded"] and not replica["failures"] for replica in snapshot["replicas"])
    return snapshot


def summarize(snapshot, failures, started, attempts):
    return {"healthy": not failures, "failures": failures,
            "started_at": started.isoformat().replace("+00:00", "Z"), "attempts": attempts,
            "conditions": {key: bool(snapshot.get(key, False)) for key in CORE_CONDITIONS + (
                "replica_readiness", "namespace_monitored", "permissions", "prometheus_queries", "rejection_checks")},
            "ready_nhc_replicas": len(snapshot.get("ready_pod_ids", [])),
            "prometheus_replicas_checked": sum(replica["query_succeeded"] for replica in snapshot.get("replicas", [])),
            "prometheus_replicas_unavailable": snapshot.get("prometheus_replicas_unavailable", 0),
            "prometheus_replicas": [{"index": index, "available": replica["available"],
                "query_succeeded": replica["query_succeeded"], "target_count": len(replica["nhc_targets"]),
                "up_samples": replica["nhc_up_count"], "failures": replica["failures"]}
                for index, replica in enumerate(snapshot.get("replicas", []))],
            "aggregate_rejection_alert": snapshot.get("aggregate_rejection_alert", {"firing": 0, "pending": 0})}


class SanitizedParser(argparse.ArgumentParser):
    def error(self, message):
        print(json.dumps({"healthy": False, "failures": ["invalid_arguments"]}))
        raise SystemExit(2)


def main():
    parser = SanitizedParser(description=__doc__)
    parser.add_argument("--kubeconfig", required=True, help="explicit readable kubeconfig file")
    parser.add_argument("--namespace", required=True, help="NHC operand namespace")
    parser.add_argument("--timeout", type=float, default=300, help="polling budget in seconds; 0 runs one bounded scan")
    args = parser.parse_args()
    if (not math.isfinite(args.timeout) or not 0 <= args.timeout <= 3600 or
            not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?", args.namespace)):
        parser.error("invalid arguments")
    kubeconfig = Path(args.kubeconfig).expanduser()
    try:
        if not kubeconfig.is_file():
            raise OSError()
        with kubeconfig.open("rb") as stream:
            stream.read(1)
    except OSError:
        parser.error("kubeconfig is not readable")
    started = datetime.now(timezone.utc)
    # timeout=0 means one immediate scan; each command and the complete scan remain bounded.
    deadline = time.monotonic() + (args.timeout if args.timeout else 90)
    oc = Oc(kubeconfig, deadline)
    attempts, snapshot = 0, {}
    while True:
        attempts += 1
        try:
            snapshot = collect(oc, args.namespace, started)
            failures = evaluate(snapshot)
        except CollectionError as error:
            failures = [str(error)]
        except (KeyError, TypeError, ValueError, AttributeError):
            failures = ["collection_malformed"]
        if not failures or not args.timeout or time.monotonic() >= deadline:
            break
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    print(json.dumps(summarize(snapshot, failures, started, attempts), sort_keys=True))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
