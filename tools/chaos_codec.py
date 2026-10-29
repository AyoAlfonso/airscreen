#!/usr/bin/env python3
"""Chaos/differential test for codec capability negotiation and VP8 fallback."""
import json, socket, time

HOST, PORT = "127.0.0.1", 47890


def connect():
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.settimeout(6)
    return s


def read_offer(s):
    buf = b""
    deadline = time.time() + 6
    while time.time() < deadline:
        try:
            data = s.recv(65536)
        except socket.timeout:
            break
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("t") == "offer":
                return obj["sdp"]
    return None


def first_video_codec(sdp):
    lines = sdp.split("\r\n")
    pt = None
    for line in lines:
        if line.startswith("m=video "):
            parts = line.split()
            if len(parts) > 3:
                pt = parts[3]
            break
    if pt is None:
        return None
    for line in lines:
        if line.startswith(f"a=rtpmap:{pt} "):
            return line.split()[1].split("/")[0].upper()
    return None


def run_case(name, hello, expected):
    s = connect()
    s.sendall((json.dumps(hello) + "\n").encode())
    sdp = read_offer(s)
    s.close()
    if sdp is None:
        raise AssertionError(f"{name}: no offer")
    codec = first_video_codec(sdp)
    if codec != expected:
        raise AssertionError(f"{name}: expected {expected}, got {codec}")
    print(f"PASS {name}: {codec}")


def main():
    base = {"t": "hello", "v": 1, "name": "Chaos TV"}
    cases = [
        ("h264 baseline", {**base, "codecs": ["H264", "VP8"], "h264Profiles": ["42e01f"]}, "H264"),
        ("h264 main profile", {**base, "codecs": ["H264", "VP8"], "h264Profiles": ["4d0032"]}, "VP8"),
        ("vp8 only", {**base, "codecs": ["VP8"]}, "VP8"),
        ("empty codecs", {**base, "codecs": []}, "H264"),
        ("h264 no profiles", {**base, "codecs": ["H264"]}, "H264"),
    ]
    for name, hello, expected in cases:
        run_case(name, hello, expected)
        time.sleep(0.4)

    # Fallback: H.264 first, then request VP8.
    s = connect()
    s.sendall((json.dumps({**base, "codecs": ["H264", "VP8"], "h264Profiles": ["42e01f"]}) + "\n").encode())
    first = read_offer(s)
    if first is None or first_video_codec(first) != "H264":
        raise AssertionError("fallback: baseline offer was not H264")
    s.sendall((json.dumps({"t": "fallback", "reason": "no_video"}) + "\n").encode())
    second = read_offer(s)
    s.close()
    if second is None:
        raise AssertionError("fallback: no second offer")
    codec = first_video_codec(second)
    if codec != "VP8":
        raise AssertionError(f"fallback: expected VP8 after fallback, got {codec}")
    print("PASS fallback: H264 -> VP8")


if __name__ == "__main__":
    main()
