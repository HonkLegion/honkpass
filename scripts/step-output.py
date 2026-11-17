#!/usr/bin/env python3
"""Display one sequential build step; preserve its unmodified output in a log."""
import argparse
import codecs
from collections import deque
import errno
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time
import unicodedata


class Tail:
    """Small terminal-like text buffer, deliberately ignoring escape commands."""

    def __init__(self):
        self.lines = deque(maxlen=3)
        self.current = ""
        self.escape = None
        self.osc_escape = False
        self.after_cr = False

    def feed(self, text):
        for char in text:
            if self.escape == "osc":
                if char == "\a" or (self.osc_escape and char == "\\"):
                    self.escape = None
                self.osc_escape = char == "\x1b"
                continue
            if self.escape == "csi":
                if "@" <= char <= "~":
                    self.escape = None
                continue
            if self.escape == "esc":
                self.escape = "csi" if char == "[" else "osc" if char == "]" else None
                continue
            if char == "\x1b":
                self.escape = "esc"
                continue
            if char == "\r":
                self.after_cr = True
                continue
            if char == "\n":
                self.lines.append(self.current)
                self.current = ""
                self.after_cr = False
                continue
            if self.after_cr:
                self.current = ""
                self.after_cr = False
            if char == "\t":
                self.current = (self.current + " " * (4 - len(self.current) % 4))[-8192:]
            elif not unicodedata.category(char).startswith("C"):
                # Only the visible suffix is needed, even for huge output lines.
                self.current = (self.current + char)[-8192:]

    def rows(self):
        return (list(self.lines) + ([self.current] if self.current else []))[-3:]


def clean(text):
    tail = Tail()
    tail.feed(text)
    return " ".join(tail.rows())


def clipped(text, width):
    result = []
    used = 0
    for char in text:
        size = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1
        if used + size > width:
            break
        result.append(char)
        used += size
    return "".join(result)


class Display:
    def __init__(self, title):
        self.title = clean(title)
        self.tty = (sys.stdout.isatty() and os.environ.get("TERM", "dumb") != "dumb"
                    and os.environ.get("MAKE_PROGRESS") != "plain" and not os.environ.get("CI"))
        self.styled = self.tty and not os.environ.get("NO_COLOR")
        self.previous = None
        self.last_update = 0.0
        self.write(self.paint(self.fit(self.title + "..."), "1;36") + "\n" + ("\n" * 3 if self.tty else ""))

    def paint(self, text, style):
        return f"\x1b[{style}m{text}\x1b[0m" if self.styled and text else text

    def fit(self, text):
        return clipped(text, max(1, shutil.get_terminal_size((80, 24)).columns - 1)) if self.tty else text

    @staticmethod
    def write(text):
        sys.stdout.write(text)
        sys.stdout.flush()

    def update(self, rows):
        now = time.monotonic()
        rendered = tuple(self.fit(row) for row in rows)
        if not self.tty or rendered == self.previous or now - self.last_update < 0.1:
            return
        live_rows = list(rendered) + [""] * (3 - len(rendered))
        self.write("\x1b[3A" + "".join("\r\x1b[K" + self.paint(row, "2") + "\n" for row in live_rows))
        self.previous = rendered
        self.last_update = now

    def finish(self, code, rows, log):
        suffix = ": OK" if code == 0 else f": FAILED (exit {code})"
        title = self.title
        if self.tty:
            width = max(1, shutil.get_terminal_size((80, 24)).columns - 1)
            suffix = clipped(suffix, width)
            title = clipped(title, max(0, width - len(suffix)))
        status = title + suffix
        if self.tty:
            # Own exactly the title and three live rows; leave earlier steps alone.
            styled_status = self.paint(title, "1") + self.paint(suffix, "32" if code == 0 else "31")
            self.write("\x1b[4A\r\x1b[K" + styled_status + "\n"
                       + "\r\x1b[K\n" * 3 + "\x1b[3A")
        else:
            self.write(status + "\n")
        if code:
            for row in rows:
                self.write(self.fit(row) + "\n")
            # A persistent path can wrap safely after the live area is gone.
            self.write("Log: " + clean(str(log)) + "\n")


def run(command, log_path, display):
    tail = Tail()
    process = None
    received_signal = None
    kill_at = None

    def forward(signum, _frame):
        nonlocal received_signal, kill_at
        received_signal = signum
        kill_at = time.monotonic() + 0.8
        if process is not None:
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("wb") as log:
            try:
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, start_new_session=True)
            except OSError as error:
                code = 127 if error.errno == errno.ENOENT else 126
                message = b"Command could not be started (not found).\n" if code == 127 else b"Command could not be started.\n"
                log.write(message)
                tail.feed(message.decode())
                return code, tail.rows()
            if received_signal is not None:
                forward(received_signal, None)
            decoder = codecs.getincrementaldecoder("utf-8")("replace")
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map() or process.poll() is None or kill_at is not None:
                    if kill_at is not None and time.monotonic() >= kill_at:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        kill_at = None
                    for key, _ in selector.select(0.05):
                        data = os.read(key.fd, 65536)
                        if data:
                            log.write(data)
                            log.flush()
                            tail.feed(decoder.decode(data))
                        else:
                            selector.unregister(key.fileobj)
                            tail.feed(decoder.decode(b"", final=True))
                    display.update(tail.rows())
            code = process.wait()
            process.stdout.close()
            return (128 + received_signal if received_signal else 128 - code if code < 0 else code), tail.rows()
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--title", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    display = Display(args.title)
    try:
        code, rows = run(command, args.log, display)
    except OSError:
        code, rows = 1, ["Step output could not be recorded."]
    display.finish(code, rows, args.log)
    return code


if __name__ == "__main__":
    sys.exit(main())
