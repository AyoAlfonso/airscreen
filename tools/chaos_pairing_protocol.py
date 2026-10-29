#!/usr/bin/env python3
"""Chaos-test the Mac's pairing and authorisation state machine.

Speaks the real protocol to the real app over real TLS, so the oracle is the
running implementation rather than a transcription of it. Every scenario
asserts the same safety property from a different angle:

    the Mac must not send an `offer` — it must not capture anything — unless
    the TV presented a certificate it has already approved, or the user
    approved it in this session.

Usage:  python3 tools/chaos_pairing_protocol.py [--app PATH] [--keep]
"""
import argparse
import json
import os
import pathlib
import shutil
import socket
import ssl
import subprocess
import sys
import signal
import tempfile
import time
import hashlib

# macOS ships a LibreSSL-backed python3 that cannot speak TLS 1.3, and the Mac
# requires it. Re-exec into an interpreter that can rather than failing with a
# protocol-version error a long way from the cause.
if not getattr(ssl, "HAS_TLSv1_3", False):
    for _candidate in ("/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                       shutil.which("python3.13"), shutil.which("python3.12")):
        if not _candidate or not os.path.exists(_candidate):
            continue
        _probe = subprocess.run([_candidate, "-c", "import ssl;print(ssl.HAS_TLSv1_3)"],
                                capture_output=True, text=True)
        if _probe.stdout.strip() == "True":
            os.execv(_candidate, [_candidate, os.path.abspath(__file__)] + sys.argv[1:])
    sys.exit(f"need a python with TLS 1.3; {ssl.OPENSSL_VERSION} cannot")

PORT = 47890
HOST = "127.0.0.1"
SUPPORT = pathlib.Path.home() / "Library/Application Support/AirScreen"
PAIRED = SUPPORT / "paired.json"
DEFAULT_APP = (pathlib.Path(__file__).resolve().parent.parent
               / "mac/build/Build/Products/Debug/AirScreen.app/Contents/MacOS/AirScreen")

# `paired` is deliberately absent from the base message: a TV that does not
# claim to hold its half of the pair must be asked again.
# `paired` is deliberately absent from the base message: a TV that does not
# claim to hold its half of the pair must be asked again.
HELLO = {
    "t": "hello", "v": 1, "name": "Chaos TV",
    "codecs": ["H264", "VP8"], "h264Profiles": ["42e01f"],
    "audioCodecs": ["opus", "pcm16"], "maxWidth": 1920, "maxHeight": 1080,
}


class Client:
    """One TLS session, with the newline-JSON framing the protocol specifies."""

    def __init__(self, certdir, with_cert=True, timeout=10):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        if with_cert:
            ctx.load_cert_chain(certdir / "tv.pem", certdir / "tv.key")
        raw = socket.create_connection((HOST, PORT), timeout=timeout)
        self.sock = ctx.wrap_socket(raw, server_hostname="airscreen")
        self.sock.settimeout(timeout)
        self.buf = b""

    def send_raw(self, data: bytes):
        self.sock.sendall(data)

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read_until(self, deadline_s, stop_types=()):
        """Collect messages until a stop type arrives or the deadline passes."""
        got = []
        end = time.time() + deadline_s
        while time.time() < end:
            self.sock.settimeout(max(0.2, end - time.time()))
            try:
                chunk = self.sock.recv(65536)
            except (socket.timeout, ssl.SSLWantReadError):
                continue
            except (ConnectionResetError, OSError):
                got.append({"t": "__closed__"})
                break
            if not chunk:
                got.append({"t": "__closed__"})
                break
            self.buf += chunk
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    got.append(json.loads(line))
                except json.JSONDecodeError:
                    got.append({"t": "__unparseable__", "raw": line[:120].decode("utf8", "replace")})
            if stop_types and any(m.get("t") in stop_types for m in got):
                break
        return got

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def make_cert(certdir):
    subprocess.run(
        ["/usr/bin/openssl", "req", "-x509", "-sha256", "-newkey", "rsa:2048", "-nodes",
         "-days", "2", "-subj", "/CN=Chaos TV",
         "-keyout", str(certdir / "tv.key"), "-out", str(certdir / "tv.pem")],
        check=True, capture_output=True)
    der = subprocess.run(
        ["/usr/bin/openssl", "x509", "-in", str(certdir / "tv.pem"), "-outform", "DER"],
        check=True, capture_output=True).stdout
    return hashlib.sha256(der).hexdigest()


class App:
    def __init__(self, binary):
        self.binary = binary
        self.proc = None
        self.log = None

    def start(self, paired_fingerprint=None):
        self.stop()
        SUPPORT.mkdir(parents=True, exist_ok=True)
        if paired_fingerprint:
            PAIRED.write_text(json.dumps({paired_fingerprint: {
                "name": "Chaos TV",
                "pairedAt": "2026-01-01T00:00:00Z",
                "lastSeenAt": "2026-01-01T00:00:00Z"}}))
        elif PAIRED.exists():
            PAIRED.unlink()
        self.log = tempfile.NamedTemporaryFile(prefix="chaos-mac-", suffix=".log", delete=False)
        env = dict(os.environ, AIRSCREEN_AUTOSTART="1")
        self.proc = subprocess.Popen([str(self.binary)], stdout=self.log, stderr=subprocess.STDOUT, env=env)
        for _ in range(60):
            time.sleep(0.25)
            with socket.socket() as s:
                s.settimeout(0.3)
                if s.connect_ex((HOST, PORT)) == 0:
                    time.sleep(0.4)
                    return
        raise RuntimeError("app never listened on 47890")

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None
        subprocess.run(["pkill", "-x", "AirScreen"], capture_output=True)
        time.sleep(0.5)

    def log_text(self):
        return pathlib.Path(self.log.name).read_text() if self.log else ""


RESULTS = []


def record(name, ok, detail):
    RESULTS.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")


def types(msgs):
    return [m.get("t") for m in msgs]


def run(app, certdir, fingerprint):
    # ---- unpaired Mac -------------------------------------------------
    print("\n[unpaired Mac]")

    app.start()
    c = Client(certdir, with_cert=False)
    msgs = c.read_until(6, stop_types=("error", "__closed__"))
    # Refused by the TLS layer itself (alert 116, certificate_required), before
    # any application message can be sent — so "no reason on the wire" is the
    # correct outcome here, unlike every other refusal below.
    record("no client certificate is refused at the handshake",
           types(msgs) == ["__closed__"],
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    msgs = c.read_until(9, stop_types=("error", "__closed__"))
    record("a TV that never says hello is dropped",
           "offer" not in types(msgs) and ("error" in types(msgs) or "__closed__" in types(msgs)),
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    c.send(dict(HELLO, v=2))
    msgs = c.read_until(6, stop_types=("error", "__closed__"))
    record("an unknown protocol version is refused",
           "offer" not in types(msgs) and any(
               m.get("code") == "unsupported_version" for m in msgs),
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    c.send(HELLO)
    msgs = c.read_until(8)
    record("an unapproved TV gets a prompt and no stream",
           "pair-required" in types(msgs) and "offer" not in types(msgs),
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    c.send(HELLO)
    time.sleep(0.5)
    # Pretend the handshake already happened.
    c.send({"t": "answer", "sdp": "v=0\r\n"})
    c.send({"t": "ice", "candidate": "candidate:1 1 udp 1 1.2.3.4 1 typ host",
            "sdpMid": "0", "sdpMLineIndex": 0})
    c.send({"t": "paired"})          # the TV does not get to say this
    c.send({"t": "pair-confirm"})    # nor this
    msgs = c.read_until(7)
    record("a TV cannot approve itself",
           "offer" not in types(msgs),
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    c.send_raw(b"{not json at all\n")
    msgs = c.read_until(5, stop_types=("error",))
    record("malformed JSON is reported, not fatal",
           any(m.get("code") == "bad_json" for m in msgs),
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    c.send_raw(b"x" * 70_000)   # no newline: the buffer must not grow forever
    msgs = c.read_until(6, stop_types=("error", "__closed__"))
    record("an unterminated oversized line is cut, with a reason",
           any(m.get("code") == "line_too_long" for m in msgs),
           f"saw {types(msgs)}")
    c.close()

    app.start()
    c = Client(certdir)
    c.send({"t": "wat", "sdp": "nonsense"})
    time.sleep(0.5)
    c.send(HELLO)
    msgs = c.read_until(7)
    record("an unknown message type does not break the session",
           "pair-required" in types(msgs),
           f"saw {types(msgs)}")
    c.close()

    # ---- already-approved Mac ----------------------------------------
    print("\n[Mac that has already approved this TV]")

    app.start(paired_fingerprint=fingerprint)
    c = Client(certdir)
    c.send(dict(HELLO, paired=True))
    msgs = c.read_until(8, stop_types=("offer",))
    record("an approved TV streams without another prompt",
           "offer" in types(msgs) and "pair-required" not in types(msgs),
           f"saw {types(msgs)}")
    codec = next((m for m in msgs if m.get("t") == "codec"), None)
    record("the announced audio codec is one this TV offered",
           codec is not None and codec.get("audioCodec") in HELLO["audioCodecs"],
           f"codec message {codec}")
    c.close()

    app.start(paired_fingerprint=fingerprint)
    c = Client(certdir)
    c.send(dict(HELLO, paired=True))
    time.sleep(1.5)
    c.send(dict(HELLO, paired=True))
    msgs = c.read_until(7)
    record("a repeated hello does not start a second session",
           types(msgs).count("offer") == 1,
           f"saw {types(msgs)}")
    c.close()

    app.start(paired_fingerprint=fingerprint)
    c = Client(certdir)
    c.send(dict(HELLO, paired=True, audioCodecs=["pcm16"]))
    msgs = c.read_until(8, stop_types=("offer",))
    codec = next((m for m in msgs if m.get("t") == "codec"), None)
    record("a PCM-only TV is not sent Opus",
           codec is not None and codec.get("audioCodec") == "pcm16",
           f"codec message {codec}")
    c.close()

    app.start(paired_fingerprint=fingerprint)
    c = Client(certdir)
    c.send(dict(HELLO, paired=True, audioCodecs=[]))
    msgs = c.read_until(8, stop_types=("offer",))
    codec = next((m for m in msgs if m.get("t") == "codec"), None)
    record("a TV offering no audio codec is not sent Opus",
           codec is not None and codec.get("audioCodec") == "pcm16",
           f"codec message {codec}")
    c.close()

    # Both halves of the pair must survive. If only the Mac remembers, it must
    # ask again rather than stream to a TV that will refuse the offer and leave
    # no way back. Reproduced on device before this rule existed.
    app.start(paired_fingerprint=fingerprint)
    c = Client(certdir)
    c.send(dict(HELLO, paired=False))
    msgs = c.read_until(8)
    record("a TV that lost its pin is asked again, not streamed to",
           "pair-required" in types(msgs) and "offer" not in types(msgs),
           f"saw {types(msgs)}")
    c.close()

    app.start(paired_fingerprint=fingerprint)
    c = Client(certdir)
    c.send(HELLO)   # says nothing about having pinned this Mac
    msgs = c.read_until(8)
    record("a TV silent about its pin is asked again (fails closed)",
           "pair-required" in types(msgs) and "offer" not in types(msgs),
           f"saw {types(msgs)}")
    c.close()

    # A different certificate must not inherit the approval.
    app.start(paired_fingerprint=fingerprint)
    other = pathlib.Path(tempfile.mkdtemp())
    make_cert(other)
    c = Client(other)
    c.send(dict(HELLO, paired=True))
    msgs = c.read_until(8)
    record("approval does not transfer to a different certificate",
           "pair-required" in types(msgs) and "offer" not in types(msgs),
           f"saw {types(msgs)}")
    c.close()
    shutil.rmtree(other, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=str(DEFAULT_APP))
    ap.add_argument("--keep", action="store_true", help="leave the app running")
    args = ap.parse_args()

    binary = pathlib.Path(args.app)
    if not binary.exists():
        print(f"no app at {binary}; run ./scripts/build-mac.sh first")
        return 2

    certdir = pathlib.Path(tempfile.mkdtemp(prefix="chaos-tv-"))
    fingerprint = make_cert(certdir)
    print(f"chaos TV certificate {fingerprint[:16]}…")

    app = App(binary)
    backup = PAIRED.read_text() if PAIRED.exists() else None

    # Interrupted runs used to leave an AirScreen holding :47890 and a client
    # still connecting, which looks exactly like a product bug the next time
    # anyone tests by hand. Tear down on the way out.
    def bail(signum, _frame):
        app.stop()
        if backup is not None:
            PAIRED.write_text(backup)
        elif PAIRED.exists():
            PAIRED.unlink()
        sys.exit(130)

    signal.signal(signal.SIGINT, bail)
    signal.signal(signal.SIGTERM, bail)
    signal.signal(signal.SIGHUP, bail)

    try:
        run(app, certdir, fingerprint)
    finally:
        if not args.keep:
            app.stop()
        if backup is not None:
            PAIRED.write_text(backup)
        elif PAIRED.exists():
            PAIRED.unlink()
        shutil.rmtree(certdir, ignore_errors=True)

    failed = [n for n, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    if failed:
        print("FAILED:")
        for n in failed:
            print(f"  - {n}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
