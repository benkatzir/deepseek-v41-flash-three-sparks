#!/usr/bin/env python3
"""Validate checked-in runtime files without Torch, model loading, or network."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
lock = json.loads((root / "source-lock.json").read_text())
for relative, expected in lock["files"].items():
    path = (root / relative).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise SystemExit("Missing or escaping source: " + relative)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit("Runtime source checksum mismatch: " + relative)
for package in ("src/cooperative/component", "src/cooperative/integration", "src/target-k"):
    directory = root / package
    manifest = json.loads((directory / "manifest.json").read_text())
    for relative, expected in manifest["files"].items():
        path = directory / relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SystemExit("Component source checksum mismatch: " + str(path.relative_to(root)))
print(f"PASS: {len(lock['files'])} runtime files; this does not validate a rebuilt image or model quality.")
