"""Check that the local build works with BSD date's command-line options."""

import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class BuildTest(unittest.TestCase):
    def test_build_timestamp_uses_portable_date_options(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = pathlib.Path(directory)
            date = tools / "date"
            date.write_text("""#!/bin/sh
for arg in "$@"; do
    case "$arg" in
        --*|-I*) echo "unsupported BSD date option: $arg" >&2; exit 64 ;;
    esac
done
exec /bin/date "$@"
""")
            go = tools / "go"
            go.write_text("""#!/bin/sh
case "$1" in
    version) echo 'go version go1.test' ;;
    env) echo 'arm64' ;;
    build) printf '%s\n' "$GOFLAGS" > "$GOFLAGS_CAPTURE" ;;
    *) exit 64 ;;
esac
""")
            date.chmod(0o755)
            go.chmod(0o755)
            capture = tools / "goflags"
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       GOFLAGS="", GOFLAGS_CAPTURE=str(capture),
                       CI_VERSION="test-version", CI_COMMIT="test-commit")
            result = subprocess.run([str(ROOT / "hack/build.sh")], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(capture.read_text(), re.compile(
                r"version\.BuildDate=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"))


if __name__ == "__main__":
    unittest.main()
