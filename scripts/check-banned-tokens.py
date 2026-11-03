#!/usr/bin/env python3
"""Fails when a file contains a banned token. The banned tokens are stored only as SHA-256 hashes, never as text.

    python3 -I scripts/check-banned-tokens.py HASHFILE PATH...      (PATH "-" reads standard input)

A token is a run of letters, a run of digits, or a camel-case part of a letter run, all lowercased. The hash file has one
"<length> <sha256 hex>" per line. Prints the file name (never the token) for each hit and exits 1. Keep the tokenizer in step with
BannedTokenScan in ShepCore/Tests/BannedTokenScan.swift.
"""
import hashlib
import re
import sys


def load_hashes(path):
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            length, digest = line.split()
            out.add((int(length), digest.lower()))
    return out


def tokens(text):
    found = set()
    for run in re.findall(r"[^\W\d_]+|\d+", text):
        found.add(run.lower())
        if run.isalpha():
            for part in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[A-Z]+", run):
                found.add(part.lower())
    return found


def hit(text, hashes):
    lengths = {n for n, _ in hashes}
    digests = {d for _, d in hashes}
    for token in tokens(text):
        if len(token) in lengths and hashlib.sha256(token.encode("utf-8")).hexdigest() in digests:
            return True
    return False


def main(argv):
    if len(argv) < 3:
        print("usage: check-banned-tokens.py HASHFILE PATH...", file=sys.stderr)
        return 2
    hashes = load_hashes(argv[1])
    bad = 0
    for path in argv[2:]:
        try:
            text = sys.stdin.read() if path == "-" else open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        if hit(text, hashes):
            print(path)
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
