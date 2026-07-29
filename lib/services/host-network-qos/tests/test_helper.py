import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class HostNetworkQosHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.helper = cls.repo_root / "lib/services/host-network-qos/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(
            tempfile.mkdtemp(prefix="host-network-qos-test.", dir=self.tmp_root)
        )
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self.write_fake_ip()
        self.write_fake_tc()

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def write_executable(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def write_fake_ip(self):
        log_path = self.state_dir / "ip.log"
        ifb_state = self.state_dir / "ifb-present"
        self.write_executable(
            self.fake_bin / "ip",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
case "$*" in
  "link show dev eno1") exit 0 ;;
  "link show dev ifb-eno1") [ -e {ifb_state} ] ;;
  "link add name ifb-eno1 type ifb") touch {ifb_state} ;;
  "link set dev ifb-eno1 up") [ -e {ifb_state} ] ;;
  "link set dev ifb-eno1 down") exit 0 ;;
  "link delete dev ifb-eno1 type ifb") rm -f {ifb_state} ;;
  *) exit 1 ;;
esac
""",
        )

    def write_fake_tc(self):
        log_path = self.state_dir / "tc.log"
        self.write_executable(
            self.fake_bin / "tc",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{FAKE_TC_APPLY_STATUS:-0}}" != 0 ] && [ "${{1-}}" != qdisc ]; then
  exit "$FAKE_TC_APPLY_STATUS"
fi
case "$*" in
  "qdisc show dev eno1")
    printf '%s\\n' 'qdisc cake 8001: root refcnt 2 bandwidth 900Mbit diffserv4'
    printf '%s\\n' 'qdisc ingress ffff: parent ffff:fff1 ----------------'
    ;;
  "qdisc show dev ifb-eno1")
    printf '%s\\n' 'qdisc cake 8002: root refcnt 2 bandwidth 900Mbit diffserv4 ingress'
    ;;
  "filter show dev eno1 parent ffff:")
    printf '%s\\n' 'action order 1: ctinfo dscp 0xfc000000 0x01000000 pipe action order 2: mirred egress redirect dev ifb-eno1'
    ;;
  *) exit 0 ;;
esac
""",
        )

    def run_helper(self, command: str, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "HOST_NETWORK_QOS_INTERFACE": "eno1",
                "HOST_NETWORK_QOS_IFB_INTERFACE": "ifb-eno1",
                "HOST_NETWORK_QOS_UPLOAD_BANDWIDTH": "900Mbit",
                "HOST_NETWORK_QOS_DOWNLOAD_BANDWIDTH": "900Mbit",
            }
        )
        env.update(overrides)
        return subprocess.run(
            [
                "bash",
                "-c",
                f'source "$1"; main "$2"',
                "host-network-qos-test",
                str(self.helper),
                command,
            ],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_apply_installs_cake_and_ctinfo_restore(self):
        result = self.run_helper("apply")

        self.assertEqual(result.returncode, 0, result.stderr)
        tc_log = (self.state_dir / "tc.log").read_text(encoding="utf-8")
        self.assertIn(
            "qdisc replace dev eno1 root cake bandwidth 900Mbit "
            "diffserv4 nat dual-srchost wash",
            tc_log,
        )
        self.assertIn(
            "qdisc replace dev ifb-eno1 root cake bandwidth 900Mbit "
            "diffserv4 nat dual-dsthost ingress wash",
            tc_log,
        )
        self.assertIn(
            "action ctinfo dscp 0xfc000000 0x01000000 pipe "
            "action mirred egress redirect dev ifb-eno1",
            tc_log,
        )

    def test_failed_apply_restores_default_qdiscs(self):
        result = self.run_helper("apply", FAKE_TC_APPLY_STATUS="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restoring defaults", result.stderr)
        self.assertFalse((self.state_dir / "ifb-present").exists())
        tc_log = (self.state_dir / "tc.log").read_text(encoding="utf-8")
        self.assertGreaterEqual(tc_log.count("qdisc del dev eno1 root"), 2)

    def test_remove_is_idempotent(self):
        first = self.run_helper("remove")
        second = self.run_helper("remove")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)

    def test_missing_bandwidth_is_rejected_before_mutation(self):
        result = self.run_helper("apply", HOST_NETWORK_QOS_UPLOAD_BANDWIDTH="")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HOST_NETWORK_QOS_UPLOAD_BANDWIDTH is required", result.stderr)
        self.assertFalse((self.state_dir / "tc.log").exists())


if __name__ == "__main__":
    unittest.main()
