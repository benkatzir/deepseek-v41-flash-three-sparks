#!/usr/bin/env python3
"""Download fixed revisions and verify every weight shard; never load a model."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path

MODELS = [
    ("deepseek-ai/DeepSeek-V4.1-Flash", "fb2764a5cf321eaa5070ca8f9e892818f477c16d", "DeepSeek-V4.1-Flash-native", "native-checksums.json"),
    ("bot-lab-21/DeepSeek-V4.1-Flash-EXL3-3.5bpw-Pollard", "f129e31a81e1337aa33e129e2d847fc7e37c8733", "DeepSeek-V4.1-Flash-EXL3-3.5", "exl3-download.json"),
]


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data-dir", required=True, type=Path)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--only", choices=("native", "exl3"))
    a = p.parse_args()
    root = a.data_dir.expanduser().resolve()
    (root / "state").mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(root / "hf-cache"))
    from huggingface_hub import HfApi, snapshot_download
    api = HfApi()
    native_results = {}
    prior = root / "state/native-checksums.json"
    if prior.is_file():
        old = json.loads(prior.read_text())
        if old.get("passed") and old.get("revision") == MODELS[0][1]:
            native_results = old.get("results", {})
    for i, (repo, revision, directory, receipt_name) in enumerate(MODELS):
        if a.only and a.only != ("native" if i == 0 else "exl3"):
            continue
        metadata = api.model_info(repo, revision=revision, files_metadata=True)
        if metadata.sha != revision:
            raise RuntimeError("Repository revision did not resolve to the pinned commit")
        target = root / "models" / directory
        target.mkdir(parents=True, exist_ok=True)
        specs = {}
        for item in metadata.siblings:
            if not item.rfilename.endswith(".safetensors"):
                continue
            if Path(item.rfilename).name != item.rfilename or item.lfs is None:
                raise RuntimeError("Unexpected shard layout or missing LFS integrity metadata")
            specs[item.rfilename] = {"sha256": item.lfs.sha256, "bytes": item.size}
        if len(specs) != 48:
            raise RuntimeError("Pinned checkpoint must contain exactly 48 safetensors shards")
        reused = []
        # Eight complete native shards are identical to the Pollard release.
        # Verify bytes again before making hardlinks; never trust a receipt alone.
        if i == 1:
            native = root / "models" / MODELS[0][2]
            for name, expected in specs.items():
                known = native_results.get(name, {})
                source = native / name
                dest = target / name
                if (known.get("sha256"), known.get("bytes")) != (expected["sha256"], expected["bytes"]):
                    continue
                if not source.is_file() or source.stat().st_size != expected["bytes"] or digest(source) != expected["sha256"]:
                    continue
                if not dest.exists():
                    os.link(source, dest)
                    reused.append(name)
        print(f"Downloading pinned {repo}; reusing {len(reused)} verified native shards", flush=True)
        snapshot_download(repo_id=repo, revision=revision, local_dir=target,
                          ignore_patterns=reused, max_workers=a.workers)
        results = {}
        for name, expected in sorted(specs.items()):
            file = target / name
            actual = {"sha256": digest(file), "bytes": file.stat().st_size}
            passed = actual == expected
            results[name] = dict(actual, passed=passed)
            print(f"{directory}/{name}: {'PASS' if passed else 'FAIL'}", flush=True)
            if not passed:
                raise RuntimeError("Weight shard checksum mismatch")
        index = json.loads((target / "model.safetensors.index.json").read_text())
        if set(index["weight_map"].values()) != set(specs):
            raise RuntimeError("Model index and pinned shard list disagree")
        record = dict(repo=repo, revision=revision, complete=True, passed=True,
                      results=results, reused_native_shards=reused,
                      completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      runtime_load_verified=False)
        dest = root / "state" / receipt_name
        temp = dest.with_suffix(".tmp")
        temp.write_text(json.dumps(record, indent=2) + "\n")
        temp.replace(dest)
        if i == 0:
            native_results = results


if __name__ == "__main__":
    main()
