#!/usr/bin/env python3
"""friday-voice-dataset-qc — P2-M5V9-B.3D.2B.

Validates a FRIDAY voice-v2 dataset directory against its manifest:
per-file WAV/signal checks, and manifest/provenance consistency checks.
Never performs speaker recognition, voice biometrics, identity
embedding, or gender/age/emotion inference — objective signal
statistics only (see friday_voice_common.py's module docstring).

Never prints speech transcripts by default (privacy-safe logs) — pass
--verbose-transcripts to opt into printing them for local debugging only.

Usage:
    python3 tools/voice-v2/friday_voice_dataset_qc.py \\
        --dataset "$HOME/Library/Application Support/FRIDAY/VoiceAssets/V2/masters" \\
        --manifest "$HOME/Library/Application Support/FRIDAY/VoiceAssets/V2/manifests/session-001.json" \\
        [--provenance-dir "$HOME/Library/Application Support/FRIDAY/VoiceAssets/V2/provenance"] \\
        [--json-report /tmp/qc-report.json] [--fail-on reject|warn] [--dry-run] \\
        [--expected-sample-rate 48000] [--expected-bit-depth 24] [--expected-channels 1]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from friday_voice_common import (
    DELIVERY_MODES,
    WAVContainerError,
    analyze_wav,
    find_duplicate_asset_ids,
    load_json,
    load_provenance_records,
)


def check_asset(asset: dict, dataset_dir: Path, provenance_records: dict, duplicate_ids: set,
                 expected_sample_rate: int, expected_bit_depth: int, expected_channels: int) -> dict:
    """Runs every per-asset check and returns a report dict with a
    PASS/WARN/REJECT verdict and the list of issues found."""
    issues: list[dict] = []

    def reject(code: str, detail: str = "") -> None:
        issues.append({"severity": "REJECT", "code": code, "detail": detail})

    def warn(code: str, detail: str = "") -> None:
        issues.append({"severity": "WARN", "code": code, "detail": detail})

    asset_id = asset.get("asset_id")
    filename = asset.get("filename")

    # --- manifest-shape checks (independent of the file on disk) ---
    if not asset.get("transcript"):
        reject("empty_transcript")
    if asset.get("delivery_mode") not in DELIVERY_MODES:
        reject("invalid_delivery_mode", str(asset.get("delivery_mode")))
    if not asset.get("speaker_id"):
        reject("missing_speaker_id")
    if not asset.get("session_id"):
        reject("missing_session_id")
    rights_record_id = asset.get("rights_record_id")
    if not rights_record_id:
        reject("missing_rights_record")
    if not isinstance(asset.get("approved"), bool):
        reject("invalid_approved_field")
    if asset_id in duplicate_ids:
        reject("duplicate_asset_id")

    # --- provenance resolvability (the hard gate) ---
    if rights_record_id:
        if provenance_records is not None:
            # A provenance directory WAS explicitly supplied — verification
            # was requested, so a non-resolving reference is a REJECT, even
            # if that directory turned out to be empty/misconfigured.
            if rights_record_id not in provenance_records:
                reject("missing_provenance", "rights_record_id does not resolve to any loaded provenance record")
        else:
            # No --provenance-dir was supplied at all — we cannot
            # independently confirm provenance. This is a WARN, not a
            # silent PASS: the field is present, but unverified.
            warn("provenance_unverified", "no --provenance-dir supplied; only the manifest field's presence was checked")

    # --- file-existence / manifest-consistency checks ---
    file_path = dataset_dir / filename if filename else None
    if file_path is None or not file_path.is_file():
        reject("file_missing", str(filename))
        return {"asset_id": asset_id, "filename": filename, "issues": issues, "verdict": _verdict(issues)}

    if filename != asset.get("filename"):  # defensive; always true by construction above, kept for clarity
        reject("filename_mismatch")

    # --- WAV container / signal checks ---
    try:
        stats = analyze_wav(file_path)
    except WAVContainerError as e:
        reject("corrupt_wav", str(e))
        return {"asset_id": asset_id, "filename": filename, "issues": issues, "verdict": _verdict(issues)}

    if stats.frame_count == 0:
        reject("zero_length_audio")
    if stats.channels != expected_channels:
        reject("wrong_channel_count", f"expected {expected_channels}, got {stats.channels}")
    if stats.sample_rate != expected_sample_rate:
        reject("wrong_sample_rate", f"expected {expected_sample_rate}, got {stats.sample_rate}")
    if stats.bit_depth != expected_bit_depth:
        reject("wrong_bit_depth", f"expected {expected_bit_depth}, got {stats.bit_depth}")
    if stats.clipped_sample_count > 0:
        reject("clipping", f"{stats.clipped_sample_count} clipped samples")
    if stats.silence_ratio >= 0.95:
        reject("unexpected_silence", f"silence_ratio={stats.silence_ratio:.3f}")
    if abs(stats.dc_offset) > 0.10:
        reject("dc_offset_extreme", f"dc_offset={stats.dc_offset:.4f}")
    elif abs(stats.dc_offset) > 0.02:
        warn("dc_offset_elevated", f"dc_offset={stats.dc_offset:.4f}")
    if stats.leading_silence_ms > 3000:
        warn("long_leading_silence", f"{stats.leading_silence_ms:.0f}ms")
    if stats.trailing_silence_ms > 3000:
        warn("long_trailing_silence", f"{stats.trailing_silence_ms:.0f}ms")

    declared_checksum = asset.get("checksum_sha256")
    if declared_checksum and declared_checksum != stats.checksum_sha256:
        reject("checksum_mismatch")

    return {
        "asset_id": asset_id,
        "filename": filename,
        "sample_rate": stats.sample_rate,
        "bit_depth": stats.bit_depth,
        "channels": stats.channels,
        "duration_ms": round(stats.duration_ms, 1),
        "peak_dbfs": None if stats.peak_dbfs == float("-inf") else round(stats.peak_dbfs, 2),
        "rms_dbfs": None if stats.rms_dbfs == float("-inf") else round(stats.rms_dbfs, 2),
        "dc_offset": round(stats.dc_offset, 5),
        "clipped_sample_count": stats.clipped_sample_count,
        "silence_ratio": round(stats.silence_ratio, 4),
        "checksum_sha256": stats.checksum_sha256,
        "issues": issues,
        "verdict": _verdict(issues),
    }


def _verdict(issues: list[dict]) -> str:
    if any(i["severity"] == "REJECT" for i in issues):
        return "REJECT"
    if any(i["severity"] == "WARN" for i in issues):
        return "WARN"
    return "PASS"


def find_orphan_files(dataset_dir: Path, manifest: dict) -> list[str]:
    manifest_filenames = {a.get("filename") for a in manifest.get("assets", [])}
    orphans = []
    for f in dataset_dir.glob("*.wav"):
        if f.name not in manifest_filenames:
            orphans.append(f.name)
    return sorted(orphans)


def run(dataset_dir: Path, manifest_path: Path, provenance_dir: Path | None,
        expected_sample_rate: int, expected_bit_depth: int, expected_channels: int) -> dict:
    manifest = load_json(manifest_path)
    provenance_records = load_provenance_records(provenance_dir)
    duplicate_ids = set(find_duplicate_asset_ids(manifest))

    asset_reports = [
        check_asset(asset, dataset_dir, provenance_records, duplicate_ids,
                    expected_sample_rate, expected_bit_depth, expected_channels)
        for asset in manifest.get("assets", [])
    ]
    orphans = find_orphan_files(dataset_dir, manifest)

    counts = {"PASS": 0, "WARN": 0, "REJECT": 0}
    for r in asset_reports:
        counts[r["verdict"]] += 1

    dataset_verdict = "REJECT" if counts["REJECT"] > 0 else ("WARN" if counts["WARN"] > 0 else "PASS")

    return {
        "manifest_id": manifest.get("manifest_id"),
        "files": asset_reports,
        "orphan_files_not_in_manifest": orphans,
        "summary": {"PASS": counts["PASS"], "WARN": counts["WARN"], "REJECT": counts["REJECT"]},
        "dataset_verdict": dataset_verdict,
    }


def print_human_summary(report: dict) -> None:
    print("=== friday-voice-dataset-qc ===\n")
    for r in report["files"]:
        marker = {"PASS": "✔", "WARN": "⚠", "REJECT": "✘"}[r["verdict"]]
        print(f"{marker} {r.get('filename', '?')}  [{r['verdict']}]")
        for issue in r.get("issues", []):
            print(f"    {issue['severity']}: {issue['code']}" + (f" — {issue['detail']}" if issue.get("detail") else ""))
    if report["orphan_files_not_in_manifest"]:
        print(f"\n⚠ {len(report['orphan_files_not_in_manifest'])} file(s) on disk with no manifest entry: {report['orphan_files_not_in_manifest']}")
    print("\nFILES:")
    print(f"  PASS:   {report['summary']['PASS']}")
    print(f"  WARN:   {report['summary']['WARN']}")
    print(f"  REJECT: {report['summary']['REJECT']}")
    print(f"\nDATASET: {report['dataset_verdict']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FRIDAY voice-v2 dataset QC")
    parser.add_argument("--dataset", required=True, help="directory containing the WAV files")
    parser.add_argument("--manifest", required=True, help="path to the dataset manifest JSON")
    parser.add_argument("--provenance-dir", default=None, help="directory of provenance-record JSON files, for real provenance-resolution checking")
    parser.add_argument("--json-report", default=None, help="write the machine-readable JSON report here")
    parser.add_argument("--fail-on", choices=["warn", "reject"], default="reject", help="exit non-zero if the dataset verdict is at least this severe")
    parser.add_argument("--dry-run", action="store_true", help="do not write --json-report even if supplied; report to stdout only")
    parser.add_argument("--expected-sample-rate", type=int, default=48000)
    parser.add_argument("--expected-bit-depth", type=int, default=24)
    parser.add_argument("--expected-channels", type=int, default=1)
    args = parser.parse_args(argv)

    report = run(
        Path(args.dataset), Path(args.manifest),
        Path(args.provenance_dir) if args.provenance_dir else None,
        args.expected_sample_rate, args.expected_bit_depth, args.expected_channels,
    )
    print_human_summary(report)

    if args.json_report and not args.dry_run:
        Path(args.json_report).write_text(json.dumps(report, indent=2))
        print(f"\nJSON report written: {args.json_report}")
    elif args.json_report and args.dry_run:
        print(f"\n(--dry-run: JSON report NOT written to {args.json_report})")

    severity_order = {"PASS": 0, "WARN": 1, "REJECT": 2}
    threshold = severity_order["WARN"] if args.fail_on == "warn" else severity_order["REJECT"]
    return 1 if severity_order[report["dataset_verdict"]] >= threshold else 0


if __name__ == "__main__":
    sys.exit(main())
