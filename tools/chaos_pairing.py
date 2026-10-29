#!/usr/bin/env python3
"""Shared test vectors for the short auth string.

Pairing.swift and Pairing.kt each reimplement this. If they drift, every
pairing shows mismatched codes and the user correctly refuses to pair — a
failure that looks like an attack. This file is the third, independent
implementation they are both checked against.

  python3 tools/chaos_pairing.py          # print vectors
  python3 tools/chaos_pairing.py --check  # also compile and check Pairing.swift
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

SALT = "AirScreen-SAS-v1:"


def short_auth_string(mac_fp: str, tv_fp: str) -> str:
    data = (SALT + mac_fp.lower() + ":" + tv_fp.lower()).encode("utf-8")
    digest = hashlib.sha256(data).digest()
    value = int.from_bytes(digest[:8], "big", signed=False)
    return f"{value % 1_000_000:06d}"


def fp(seed: str) -> str:
    return hashlib.sha256(seed.encode()).hexdigest()


VECTORS = [
    (fp("mac-a"), fp("tv-a")),
    (fp("mac-a"), fp("tv-b")),
    (fp("mac-b"), fp("tv-a")),
    ("00" * 32, "ff" * 32),
    ("ff" * 32, "00" * 32),
    # Upper case in, same code out: both sides lower-case before hashing.
    (fp("mac-a").upper(), fp("tv-a")),
    # Chosen because its first 8 digest bytes have bit 63 set, which is where a
    # signed 64-bit modulo on the Kotlin side would disagree.
    (fp("signbit-mac"), fp("signbit-tv")),
]

SWIFT_MAIN = """
let vectors: [(String, String)] = [
%s
]
for (mac, tv) in vectors {
    print(Pairing.shortAuthString(macFingerprint: mac, tvFingerprint: tv))
}
"""


def swift_codes(repo: pathlib.Path):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        rows = ",\n".join(f'    ("{m}", "{t}")' for m, t in VECTORS)
        (tmp / "main.swift").write_text(SWIFT_MAIN % rows)
        binary = tmp / "sas"
        subprocess.run(
            ["swiftc", "-O", "-o", str(binary), str(tmp / "main.swift"),
             str(repo / "mac/Sources/AirScreen/Pairing.swift")],
            check=True, capture_output=True,
        )
        out = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
        return out.stdout.split()


def main():
    repo = pathlib.Path(__file__).resolve().parent.parent
    expected = [short_auth_string(m, t) for m, t in VECTORS]

    if "--json" in sys.argv:
        print(json.dumps(
            [{"mac": m, "tv": t, "code": c} for (m, t), c in zip(VECTORS, expected)],
            indent=2))
        return 0

    width = max(len(str(i)) for i in range(len(VECTORS)))
    for i, ((m, t), code) in enumerate(zip(VECTORS, expected)):
        print(f"{i:>{width}}  {m[:12]}… x {t[:12]}…  -> {code}")

    # A code that depended on only one side would repeat across these.
    assert expected[0] != expected[1], "code must depend on the TV certificate"
    assert expected[0] != expected[2], "code must depend on the Mac certificate"
    assert expected[0] == expected[5], "fingerprint case must not matter"
    assert expected[3] != expected[4], "the two fingerprints must not commute"
    print("\nself-checks passed")

    if "--check" in sys.argv:
        got = swift_codes(repo)
        bad = [(i, e, g) for i, (e, g) in enumerate(zip(expected, got)) if e != g]
        for i, e, g in bad:
            print(f"MISMATCH vector {i}: python={e} swift={g}")
        if bad or len(got) != len(expected):
            print("Pairing.swift DISAGREES")
            return 1
        print(f"Pairing.swift agrees on all {len(expected)} vectors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
