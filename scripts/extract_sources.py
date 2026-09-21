#!/usr/bin/env python3
"""Safely materialize the published source archive, preserving existing files."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tarfile


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for data in iter(lambda: f.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def extract(root):
    root = root.resolve()
    lock = json.loads((root / "source-lock.json").read_text())
    expected = {p: h for p, h in lock["files"].items() if p.startswith("src/")}
    spec = lock["source_archive"]
    if spec["filename"] != "runtime-source.tar.gz":
        raise ValueError("Unexpected archive name")
    archive = root / spec["filename"]
    if archive.stat().st_size != spec["bytes"] or digest(archive) != spec["sha256"]:
        raise ValueError("Published source archive checksum mismatch")
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        names = [m.name for m in members]
        if len(names) != len(set(names)) or set(names) != set(expected):
            raise ValueError("Archive membership differs from the complete source lock")
        # Verify the entire archive before writing any file. No symlinks,
        # hardlinks, special devices, dot components, or AppleDouble files.
        for member in members:
            parts = PurePosixPath(member.name).parts
            if (not member.isfile() or not parts or parts[0] != "src"
                    or any(p in (".", "..") or p.startswith("._") for p in parts)
                    or str(PurePosixPath(member.name)) != member.name
                    or member.size > 64 * 1024 * 1024):
                raise ValueError("Unsafe source archive member")
            dest = root / member.name
            if not dest.resolve().is_relative_to(root):
                raise ValueError("Source destination escapes checkout")
            if any(p.is_symlink() for p in (dest, *dest.parents) if p != root.parent):
                raise ValueError("Source destination contains a symlink")
            if dest.exists() and (not dest.is_file() or digest(dest) != expected[member.name]):
                raise ValueError("Refusing to overwrite modified existing source: " + member.name)
            stream = tf.extractfile(member)
            h = hashlib.sha256()
            for data in iter(lambda: stream.read(1024 * 1024), b""):
                h.update(data)
            if h.hexdigest() != expected[member.name]:
                raise ValueError("Archived source checksum mismatch: " + member.name)
        written = 0
        for member in members:
            dest = root / member.name
            if dest.exists():
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            with dest.open("xb") as output, tf.extractfile(member) as source:
                for data in iter(lambda: source.read(1024 * 1024), b""):
                    output.write(data)
            os.chmod(dest, 0o755 if dest.suffix == ".sh" else 0o644)
            written += 1
    print(f"Source archive verified; extracted {written} new files without replacing existing content.")


if __name__ == "__main__":
    extract(Path(__file__).resolve().parents[1])
