"""P2-M5V9-B.3D.2C — targeted tests for friday_voice_ingest.

All fixtures are synthetic (sine tones) — never human voice. Uses
temporary directories only; never touches the real
"~/Library/Application Support/FRIDAY/VoiceAssets/V2" default.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))
sys.path.insert(0, str(TOOLS_DIR / "tests"))

import friday_voice_ingest as ingest_mod  # noqa: E402
from friday_voice_common import sha256_of_file  # noqa: E402
from wav_fixtures import write_clipped_wav, write_sine_wav  # noqa: E402


def base_asset(asset_id="asset-0001", filename="friday_v2_neutral_0001.wav", **overrides) -> dict:
    asset = {
        "asset_id": asset_id, "filename": filename, "transcript": "A synthetic test line.",
        "delivery_mode": "neutral", "language": "en", "locale": "en-US",
        "speaker_id": "spk-test", "session_id": "sess-test", "take_number": 1,
        "approved": True, "sample_rate": 48000, "bit_depth": 24, "channels": 1,
        "duration_ms": 1000, "peak_dbfs": -6.0, "checksum_sha256": "0" * 64,
        "recorded_at": "2026-09-09T00:00:00Z", "mic": "test-mic", "interface": "test-interface",
        "room": "test-room", "rights_record_id": "rights-test-0001", "notes": "synthetic",
    }
    asset.update(overrides)
    return asset


class IngestTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())
        self.candidate_dir = self.tmpdir / "candidate"
        self.candidate_dir.mkdir()
        self.dest_root = self.tmpdir / "dest"
        self.prov_dir = self.tmpdir / "provenance"
        self.prov_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_manifest(self, assets: list[dict]) -> Path:
        manifest = {"manifest_id": "m-test", "manifest_version": "1.0", "speaker_id": "spk-test", "session_id": "sess-test", "assets": assets}
        p = self.tmpdir / "manifest.json"
        p.write_text(json.dumps(manifest))
        return p

    def _write_provenance(self, rights_record_id="rights-test-0001") -> None:
        record = {
            "provenance_id": "prov-test-0001", "speaker_id": "spk-test", "rights_record_id": rights_record_id,
            "session_id": "sess-test", "session_date": "2026-09-09", "studio_or_location": "test-studio",
            "engineer": "eng-test", "mic": "test-mic", "interface": "test-interface", "room": "test-room",
            "rights_scope_summary": "synthetic test record", "created_at": "2026-09-09T00:00:00Z",
        }
        (self.prov_dir / "record.json").write_text(json.dumps(record))

    def _valid_asset(self):
        write_sine_wav(self.candidate_dir / "friday_v2_neutral_0001.wav")
        checksum = sha256_of_file(self.candidate_dir / "friday_v2_neutral_0001.wav")
        return base_asset(checksum_sha256=checksum)

    def test_valid_synthetic_dataset_accepted(self):
        asset = self._valid_asset()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report["accepted_count"], 1)
        self.assertEqual(report["quarantined_count"], 0)
        self.assertTrue((self.dest_root / "approved" / "friday_v2_neutral_0001.wav").exists())
        self.assertTrue((self.dest_root / "manifests" / manifest_path.name).exists())
        self.assertTrue((self.dest_root / "provenance" / "record.json").exists())

    def test_missing_provenance_rejected(self):
        asset = self._valid_asset()
        # No provenance written at all, and no --provenance-dir passed.
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, None, self.dest_root)
        self.assertEqual(report["accepted_count"], 0)
        self.assertEqual(report["quarantined_count"], 1)
        self.assertIn("provenance", report["quarantined"][0]["reason"])

    def test_missing_rights_record_id_rejected_at_schema_gate(self):
        # An empty rights_record_id fails the manifest schema's own
        # minLength:1 constraint (schemas/voice-v2/dataset-manifest.schema.json)
        # BEFORE any per-asset processing — the whole batch is blocked
        # rather than silently ingesting a malformed manifest's other
        # entries. "Goes nowhere" per the ingest contract.
        write_sine_wav(self.candidate_dir / "friday_v2_neutral_0001.wav")
        checksum = sha256_of_file(self.candidate_dir / "friday_v2_neutral_0001.wav")
        asset = base_asset(checksum_sha256=checksum, rights_record_id="")
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        with self.assertRaises(ingest_mod.IngestBlocked):
            ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertFalse((self.dest_root / "approved").exists(), "a schema-invalid manifest must never partially ingest")

    def test_rights_record_id_that_does_not_resolve_is_quarantined(self):
        # Schema-valid (non-empty string), but doesn't match any loaded
        # provenance record — this IS a per-asset quarantine, not a
        # whole-batch block, since the manifest itself is well-formed.
        asset = self._valid_asset()
        asset["rights_record_id"] = "rights-that-does-not-exist"
        self._write_provenance(rights_record_id="a-completely-different-id")
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report["accepted_count"], 0)
        self.assertEqual(report["quarantined_count"], 1)

    def test_qc_reject_rejected(self):
        write_clipped_wav(self.candidate_dir / "friday_v2_neutral_0001.wav")
        checksum = sha256_of_file(self.candidate_dir / "friday_v2_neutral_0001.wav")
        asset = base_asset(checksum_sha256=checksum)
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report["accepted_count"], 0)
        self.assertEqual(report["quarantined_count"], 1)
        self.assertIn("REJECT", report["quarantined"][0]["reason"])

    def test_manifest_mismatch_rejected(self):
        # Manifest references a file that doesn't exist in candidate_dir.
        asset = base_asset(filename="friday_v2_neutral_9999.wav")
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report["accepted_count"], 0)
        self.assertEqual(report["quarantined_count"], 1)

    def test_checksum_mismatch_rejected(self):
        write_sine_wav(self.candidate_dir / "friday_v2_neutral_0001.wav")
        asset = base_asset(checksum_sha256="f" * 64)  # deliberately wrong
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report["accepted_count"], 0)
        self.assertEqual(report["quarantined_count"], 1)
        self.assertIn("checksum", report["quarantined"][0]["reason"])

    def test_duplicate_ingestion_is_deterministic_and_safe(self):
        asset = self._valid_asset()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        report1 = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        report2 = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report1["accepted_count"], 1)
        self.assertEqual(report2["accepted_count"], 1)  # idempotent re-ingest of identical content succeeds again
        self.assertEqual(report2["quarantined_count"], 0)

    def test_duplicate_ingestion_with_different_content_at_destination_quarantined(self):
        asset = self._valid_asset()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        # Now corrupt the already-ingested destination file so it no longer matches.
        dest_file = self.dest_root / "approved" / "friday_v2_neutral_0001.wav"
        dest_file.write_bytes(dest_file.read_bytes() + b"\x00\x00\x00\x00")
        report2 = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report2["accepted_count"], 0)
        self.assertEqual(report2["quarantined_count"], 1)
        self.assertIn("DIFFERENT content", report2["quarantined"][0]["reason"])

    def test_partial_write_simulation_leaves_no_corrupted_committed_asset(self):
        asset = self._valid_asset()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])

        real_copyfileobj = shutil.copyfileobj

        def failing_copyfileobj(fsrc, fdst, *a, **kw):
            fdst.write(b"only a few bytes before the failure")
            raise OSError("simulated I/O failure mid-copy")

        with mock.patch("shutil.copyfileobj", side_effect=failing_copyfileobj):
            with self.assertRaises(OSError):
                ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)

        dest_file = self.dest_root / "approved" / "friday_v2_neutral_0001.wav"
        self.assertFalse(dest_file.exists(), "a failed copy must never leave a partial file at the destination")
        # Confirm the tool still works normally afterward (no leftover temp-file interference).
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual(report["accepted_count"], 1)

    def test_path_traversal_attempt_rejected(self):
        asset = base_asset(filename="../../etc/passwd")
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        with self.assertRaises(ingest_mod.IngestBlocked):
            ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)

    def test_symlink_escape_rejected(self):
        outside_dir = self.tmpdir / "outside"
        outside_dir.mkdir()
        write_sine_wav(outside_dir / "secret.wav")
        # The manifest's filename is schema-legal, but the actual file
        # in candidate_dir is a symlink pointing OUTSIDE candidate_dir.
        link_path = self.candidate_dir / "friday_v2_neutral_0001.wav"
        os.symlink(outside_dir / "secret.wav", link_path)
        checksum = sha256_of_file(outside_dir / "secret.wav")
        asset = base_asset(checksum_sha256=checksum)
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        with self.assertRaises(ingest_mod.IngestBlocked):
            ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)

    def test_repository_destination_attempt_rejected(self):
        asset = self._valid_asset()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        repo_dest = ingest_mod.REPO_ROOT / "schemas" / "voice-v2"  # a real, existing in-repo path
        with self.assertRaises(ingest_mod.IngestBlocked):
            ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, repo_dest)

    def test_dry_run_copies_nothing(self):
        asset = self._valid_asset()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        report = ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root, dry_run=True)
        self.assertEqual(report["accepted_count"], 1)
        self.assertFalse((self.dest_root / "approved").exists())

    def test_original_recording_never_mutated(self):
        asset = self._valid_asset()
        original_bytes = (self.candidate_dir / "friday_v2_neutral_0001.wav").read_bytes()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        self.assertEqual((self.candidate_dir / "friday_v2_neutral_0001.wav").read_bytes(), original_bytes)

    def test_ingested_asset_is_byte_identical_to_source(self):
        asset = self._valid_asset()
        original_bytes = (self.candidate_dir / "friday_v2_neutral_0001.wav").read_bytes()
        self._write_provenance()
        manifest_path = self._write_manifest([asset])
        ingest_mod.ingest(self.candidate_dir, manifest_path, self.prov_dir, self.dest_root)
        ingested_bytes = (self.dest_root / "approved" / "friday_v2_neutral_0001.wav").read_bytes()
        self.assertEqual(ingested_bytes, original_bytes, "no resampling/normalization/format conversion may occur during ingest")


if __name__ == "__main__":
    unittest.main()
