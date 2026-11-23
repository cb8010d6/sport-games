"""Reject explicit engine failures while retaining complete subprocess evidence."""
import contextlib
import io
import sys
import unittest

from tools.smoke_game import checked_run

RETAINED = "ERROR: 9 resources still in use at exit (run with --verbose for details)."
OBJECTS = "WARNING: 4 ObjectDB instances were leaked at exit (run with `--verbose` for details)."
CLEANUP = "   at: cleanup (./core/object/object.cpp:2536)\n"


class GodotChecksTests(unittest.TestCase):
    def test_zero_exit_does_not_hide_diagnostics_on_either_stream(self):
        diagnostics = ["SCRIPT ERROR: bad script", "ERROR: Missing texture", "Parse Error: bad syntax",
                       "SHADER ERROR: bad shader", "UNKNOWN ERROR: unknown", "FATAL: bad failure",
                       "CRASH: bad failure", "handle_crash: Program crashed with signal 11",
                       "CrashHandlerException: Program crashed", "Dumping the backtrace.",
                       "-- END OF C++ BACKTRACE --", "GDScript backtrace (most recent call first):",
                       "WARNING: ObjectDB instances leaked at exit", RETAINED]
        for diagnostic in diagnostics:
            for channel in ("stdout", "stderr"):
                with self.subTest(diagnostic=diagnostic, channel=channel):
                    # A non-newline stdout prefix must not hide a diagnostic on stderr.
                    script = f"import sys; sys.stdout.write('prefix'); print({diagnostic!r}, file=sys.{channel})"
                    if channel == "stdout":
                        script = f"import sys; print({diagnostic!r})"
                    with self.assertRaises(RuntimeError) as caught:
                        checked_run([sys.executable, "-c", script])
                    self.assertIn(diagnostic, str(caught.exception))

    def test_gameplay_crash_event_is_not_an_engine_diagnostic(self):
        event = 'RS_BENCH_EVENT: {"event": "CRASH", "game": "skate"}'
        output = checked_run([sys.executable, "-c", f"print({event!r})"])
        self.assertEqual(output.strip(), event)

    def test_retained_resource_allowance_requires_explicit_forced_startup(self):
        script = f"print({RETAINED!r})"
        for args, allow in (([], False), ([], True), (["--quit-after", "600"], False),
                            (["--", "--quit-after", "600"], True)):
            with self.subTest(args=args, allow=allow), self.assertRaises(RuntimeError):
                checked_run([sys.executable, "-c", script, *args], allow_shutdown_resources=allow)

    def test_allowed_shutdown_diagnostic_and_warning_remain_visible(self):
        for channel in ("stdout", "stderr"):
            for suffix in ("", "\n", "\n   at: clear (core/io/resource.cpp:614)\n"):
                diagnostic = RETAINED + suffix
                script = f"import sys; sys.{channel}.write({diagnostic!r})"
                warning = io.StringIO()
                with self.subTest(channel=channel, suffix=suffix), contextlib.redirect_stdout(warning):
                    output = checked_run([sys.executable, "-c", script, "--quit-after", "600"],
                                         allow_shutdown_resources=True)
                self.assertEqual(output, diagnostic)
                self.assertIn("does not verify clean shutdown", warning.getvalue())

    def test_startup_allowance_does_not_hide_other_errors_or_leaks(self):
        for diagnostic in ("ERROR: Missing texture", "WARNING: ObjectDB instances leaked at exit",
                           RETAINED + " unexpected suffix"):
            script = f"print({RETAINED!r}); print({diagnostic!r})"
            with self.subTest(diagnostic=diagnostic), self.assertRaises(RuntimeError):
                checked_run([sys.executable, "-c", script, "--quit-after", "600"], allow_shutdown_resources=True)

    def test_forced_startup_shutdown_pair_remains_visible_on_either_stream(self):
        for channel in ("stdout", "stderr"):
            for stack in ("", CLEANUP, CLEANUP.replace("./core", "core")):
                for resource_first in (False, True):
                    warning = OBJECTS + "\n" + stack
                    resource = RETAINED + "\n"
                    diagnostic = resource + warning if resource_first else warning + resource
                    script = f"import sys; sys.{channel}.write({diagnostic!r})"
                    notice = io.StringIO()
                    with self.subTest(channel=channel, stack=stack, resource_first=resource_first), \
                         contextlib.redirect_stdout(notice):
                        output = checked_run([sys.executable, "-c", script, "--quit-after", "600"],
                                             allow_shutdown_resources=True)
                    self.assertEqual(output, diagnostic)
                    self.assertIn("forced --quit-after exit", notice.getvalue())
                    self.assertIn("startup check does not verify clean shutdown", notice.getvalue())

    def test_shutdown_pair_requires_explicit_forced_startup(self):
        diagnostic = OBJECTS + "\n" + CLEANUP + RETAINED + "\n"
        for args, allow in (([], False), ([], True), (["--quit-after", "600"], False),
                            (["--", "--quit-after", "600"], True)):
            with self.subTest(args=args, allow=allow):
                with self.assertRaises(RuntimeError) as caught:
                    checked_run([sys.executable, "-c", f"print({diagnostic!r})", *args], allow_shutdown_resources=allow)
                self.assertIn(OBJECTS, str(caught.exception))

    def test_shutdown_pair_does_not_hide_unpaired_or_other_diagnostics(self):
        warning, resource = OBJECTS + "\n", RETAINED + "\n"
        pair = warning + CLEANUP + resource
        scenarios = [(warning, ""), ("", warning), (warning, resource), (resource, warning),
                     (OBJECTS + " unexpected suffix\n" + resource, ""),
                     (warning + CLEANUP.rstrip() + " unexpected suffix\n" + resource, ""),
                     (warning + CLEANUP.replace("core/object/object.cpp", "core/object/unknown.cpp") + resource, ""),
                     (warning + RETAINED + " unexpected suffix\n", ""),
                     (pair + "ERROR: Missing texture\n", ""), (pair, "ERROR: Missing texture\n"),
                     (pair + "WARNING: Other objects leaked at exit\n", "")]
        for stdout, stderr in scenarios:
            script = f"import sys; sys.stdout.write({stdout!r}); sys.stderr.write({stderr!r})"
            with self.subTest(stdout=stdout, stderr=stderr):
                with self.assertRaises(RuntimeError) as caught:
                    checked_run([sys.executable, "-c", script, "--quit-after", "600"], allow_shutdown_resources=True)
                self.assertIn(stdout, str(caught.exception))
                self.assertIn(stderr, str(caught.exception))

    def test_nonzero_exit_preserves_complete_streams_and_code(self):
        stdout, stderr = "FIRST-OUT\n" + "o" * 20000 + "LAST-OUT", "FIRST-ERR\n" + "e" * 20000 + "LAST-ERR"
        script = ("import sys; sys.stdout.write('FIRST-OUT\\n' + 'o' * 20000 + 'LAST-OUT'); "
                  "sys.stderr.write('FIRST-ERR\\n' + 'e' * 20000 + 'LAST-ERR'); sys.exit(7)")
        with self.assertRaises(RuntimeError) as caught:
            checked_run([sys.executable, "-c", script])
        message = str(caught.exception)
        self.assertIn("exit 7 (0x00000007)", message)
        self.assertIn(stdout, message)
        self.assertIn(stderr, message)

    def test_success_preserves_both_streams(self):
        output = checked_run([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"])
        self.assertEqual(output, "out\nerr\n")


if __name__ == "__main__":
    unittest.main()
