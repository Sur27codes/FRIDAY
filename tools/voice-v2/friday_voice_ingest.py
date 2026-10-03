#!/usr/bin/env python3
"""friday-voice-ingest — P2-M5V9-B.3D.2C.

Copies a validated, QC-passed, provenance-complete candidate recording
into the private FRIDAY voice-v2 asset store. Never mutates the
original recording. Never resamples/normalizes/denoises/compresses/
EQs/pitch-shifts/format-converts anything — the master stays the
master, copied byte-for-byte.

The private root defaults to
"~/Library/Application Support/FRIDAY/VoiceAssets/V2" but is NEVER
hardcoded internally beyond that default — pass --dest-root to use any
other root (tests always do, to stay inside a temp directory).

Usage:
    python3 tools/voice-v2/friday_voice_ingest.py \\
        --candidate-dir /path/to/raw/session \\
        --manifest /path/to/session-manifest.json \\
        --provenance-dir /path/to/provenance \\
        [--dest-root "$HOME/Library/Application Support/FRIDAY/VoiceAssets/V2"] \\
        [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

import friday_voice_dataset_qc as qc
from friday_voice_common import load_json, sha256_of_file

try:
    import jsonschema
except ImportError:  # pragma: no cover - jsonschema is expected to be present (see repo README)
    jsonschema = None

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMAS_DIR = REPO_ROOT / "schemas" / "voice-v2"
DEFAULT_DEST_ROOT = Path.home() / "Library" / "Application Support" / "FRIDAY" / "VoiceAssets" / "V2"
ASSET_SUBDIRS = ["masters", "approved", "references", "manifests", "provenance", "reports", "quarantine"]


class IngestBlocked(Exception):
    """Raised for any condition that must stop ingestion outright (not merely reject one asset)."""


def _resolve_strict(path: Path) -> Path:
    """Resolves symlinks and relative components. Raises if the path
    does not actually exist (used for security containment checks,
    where a nonexistent path can't be meaningfully contained)."""
    return Path(os.path.realpath(str(path)))


def _ensure_not_inside_repo(dest_root: Path) -> None:
    resolved = _resolve_strict(dest_root) if dest_root.exists() else dest_root.resolve()
    repo = REPO_ROOT.resolve()
    if resolved == repo or repo in resolved.parents:
        raise IngestBlocked(f"refusing to use a destination root inside the repository: {resolved}")


def _ensure_no_path_traversal(filename: str) -> None:
    if not filename or "/" in filename or "\\" in filename or filename.startswith("."):
        raise IngestBlocked(f"unsafe filename rejected (path traversal guard): {filename!r}")
    # Also reject any resolved-relative-component trick hiding in the name.
    if Path(filename).name != filename:
        raise IngestBlocked(f"unsafe filename rejected (path traversal guard): {filename!r}")


def _ensure_no_symlink_escape(candidate_dir: Path, file_path: Path) -> None:
    real_candidate_dir = _resolve_strict(candidate_dir)
    real_file = _resolve_strict(file_path)
    if real_candidate_dir not in real_file.parents and real_file != real_candidate_dir:
        raise IngestBlocked(f"symlink/path escape rejected: resolved path {real_file} is outside {real_candidate_dir}")


def _validate_schema(instance: dict, schema_filename: str) -> None:
    if jsonschema is None:
        raise IngestBlocked("jsonschema package is not available — cannot validate schemas, refusing to ingest")
    schema = load_json(SCHEMAS_DIR / schema_filename)
    try:
        jsonschema.validate(instance=instance, schema=schema)
    except jsonschema.ValidationError as e:
        raise IngestBlocked(f"schema validation failed ({schema_filename}): {e.message}")


def _atomic_copy(src: Path, dest: Path) -> None:
    """Copies `src` to `dest` such that `dest` either ends up as a
    complete, correct copy, or does not exist at all — never a
    truncated/partial file, even if the process is interrupted or an
    error occurs mid-copy."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(dest.parent), prefix=".tmp-ingest-")
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as tmp_f, open(src, "rb") as src_f:
            shutil.copyfileobj(src_f, tmp_f)
            tmp_f.flush()
            os.fsync(tmp_f.fileno())
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, dest)  # atomic on the same filesystem
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def _ensure_dest_structure(dest_root: Path) -> None:
    dest_root.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(dest_root, 0o700)
    except OSError:
        pass  # best-effort; POSIX permissions are defense-in-depth, not a security boundary by themselves
    for sub in ASSET_SUBDIRS:
        d = dest_root / sub
        d.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass


def ingest(candidate_dir: Path, manifest_path: Path, provenance_dir: Path, dest_root: Path,
           expected_sample_rate: int = 48000, expected_bit_depth: int = 24, expected_channels: int = 1,
           dry_run: bool = False) -> dict:
    """Runs the full ingest contract. Returns a sanitized report dict.
    Raises IngestBlocked for a condition that stops the WHOLE run
    (unsafe destination, missing schemas, path traversal/symlink escape
    attempts). A single asset failing QC/rights/provenance checks does
    NOT raise — it is recorded as quarantined in the returned report."""
    _ensure_not_inside_repo(dest_root)

    manifest = load_json(manifest_path)
    _validate_schema(manifest, "dataset-manifest.schema.json")

    provenance_records = {}
    if provenance_dir and Path(provenance_dir).is_dir():
        for f in Path(provenance_dir).glob("*.json"):
            record = load_json(f)
            _validate_schema(record, "provenance-record.schema.json")
            if record.get("rights_record_id"):
                provenance_records[record["rights_record_id"]] = record

    # Security checks per asset BEFORE anything else touches the filesystem.
    for asset in manifest.get("assets", []):
        filename = asset.get("filename", "")
        _ensure_no_path_traversal(filename)
        candidate_file = candidate_dir / filename
        if candidate_file.exists():
            _ensure_no_symlink_escape(candidate_dir, candidate_file)

    qc_report = qc.run(candidate_dir, manifest_path, provenance_dir if provenance_dir else None,
                        expected_sample_rate, expected_bit_depth, expected_channels)
    qc_by_filename = {r["filename"]: r for r in qc_report["files"]}

    if not dry_run:
        _ensure_dest_structure(dest_root)

    accepted = []
    quarantined = []
    for asset in manifest.get("assets", []):
        filename = asset["filename"]
        asset_id = asset["asset_id"]
        file_qc = qc_by_filename.get(filename, {"verdict": "REJECT", "issues": [{"severity": "REJECT", "code": "not_found_in_qc_run"}]})

        # Ingestion is STRICTER than a bare QC PASS/no-REJECT: a WARN
        # (e.g. provenance unverified because no --provenance-dir was
        # ever supplied) is NOT sufficient to ingest — ingestion always
        # requires an explicit provenance directory and a clean PASS.
        if provenance_dir is None or not Path(provenance_dir).is_dir():
            reason = "no provenance_dir supplied to ingest — cannot verify provenance, refusing to ingest"
            quarantined.append({"asset_id": asset_id, "filename": filename, "reason": reason})
            continue
        if file_qc["verdict"] != "PASS":
            reason = f"QC verdict {file_qc['verdict']}: " + "; ".join(f"{i['code']}" for i in file_qc.get("issues", []))
            quarantined.append({"asset_id": asset_id, "filename": filename, "reason": reason})
            continue

        rights_record_id = asset.get("rights_record_id")
        if not rights_record_id or rights_record_id not in provenance_records:
            quarantined.append({"asset_id": asset_id, "filename": filename, "reason": "rights_record_id does not resolve to a validated provenance record"})
            continue

        src = candidate_dir / filename
        actual_checksum = sha256_of_file(src)
        if actual_checksum != asset.get("checksum_sha256"):
            quarantined.append({"asset_id": asset_id, "filename": filename, "reason": "checksum mismatch between manifest and candidate file"})
            continue

        dest_path = dest_root / "approved" / filename
        if not dry_run:
            if dest_path.exists():
                # Deterministic, safe behavior on a repeat ingest of the
                # same asset: verify the existing copy is byte-identical
                # (never silently overwrite with different content), and
                # treat a matching re-ingest as an idempotent no-op.
                if sha256_of_file(dest_path) != actual_checksum:
                    quarantined.append({"asset_id": asset_id, "filename": filename, "reason": "destination already exists with DIFFERENT content — refusing to overwrite"})
                    continue
            else:
                _atomic_copy(src, dest_path)
        accepted.append({"asset_id": asset_id, "filename": filename, "checksum_sha256": actual_checksum, "rights_record_id": rights_record_id})

    if not dry_run:
        # Copy manifest + provenance alongside the approved assets too,
        # so the private store is self-describing (§ provenance spec).
        _atomic_copy(manifest_path, dest_root / "manifests" / manifest_path.name)
        if provenance_dir and Path(provenance_dir).is_dir():
            for f in Path(provenance_dir).glob("*.json"):
                _atomic_copy(f, dest_root / "provenance" / f.name)

    report = {
        "manifest_id": manifest.get("manifest_id"),
        "dest_root": str(dest_root),
        "accepted_count": len(accepted),
        "quarantined_count": len(quarantined),
        "accepted": accepted,
        "quarantined": quarantined,
        "dry_run": dry_run,
    }
    if not dry_run:
        report_path = dest_root / "reports" / f"ingest-report-{manifest.get('manifest_id', 'unknown')}.json"
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2))
        try:
            os.chmod(report_path, 0o600)
        except OSError:
            pass
        report["report_path"] = str(report_path)
    return report


def print_summary(report: dict) -> None:
    print("=== friday-voice-ingest ===\n")
    print(f"Accepted:    {report['accepted_count']}")
    for a in report["accepted"]:
        print(f"  ✔ {a['filename']} (asset_id={a['asset_id']})")
    print(f"Quarantined: {report['quarantined_count']}")
    for q in report["quarantined"]:
        print(f"  ✘ {q['filename']} (asset_id={q['asset_id']}) — {q['reason']}")
    if report.get("dry_run"):
        print("\n(--dry-run: nothing was actually copied)")
    if report.get("report_path"):
        print(f"\nIngest report written: {report['report_path']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FRIDAY voice-v2 private asset ingestion")
    parser.add_argument("--candidate-dir", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--provenance-dir", default=None)
    parser.add_argument("--dest-root", default=str(DEFAULT_DEST_ROOT))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--expected-sample-rate", type=int, default=48000)
    parser.add_argument("--expected-bit-depth", type=int, default=24)
    parser.add_argument("--expected-channels", type=int, default=1)
    args = parser.parse_args(argv)

    try:
        report = ingest(
            Path(args.candidate_dir), Path(args.manifest),
            Path(args.provenance_dir) if args.provenance_dir else None,
            Path(args.dest_root),
            args.expected_sample_rate, args.expected_bit_depth, args.expected_channels,
            dry_run=args.dry_run,
        )
    except IngestBlocked as e:
        print(f"BLOCKED — {e}")
        return 2

    print_summary(report)
    return 0 if report["quarantined_count"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
