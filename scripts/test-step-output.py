#!/usr/bin/env python3
"""Synthetic integration tests: no build, signing, network or user configuration."""
import errno
import importlib.util
import os
from pathlib import Path
import pty
import re
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
import fcntl

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("step-output.py")
spec = importlib.util.spec_from_file_location("step_output", SCRIPT)
step_output = importlib.util.module_from_spec(spec)
spec.loader.exec_module(step_output)


class StepOutputTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="step-output-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "step.log"
        self.environment = dict(os.environ, TERM="xterm", CI="", MAKE_PROGRESS="", NO_COLOR="")

    @staticmethod
    def without_styles(output):
        return re.sub(rb"\x1b\[[0-9;]*m", b"", output)

    def args(self, source):
        return [sys.executable, str(SCRIPT), "--title", "Building app", "--log", str(self.log),
                "--", sys.executable, "-c", source]

    def run_step(self, source, **kwargs):
        return subprocess.run(self.args(source), env=self.environment, capture_output=True, timeout=5, **kwargs)

    def test_plain_success_retains_complete_combined_log(self):
        result = self.run_step("import os; os.write(1,b'hello\\n'); os.write(2,b'error stream\\n')")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"Building app...\nBuilding app: OK\n")
        self.assertEqual(self.log.read_bytes(), b"hello\nerror stream\n")

    def test_failure_shows_only_last_three_sanitized_lines(self):
        result = self.run_step("import os; os.write(1,b'old\\none\\n\\x1b[31mtwo\\x1b[0m\\nthree\\n'); raise SystemExit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertIn(b"FAILED (exit 7)\none\ntwo\nthree\nLog: ", result.stdout)
        self.assertNotIn(b"\nold\n", result.stdout)
        self.assertNotIn(b"\x1b", result.stdout)
        self.assertIn(b"\x1b[31m", self.log.read_bytes())

    def test_missing_command(self):
        args = self.args("unused")[:-3] + [str(self.root / "missing-command")]
        result = subprocess.run(args, env=self.environment, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"FAILED (exit 127)", result.stdout)
        self.assertIn(b"not found", self.log.read_bytes())
        self.assertNotIn(b"missing-command", result.stdout)

    def test_utf8_cr_and_escapes_across_chunks(self):
        tail = step_output.Tail()
        tail.feed("old\rnew\r")
        self.assertEqual(tail.rows(), ["new"])
        tail.feed("\n\x1b[")
        tail.feed("31mPříliš\x1b[0m\x1b]title")
        tail.feed("\x1b\\\x00 žluťoučký\n")
        self.assertEqual(tail.rows(), ["new", "Příliš žluťoučký"])
        self.assertEqual(step_output.clipped("a界e\u0301", 4), "a界e\u0301")

    def run_pty(self, source, expected_code=0, **overrides):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 24, 0, 0))
        process = subprocess.Popen(self.args(source), env=dict(self.environment, **overrides),
                                   stdout=slave, stderr=slave)
        os.close(slave)
        result = bytearray()
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            result.extend(chunk)
        self.assertEqual(process.wait(timeout=5), expected_code)
        return bytes(result)

    def test_tty_uses_only_three_live_rows_and_truncates(self):
        output = self.run_pty("import time; print('界'*40,flush=True); time.sleep(.2); print('done',flush=True)")
        self.assertIn(b"\x1b[3A", output)
        self.assertIn(b"\x1b[4A", output)
        self.assertNotIn(b"\x1b[2J", output)
        self.assertNotIn(("界" * 12).encode(), output)
        self.assertIn(b"Building app: OK", self.without_styles(output))
        self.assertEqual(self.log.read_text(), "界" * 40 + "\ndone\n")

    def test_plain_and_ci_disable_tty_ansi(self):
        for overrides in ({"MAKE_PROGRESS": "plain"}, {"CI": "true"}, {"TERM": "dumb"}):
            with self.subTest(overrides=overrides):
                output = self.run_pty("print('hidden progress')", **overrides)
                self.assertNotIn(b"\x1b", output)
                self.assertNotIn(b"hidden progress", output)

    def test_tty_failure_keeps_tail_and_log_reference(self):
        output = self.run_pty("print('first'); print('second'); raise SystemExit(9)", expected_code=9)
        self.assertIn(b"FAILED (exit 9)", self.without_styles(output))
        self.assertIn(b"first\r\nsecond\r\nLog:", output)
        self.assertIn(str(self.log).encode(), output)
        self.assertEqual(self.log.read_bytes(), b"first\nsecond\n")

    def test_tty_styles_distinguish_title_progress_and_result(self):
        source = "import time; print('working',flush=True); time.sleep(.15)"
        output = self.run_pty(source)
        self.assertIn(b"\x1b[1;36mBuilding app...\x1b[0m", output)
        self.assertIn(b"\x1b[2mworking\x1b[0m", output)
        self.assertIn(b"\x1b[1mBuilding app\x1b[0m\x1b[32m: OK\x1b[0m", output)
        self.assertEqual(self.log.read_bytes(), b"working\n")
        failure = self.run_pty("raise SystemExit(7)", expected_code=7)
        self.assertIn(b"\x1b[31m: FAILED (exit 7)\x1b[0m", failure)

    def test_no_color_keeps_live_progress_without_styles(self):
        output = self.run_pty("import time; print('working',flush=True); time.sleep(.15)", NO_COLOR="1")
        self.assertEqual(self.without_styles(output), output)
        self.assertIn(b"\x1b[3A", output)
        self.assertIn(b"Building app: OK", output)

    def test_split_utf8_is_decoded_for_display_without_changing_log(self):
        source = "import os,time; os.write(1,b'\\xc5'); time.sleep(.12); os.write(1,b'\\xbelu\\xc5\\xa5ou\\xc4\\x8dk\\xc3\\xbd\\n'); raise SystemExit(3)"
        result = self.run_step(source)
        self.assertEqual(result.returncode, 3)
        self.assertIn("žluťoučký".encode(), result.stdout)
        self.assertEqual(self.log.read_bytes(), "žluťoučký\n".encode())

    def test_interrupt_terminates_child_process_group(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                pidfile = self.root / "child.pid"
                pidfile.unlink(missing_ok=True)
                source = ("import os,signal,time; signal.signal(signal.SIGINT,signal.SIG_IGN); "
                          "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                          f"open({str(pidfile)!r},'w').write(str(os.getpid())); "
                          "print('ready',flush=True); time.sleep(30)")
                process = subprocess.Popen(self.args(source), env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 3
                    while not pidfile.exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue(pidfile.exists())
                    child = int(pidfile.read_text())
                    process.send_signal(signum)
                    stdout, _ = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 128 + signum)
                    self.assertIn(f"FAILED (exit {128 + signum})".encode(), stdout)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child, 0)
                    self.assertIn("ready", self.log.read_text())
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()

    def test_term_reaches_grandchild(self):
        ready = self.root / "grandchild-ready"
        stopped = self.root / "grandchild-stopped"
        descendant = ("import signal,time,pathlib; "
                      f"signal.signal(signal.SIGTERM,lambda *_: (pathlib.Path({str(stopped)!r}).write_text('stopped'),exit(0))); "
                      f"pathlib.Path({str(ready)!r}).write_text('ready'); time.sleep(30)")
        source = ("import subprocess,sys,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                  f"subprocess.Popen([sys.executable,'-c',{descendant!r}]); time.sleep(30)")
        process = subprocess.Popen(self.args(source), env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists())
            process.terminate()
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143)
            self.assertEqual(stopped.read_text(), "stopped")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == "__main__":
    unittest.main()
