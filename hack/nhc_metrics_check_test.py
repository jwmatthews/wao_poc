"""Offline contract and subprocess-boundary tests for the read-only NHC checker."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "test/openshift/check-nhc-metrics.py"
NS = "operand-test"
SERVICE = "node-healthcheck-controller-manager-metrics-service"
MONITOR = "node-healthcheck-controller-manager-metrics-monitor"
DEPLOYMENT = "node-healthcheck-controller-manager"


def healthy_snapshot():
    return dict(ca_populated=True, service_matches=True, certificate_wired=True,
                mtls_enabled=True, scrape_class_present=True, monitor_accepted=True,
                ready_pod_ids=["manager-a", "manager-b"],
                nhc_targets=[dict(pod_id=p, health="up", lastError="")
                             for p in ("manager-a", "manager-b")], nhc_up_count=2)


def fixtures():
    labels = {"app.kubernetes.io/component": "controller-manager",
              "app.kubernetes.io/name": "node-healthcheck-operator",
              "app.kubernetes.io/instance": "metrics"}
    selector = {"app.kubernetes.io/name": "node-healthcheck-operator"}
    pod_spec = {"serviceAccountName": DEPLOYMENT, "containers": [{"name": "manager",
        "volumeMounts": [{"name": "tls-config", "mountPath": "/etc/tls/private", "readOnly": True}]}],
        "volumes": [{"name": "tls-config", "secret": {"secretName": "node-healthcheck-tls",
                    "optional": False, "items": [{"key": "tls.crt", "path": "tls.crt"},
                                                  {"key": "tls.key", "path": "tls.key"}]}}]}
    ready = [{"type": "Ready", "status": "True"}]
    targets = [{"scrapePool": f"serviceMonitor/{NS}/{MONITOR}/0",
                "labels": {"pod": p, "namespace": NS, "service": SERVICE},
                "discoveredLabels": {"__meta_kubernetes_pod_name": p},
                "health": "up", "lastError": ""} for p in ("manager-a", "manager-b")]
    up = {"status": "success", "data": {"resultType": "vector", "result": [
        {"metric": {"pod": p, "namespace": NS, "service": SERVICE}, "value": [1, "1"]}
        for p in ("manager-a", "manager-b")]}}
    result = {"objects": {
        "configmap/node-healthcheck-ca-bundle": {"metadata": {"annotations": {
            "service.beta.openshift.io/inject-cabundle": "true"}}, "data": {"service-ca.crt": "PRIVATE_CA_SENTINEL"}},
        f"service/{SERVICE}": {"metadata": {"name": SERVICE, "labels": labels, "annotations": {
            "service.beta.openshift.io/serving-cert-secret-name": "node-healthcheck-tls"}},
            "spec": {"selector": selector, "ports": [{"name": "https", "port": 8443, "targetPort": "https"}]}},
        f"servicemonitor/{MONITOR}": {"metadata": {"ownerReferences": [{"kind": "Deployment", "name": DEPLOYMENT, "uid": "deployment-uid"}]},
            "spec": {"selector": {"matchLabels": labels}, "namespaceSelector": {"matchNames": [NS]},
                     "scrapeClass": "tls-client-certificate-auth", "endpoints": [{"port": "https", "scheme": "https",
                     "tlsConfig": {"ca": {"configMap": {"name": "node-healthcheck-ca-bundle", "key": "service-ca.crt"}},
                                   "serverName": f"{SERVICE}.{NS}.svc", "insecureSkipVerify": False}}]}},
        f"deployment/{DEPLOYMENT}": {"metadata": {"uid": "deployment-uid"}, "spec": {"replicas": 2,
            "selector": {"matchLabels": selector}, "template": {"metadata": {"labels": selector}, "spec": pod_spec}}},
        f"namespace/{NS}": {"metadata": {"labels": {"openshift.io/cluster-monitoring": "true"}}},
        "prometheus/k8s": {"spec": {"serviceAccountName": "prometheus-k8s", "scrapeClasses": [{
            "name": "tls-client-certificate-auth", "tlsConfig": {"caFile": "/ca/service-ca.crt",
            "certFile": "/cert/tls.crt", "keyFile": "/cert/tls.key", "insecureSkipVerify": False}}]}},
        "pods/operand": {"items": [{"metadata": {"name": p, "labels": selector}, "spec": copy.deepcopy(pod_spec),
            "status": {"phase": "Running", "conditions": ready}} for p in ("manager-a", "manager-b")]},
        "pods/prometheus": {"items": [{"metadata": {"name": p}, "status": {"phase": "Running", "conditions": ready}}
                                    for p in ("prometheus-k8s-0", "prometheus-k8s-1")]},
        "pods/operator": {"items": [{"metadata": {"name": "prometheus-operator-test"}, "status": {"phase": "Running", "conditions": ready}}]},
        "events": {"items": []}},
        "logs": {"manager-a": "Configuring secure metrics with mTLS\n", "manager-b": "Configuring secure metrics with mTLS\n",
                 "prometheus-operator-test": ""},
        "targets": {p: {"status": "success", "data": {"activeTargets": copy.deepcopy(targets)}}
                    for p in ("prometheus-k8s-0", "prometheus-k8s-1")},
        "up": {p: copy.deepcopy(up) for p in ("prometheus-k8s-0", "prometheus-k8s-1")},
        "alerts": {"status": "success", "data": {"resultType": "vector", "result": []}},
        "permissions": "yes"}
    result["objects"]["services"] = {"items": [copy.deepcopy(result["objects"][f"service/{SERVICE}"])]}
    return result


FAKE_OC = r'''#!/usr/bin/env python3
import json, os, sys, time
from urllib.parse import parse_qs, urlparse
args = sys.argv[1:]
with open(os.environ["OC_CALLS"], "a") as f:
    f.write(json.dumps(args) + "\n")
with open(os.environ["OC_FIXTURE"]) as f:
    data = json.load(f)
def reject():
    print("PRIVATE_CLUSTER_ERROR_SENTINEL", file=sys.stderr)
    sys.exit(1)
if "--kubeconfig" not in args or not any(a.startswith("--request-timeout=") for a in args): reject()
for flag in ("--kubeconfig", "-n", "--namespace"):
    if flag in args:
        i = args.index(flag); del args[i:i+2]
args = [a for a in args if not a.startswith("--request-timeout=")]
if not args or args[0] not in ("get", "logs", "auth", "exec"): reject()
if args[0] == "get":
    if args[1].lower() in ("secret", "secrets"): reject()
    if data.get("get_delay"): time.sleep(data["get_delay"])
    if data.get("get_failure"): reject()
    if data.get("malformed_get"):
        print("not json PRIVATE_CLUSTER_ERROR_SENTINEL"); sys.exit(0)
    key = args[1] + "/" + args[2] if args[1] not in ("pods", "events", "services") else args[1]
    if args[1] == "pods":
        label = args[args.index("-l") + 1]
        key = "pods/operator" if "prometheus-operator" in label else "pods/prometheus" if "prometheus" in label else "pods/operand"
    if key not in data["objects"]: reject()
    print(json.dumps(data["objects"][key]))
elif args[0] == "logs":
    if args[1] not in data["logs"]: reject()
    if "operator" in args[1] and not any(a.startswith("--since-time=") for a in args): reject()
    print(data["logs"][args[1]])
elif args[:2] == ["auth", "can-i"]:
    if not any(a.startswith("--as=system:serviceaccount:") for a in args): reject()
    permission = data["permissions"]
    print(permission.get(args[3], permission.get("default", "no")) if isinstance(permission, dict) else permission)
elif args[0] == "exec":
    tail = args[args.index("--") + 1:]
    if tail[:2] != ["curl", "-fsS"] or "-c" not in args or args[args.index("-c") + 1] != "prometheus": reject()
    if len(tail) != 5 or tail[2:4] != ["--max-time", "5"]: reject()
    url = urlparse(tail[-1])
    if url.scheme != "http" or url.hostname != "localhost" or url.port != 9090: reject()
    pod = args[1]
    if data.get("query_failure") == pod: reject()
    if data.get("malformed_query") == pod:
        print(json.dumps({"status": "error", "error": "PRIVATE_CLUSTER_ERROR_SENTINEL"})); sys.exit(0)
    if url.path == "/api/v1/targets" and url.query == "state=active": out = data["targets"][pod]
    elif url.path == "/api/v1/query":
        query = parse_qs(url.query).get("query", [""])[0]
        if query == 'up{namespace="operand-test",service="node-healthcheck-controller-manager-metrics-service"}': out = data["up"][pod]
        elif query == 'ALERTS{alertname="PrometheusOperatorRejectedResources"}': out = data["alerts"]
        else: reject()
    else: reject()
    print(json.dumps(out))
else: reject()
'''


class EvaluationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CHECKER.exists():
            return
        spec = importlib.util.spec_from_file_location("nhc_metrics_checker", CHECKER)
        cls.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.checker)

    def evaluate(self, snapshot):
        self.assertTrue(CHECKER.is_file(), "the metrics verification command must exist")
        return self.checker.evaluate(snapshot)

    def test_all_conditions_healthy(self):
        self.assertEqual(self.evaluate(healthy_snapshot()), [])

    def test_each_required_contract_condition_fails_closed(self):
        for field in ("ca_populated", "service_matches", "certificate_wired", "mtls_enabled", "scrape_class_present", "monitor_accepted"):
            with self.subTest(field=field):
                snapshot = healthy_snapshot(); snapshot[field] = False
                self.assertIn(field, self.evaluate(snapshot))

    def test_zero_targets_and_no_ready_pods_do_not_pass(self):
        snapshot = healthy_snapshot(); snapshot["nhc_targets"] = []; snapshot["nhc_up_count"] = 0
        self.assertIn("target_coverage", self.evaluate(snapshot))
        snapshot["ready_pod_ids"] = []
        self.assertIn("target_coverage", self.evaluate(snapshot))

    def test_unhealthy_second_replica_or_last_error_fails(self):
        for change in ({"health": "down"}, {"lastError": "PRIVATE_TLS_ERROR_SENTINEL"}):
            with self.subTest(change=change):
                snapshot = healthy_snapshot(); snapshot["nhc_targets"][1].update(change)
                self.assertIn("target_health", self.evaluate(snapshot))

    def test_duplicate_targets_and_incomplete_samples_fail(self):
        snapshot = healthy_snapshot(); snapshot["nhc_targets"].append(copy.deepcopy(snapshot["nhc_targets"][0]))
        self.assertIn("target_count", self.evaluate(snapshot))
        snapshot = healthy_snapshot(); snapshot["nhc_up_count"] = 1
        self.assertIn("scrape_samples", self.evaluate(snapshot))


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(CHECKER.is_file(), "the metrics verification command must exist")
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        (self.path / "oc").write_text(FAKE_OC); (self.path / "oc").chmod(0o755)
        (self.path / "kubeconfig").write_text("fixture kubeconfig")
        self.data = fixtures()

    def run_check(self, args=None):
        (self.path / "fixture.json").write_text(json.dumps(self.data))
        env = dict(os.environ, PATH=str(self.path) + os.pathsep + os.environ["PATH"],
                   OC_CALLS=str(self.path / "calls.jsonl"), OC_FIXTURE=str(self.path / "fixture.json"))
        result = subprocess.run([sys.executable, str(CHECKER)] + (args if args is not None else [
            "--kubeconfig", str(self.path / "kubeconfig"), "--namespace", NS, "--timeout", "0"]),
            env=env, text=True, capture_output=True, timeout=20)
        self.assertNotIn("PRIVATE_", result.stdout + result.stderr)
        self.assertNotIn("manager-a", result.stdout + result.stderr)
        self.assertNotIn("prometheus-k8s-", result.stdout + result.stderr)
        return result

    def test_healthy_read_only_command_checks_both_prometheus_replicas(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["healthy"])
        self.assertEqual(report["prometheus_replicas_checked"], 2)
        calls = [json.loads(line) for line in (self.path / "calls.jsonl").read_text().splitlines()]
        self.assertTrue(all("--kubeconfig" in call for call in calls))
        self.assertEqual({call[1] for call in calls if call[0] == "exec"}, {"prometheus-k8s-0", "prometheus-k8s-1"})

    def test_missing_or_unreadable_kubeconfig_is_argument_error_without_oc(self):
        for args in (["--namespace", NS], ["--kubeconfig", str(self.path / "absent"), "--namespace", NS],
                     ["--kubeconfig", str(self.path), "--namespace", NS]):
            with self.subTest(args=args):
                self.assertEqual(self.run_check(args).returncode, 2)
                self.assertFalse((self.path / "calls.jsonl").exists())

    def test_polling_budget_bounds_a_hung_oc_process(self):
        self.data["get_delay"] = 10
        import time
        started = time.monotonic()
        result = self.run_check(["--kubeconfig", str(self.path / "kubeconfig"),
                                 "--namespace", NS, "--timeout", "0.2"])
        self.assertEqual(result.returncode, 1)
        self.assertLess(time.monotonic() - started, 3)

    def test_monitor_must_select_only_the_intended_service(self):
        extra = copy.deepcopy(self.data["objects"][f"service/{SERVICE}"])
        extra["metadata"]["name"] = "unintended-service"
        self.data["objects"]["services"]["items"].append(extra)
        self.assert_failure("service_matches")

    def test_current_scrapes_pass_with_old_pod_series_in_query_lookback(self):
        samples = self.data["up"]["prometheus-k8s-0"]["data"]["result"]
        samples.extend([
            {"metric": {"pod": "old-manager-a", "namespace": NS, "service": SERVICE}, "value": [0, "1"]},
            {"metric": {"pod": "old-manager-b", "namespace": NS, "service": SERVICE}, "value": [0, "0"]},
        ])
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual([replica["up_samples"] for replica in report["prometheus_replicas"]], [2, 2])

    def test_duplicate_or_zero_or_wrong_pod_samples_cannot_pass(self):
        for change in ("duplicate", "duplicate_extra", "zero", "wrong_pod", "wrong_pod_only"):
            with self.subTest(change=change):
                self.data = fixtures()
                samples = self.data["up"]["prometheus-k8s-1"]["data"]["result"]
                if change == "duplicate": samples[1] = copy.deepcopy(samples[0])
                if change == "duplicate_extra": samples.append(copy.deepcopy(samples[0]))
                if change == "zero": samples[1]["value"][1] = "0"
                if change == "wrong_pod": samples[1]["metric"]["pod"] = "stale-pod"
                if change == "wrong_pod_only":
                    for index, sample in enumerate(samples): sample["metric"]["pod"] = f"old-pod-{index}"
                self.assert_failure("scrape_samples")

    def test_missing_or_empty_ca_fails(self):
        for value in ({}, {"service-ca.crt": ""}, {"service-ca.crt": "   "}):
            with self.subTest(value=value):
                self.data["objects"]["configmap/node-healthcheck-ca-bundle"]["data"] = value
                self.assert_failure("ca_populated")

    def test_service_metadata_must_match_monitor(self):
        del self.data["objects"][f"service/{SERVICE}"]["metadata"]["labels"]["app.kubernetes.io/instance"]
        self.assert_failure("service_matches")

    def test_required_mount_and_both_secret_keys(self):
        for change in ("volume", "key", "optional", "subPath"):
            with self.subTest(change=change):
                self.data = fixtures()
                spec = self.data["objects"][f"deployment/{DEPLOYMENT}"]["spec"]["template"]["spec"]
                if change == "volume": spec["volumes"] = []
                if change == "key": spec["volumes"][0]["secret"]["items"].pop()
                if change == "optional": spec["volumes"][0]["secret"]["optional"] = True
                if change == "subPath": spec["containers"][0]["volumeMounts"][0]["subPath"] = "tls.crt"
                self.assert_failure("certificate_wired")

    def test_absent_scrape_class_or_insecure_tls_fails(self):
        for classes in ([], [{"name": "tls-client-certificate-auth", "tlsConfig": {"insecureSkipVerify": True}}]):
            self.data["objects"]["prometheus/k8s"]["spec"]["scrapeClasses"] = classes
            self.assert_failure("scrape_class_present")

    def test_monitor_ca_server_name_and_port_are_required(self):
        for field, value in (("port", "wrong"), ("scheme", "http"), ("tlsConfig", {})):
            with self.subTest(field=field):
                self.data = fixtures()
                self.data["objects"][f"servicemonitor/{MONITOR}"]["spec"]["endpoints"][0][field] = value
                self.assert_failure("service_matches")

    def test_positive_startup_evidence_required_for_every_pod(self):
        self.data["logs"]["manager-b"] = "mTLS certificate not present, skipping mTLS configuration\nUsing bearer-token authn/authz via controller-runtime"
        self.assert_failure("mtls_enabled")

    def test_one_bad_prometheus_replica_cannot_hide_behind_healthy_peer(self):
        self.data["targets"]["prometheus-k8s-1"]["data"]["activeTargets"][1]["lastError"] = "PRIVATE_TLS_ERROR_SENTINEL"
        self.assert_failure("target_health")

    def test_empty_targets_and_missing_up_samples_fail(self):
        self.data["targets"]["prometheus-k8s-0"]["data"]["activeTargets"] = []
        self.assert_failure("target_coverage")
        self.data = fixtures(); self.data["up"]["prometheus-k8s-0"]["data"]["result"] = []
        self.assert_failure("scrape_samples")

    def test_wrong_scrape_pool_is_not_counted(self):
        for target in self.data["targets"]["prometheus-k8s-0"]["data"]["activeTargets"]:
            target["scrapePool"] = "serviceMonitor/other/monitor/0"
        self.assert_failure("target_coverage")

    def test_api_or_query_errors_never_look_like_healthy_empty_results(self):
        for key, value in (("get_failure", True), ("malformed_get", True),
                           ("query_failure", "prometheus-k8s-1"), ("malformed_query", "prometheus-k8s-0")):
            with self.subTest(key=key):
                self.data = fixtures(); self.data[key] = value
                self.assertEqual(self.run_check().returncode, 1)

    def test_incomplete_ready_pods_and_unavailable_prometheus_fail(self):
        self.data["objects"]["pods/operand"]["items"].pop()
        self.assert_failure("replica_readiness")
        self.data = fixtures(); self.data["objects"]["pods/prometheus"]["items"][1]["status"]["conditions"] = []
        self.assert_failure("prometheus_replica_unavailable")

    def test_discovery_permissions_follow_configured_role(self):
        self.data["permissions"] = {"default": "yes", "endpointslices.discovery.k8s.io": "no"}
        self.assertEqual(self.run_check().returncode, 0)
        self.data["objects"]["prometheus/k8s"]["spec"]["serviceDiscoveryRole"] = "EndpointSlice"
        self.assert_failure("permissions")
        self.data["objects"]["prometheus/k8s"]["spec"].pop("serviceDiscoveryRole")
        self.data["objects"][f"servicemonitor/{MONITOR}"]["spec"]["serviceDiscoveryRole"] = "EndpointSlice"
        self.assert_failure("permissions")

    def test_effective_permissions_and_namespace_monitoring_required(self):
        self.data["permissions"] = "no"
        self.assert_failure("permissions")
        self.data = fixtures(); self.data["objects"][f"namespace/{NS}"]["metadata"]["labels"] = {}
        self.assert_failure("namespace_monitored")

    def test_new_monitor_rejection_fails_but_historical_warning_is_ignored(self):
        event = {"involvedObject": {"kind": "ServiceMonitor", "name": MONITOR, "namespace": NS},
                 "type": "Warning", "reason": "Rejected", "message": "PRIVATE_REJECTION_SENTINEL", "lastTimestamp": "2000-01-01T00:00:00Z"}
        self.data["objects"]["events"]["items"] = [event]
        self.assertEqual(self.run_check().returncode, 0)
        event["lastTimestamp"] = "2999-01-01T00:00:00Z"
        self.assert_failure("monitor_accepted")

    def test_new_operator_rejection_logs_fail_acceptance(self):
        self.data["logs"]["prometheus-operator-test"] = f'level=warn msg="skipping servicemonitor" servicemonitor={NS}/{MONITOR}'
        self.assert_failure("monitor_accepted")

    def test_aggregate_rejection_alert_is_reported_without_attribution(self):
        self.data["alerts"]["data"]["result"] = [{"metric": {"alertstate": "firing", "namespace": "another-monitoring-namespace"}, "value": [1, "1"]}]
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stdout)["aggregate_rejection_alert"]["firing"], 1)

    def assert_failure(self, condition):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report["healthy"])
        self.assertTrue(any(condition in item for item in report["failures"]), report)


if __name__ == "__main__":
    unittest.main()
