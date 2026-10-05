# test/cluster/results_test.py — offline checks for the per-case outcome recorder.
import contextlib, importlib.util, io, json, pathlib, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("results", HERE / "results.py")
results = importlib.util.module_from_spec(spec); spec.loader.exec_module(results)


class ResultsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_record_and_build(self):
        log = self.run / "case.log"
        log.write_text("== WAO-INST-05\nPASS: manager Available\nnote: no ConsolePlugin created\n"
                       "FAIL: status admissionReady true\nok: something\nTIMEOUT: status phase Available\n")
        results.main(["record", "--run-dir", str(self.run), "--id", "WAO-INST-05", "--status", "fail", "--log", str(log)])
        results.main(["record", "--run-dir", str(self.run), "--id", "WAO-INST-00", "--status", "pass", "--notes", "Machine API present"])
        with contextlib.redirect_stdout(io.StringIO()):
            results.main(["build", "--run-dir", str(self.run)])
        out = json.loads((self.run / "results.json").read_text())
        ids = [e["id"] for e in out]
        self.assertEqual(ids, [f"WAO-INST-{i:02d}" for i in range(19)])
        by = {e["id"]: e for e in out}
        self.assertEqual(by["WAO-INST-00"]["status"], "pass")
        self.assertEqual(by["WAO-INST-00"]["notes"], "Machine API present")
        self.assertEqual(by["WAO-INST-05"]["status"], "fail")
        self.assertEqual(by["WAO-INST-05"]["notes"],
                         "note: no ConsolePlugin created; FAIL: status admissionReady true; TIMEOUT: status phase Available")
        self.assertRegex(by["WAO-INST-05"]["observed_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(by["WAO-INST-01"]["status"], "blocked")
        self.assertEqual(by["WAO-INST-01"]["notes"], "not run")
        self.assertEqual(set(by["WAO-INST-01"]), {"id", "status", "observed_at", "notes"})

    def test_rejects_unknown_status_and_id(self):
        with self.assertRaises(SystemExit):
            results.main(["record", "--run-dir", str(self.run), "--id", "WAO-INST-05", "--status", "ok"])
        with self.assertRaises(SystemExit):
            results.main(["record", "--run-dir", str(self.run), "--id", "WAO-INST-99", "--status", "pass"])

    def test_rerun_overwrites(self):
        for status in ("fail", "pass"):
            results.main(["record", "--run-dir", str(self.run), "--id", "WAO-INST-03", "--status", status])
        with contextlib.redirect_stdout(io.StringIO()):
            results.main(["build", "--run-dir", str(self.run)])
        by = {e["id"]: e for e in json.loads((self.run / "results.json").read_text())}
        self.assertEqual(by["WAO-INST-03"]["status"], "pass")


if __name__ == "__main__":
    unittest.main()
