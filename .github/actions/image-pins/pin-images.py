#!/usr/bin/python3 -I
"""Helm post-renderer: every ghcr.io/<owner> image by tag becomes tag@digest of the trusted build; anything else of the owner fails."""
import os
import re
import sys

TAG = r"[A-Za-z0-9_][A-Za-z0-9._-]{0,127}"
DIGEST = r"sha256:[0-9a-f]{64}"
IMAGE_LINE = re.compile(r"^(?P<pre>\s*(?:-\s+)?image:\s+)(?P<q>[\"']?)(?P<ref>[^\s\"'#]+)(?P=q)(?P<post>\s*(?:#.*)?)$")


def load_pins(path, prefix):
    name = re.escape(prefix) + r"[a-z0-9][a-z0-9._/-]{0,127}"
    line_re = re.compile(rf"^({name}:{TAG})@({DIGEST})$")
    pins = {}
    with open(path, encoding="utf-8") as f:
        for line in f.read().splitlines():
            match = line_re.match(line)
            if not match:
                raise ValueError(f"bad pin line {line!r}")
            ref, digest = match.groups()
            if pins.get(ref, digest) != digest:
                raise ValueError(f"two digests for {ref}")
            pins[ref] = digest
    if not pins:
        raise ValueError("no pins")
    return pins, re.compile(rf"^{name}(?::{TAG})?@{DIGEST}$")


def render(text, prefix, pins, pinned_re):
    errors = []
    out = []
    for line in text.split("\n"):
        match = IMAGE_LINE.match(line)
        ref = match.group("ref") if match else ""
        if ref.lower().startswith(prefix) and "@" not in ref:
            digest = pins.get(ref)
            if digest is None:
                errors.append(f"no trusted digest for {ref}")
            else:
                q = match.group("q")
                line = f"{match.group('pre')}{q}{ref}@{digest}{q}{match.group('post')}"
        out.append(line)
    result = "\n".join(out)
    for token in re.findall(r"[^\s\"'\[\]{},=]*" + re.escape(prefix) + r"[^\s\"'\[\]{},]*", result, flags=re.IGNORECASE):
        if not pinned_re.match(token):
            errors.append(f"{token} is not an image pinned by digest")
    if errors:
        raise ValueError("; ".join(sorted(set(errors))))
    return result


def main():
    owner = os.environ.get("IMAGE_PINS_OWNER", "")
    path = os.environ.get("IMAGE_PINS_FILE", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,38}", owner) or not path:
        print("pin-images: IMAGE_PINS_OWNER and IMAGE_PINS_FILE are required", file=sys.stderr)
        return 1
    prefix = f"ghcr.io/{owner}/"
    try:
        pins, pinned_re = load_pins(path, prefix)
        sys.stdout.write(render(sys.stdin.read(), prefix, pins, pinned_re))
    except ValueError as e:
        print(f"pin-images: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
