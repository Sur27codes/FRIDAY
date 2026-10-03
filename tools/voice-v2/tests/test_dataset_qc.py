"""P2-M5V9-B.3D.2B — targeted tests for friday_voice_dataset_qc.

All fixtures are synthetic (sine tones / silence / corrupted bytes) —
never human voice. Run with: python3 -m unittest discover -s tools/voice-v2/tests
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))
sys.path.insert(0, str(TOOLS_DIR / "tests"))

import friday_voice_dataset_qc as qc  # noqa: E402
from friday_voice_common import sha256_of_file  # noqa: E402
from wav_fixtures import (  # noqa: E402
    write_clipped_wav, write_empty_wav, write_not_a_wav, write_silence_wav,
    write_sine_wav, write_truncated_wav,
)


def base_asset(asset_id="asset-0001", filename="a.wav", **overrides) -> dict:
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


def make_provenance(tmpdir: Path, rights_record_id="rights-test-0001") -> Path:
    prov_dir = tmpdir / "provenance"
    prov_dir.mkdir(exist_ok=True)
    record = {
        "provenance_id": "prov-test-0001", "speaker_id": "spk-test", "rights_record_id": rights_record_id,
        "session_id": "sess-test", "session_date": "2026-09-09", "studio_or_location": "test-studio",
        "engineer": "eng-test", "mic": "test-mic", "interface": "test-interface", "room": "test-room",
        "rights_scope_summary": "synthetic test record", "created_at": "2026-09-09T00:00:00Z",
    }
    (prov_dir / "record-0001.json").write_text(json.dumps(record))
    return prov_dir


class DatasetQCTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())
        self.dataset_dir = self.tmpdir / "dataset"
        self.dataset_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _manifest_path(self, assets: list[dict]) -> Path:
        manifest = {"manifest_id": "m-test", "manifest_version": "1.0", "speaker_id": "spk-test", "session_id": "sess-test", "assets": assets}
        p = self.tmpdir / "manifest.json"
        p.write_text(json.dumps(manifest))
        return p

    def _run(self, assets: list[dict], provenance_dir=None):
        manifest_path = self._manifest_path(assets)
        return qc.run(self.dataset_dir, manifest_path, provenance_dir, 48000, 24, 1)

    # --- required test list from the mission ---

    def test_valid_master_passes(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "PASS", report["files"][0]["issues"])
        self.assertEqual(report["dataset_verdict"], "PASS")

    def test_clipped_rejected(self):
        write_clipped_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "clipping" for i in report["files"][0]["issues"]))

    def test_wrong_sample_rate_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav", sample_rate=44100)
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "wrong_sample_rate" for i in report["files"][0]["issues"]))

    def test_wrong_channel_count_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav", channels=2)
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "wrong_channel_count" for i in report["files"][0]["issues"]))

    def test_wrong_bit_depth_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav", bit_depth=16)
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "wrong_bit_depth" for i in report["files"][0]["issues"]))

    def test_corrupt_wav_rejected(self):
        write_not_a_wav(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset()], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "corrupt_wav" for i in report["files"][0]["issues"]))

    def test_truncated_wav_rejected(self):
        write_truncated_wav(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset()], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")

    def test_missing_provenance_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        empty_prov_dir = self.tmpdir / "empty-provenance"
        empty_prov_dir.mkdir()
        report = self._run([base_asset(checksum_sha256=checksum, rights_record_id="rights-that-does-not-exist")], provenance_dir=empty_prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "missing_provenance" for i in report["files"][0]["issues"]))

    def test_missing_rights_record_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        report = self._run([base_asset(checksum_sha256=checksum, rights_record_id="")])
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "missing_rights_record" for i in report["files"][0]["issues"]))

    def test_checksum_mismatch_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256="f" * 64)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "checksum_mismatch" for i in report["files"][0]["issues"]))

    def test_duplicate_asset_id_rejected(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        write_sine_wav(self.dataset_dir / "b.wav")
        checksum_a = sha256_of_file(self.dataset_dir / "a.wav")
        checksum_b = sha256_of_file(self.dataset_dir / "b.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([
            base_asset(asset_id="dup-id", filename="a.wav", checksum_sha256=checksum_a),
            base_asset(asset_id="dup-id", filename="b.wav", checksum_sha256=checksum_b),
        ], provenance_dir=prov_dir)
        self.assertTrue(all(r["verdict"] == "REJECT" for r in report["files"]))
        self.assertTrue(any(i["code"] == "duplicate_asset_id" for r in report["files"] for i in r["issues"]))
        self.assertEqual(report["dataset_verdict"], "REJECT")

    # --- additional fixtures mentioned in the mission ---

    def test_dc_offset_signal_flagged(self):
        write_sine_wav(self.dataset_dir / "a.wav", dc_offset=0.15, amplitude=0.3)
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "dc_offset_extreme" for i in report["files"][0]["issues"]))

    def test_empty_wav_rejected(self):
        write_empty_wav(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset()], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "zero_length_audio" for i in report["files"][0]["issues"]))

    def test_long_silence_rejected(self):
        write_silence_wav(self.dataset_dir / "a.wav", seconds=3.0)
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "unexpected_silence" for i in report["files"][0]["issues"]))

    def test_missing_manifest_file_reference_rejected(self):
        # Manifest references a file that was never written to disk.
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(filename="never-written.wav")], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "REJECT")
        self.assertTrue(any(i["code"] == "file_missing" for i in report["files"][0]["issues"]))

    def test_orphan_file_not_in_manifest_reported(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        write_sine_wav(self.dataset_dir / "orphan.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertIn("orphan.wav", report["orphan_files_not_in_manifest"])

    def test_normal_dynamic_variation_not_auto_rejected(self):
        # A quieter, natural take must not be REJECTed merely for having
        # a lower level than another take.
        write_sine_wav(self.dataset_dir / "a.wav", amplitude=0.2)
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        self.assertEqual(report["files"][0]["verdict"], "PASS")

    def test_provenance_unverified_is_warn_not_pass_or_reject_bypass(self):
        # With NO --provenance-dir supplied at all (None, not merely
        # empty), a present-but-unverifiable rights_record_id is a WARN,
        # not a silent PASS.
        write_sine_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=None)
        self.assertEqual(report["files"][0]["verdict"], "WARN")
        self.assertTrue(any(i["code"] == "provenance_unverified" for i in report["files"][0]["issues"]))

    def test_no_biometric_or_identity_fields_ever_reported(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        prov_dir = make_provenance(self.tmpdir)
        report = self._run([base_asset(checksum_sha256=checksum)], provenance_dir=prov_dir)
        forbidden = {"speaker_embedding", "gender", "age", "emotion", "identity_score", "speaker_similarity"}
        self.assertTrue(forbidden.isdisjoint(report["files"][0].keys()))

    def test_cli_fail_on_reject_exit_code(self):
        write_clipped_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        manifest_path = self._manifest_path([base_asset(checksum_sha256=checksum)])
        rc = qc.main(["--dataset", str(self.dataset_dir), "--manifest", str(manifest_path), "--fail-on", "reject"])
        self.assertEqual(rc, 1)

    def test_cli_dry_run_does_not_write_report(self):
        write_sine_wav(self.dataset_dir / "a.wav")
        checksum = sha256_of_file(self.dataset_dir / "a.wav")
        manifest_path = self._manifest_path([base_asset(checksum_sha256=checksum)])
        report_path = self.tmpdir / "report.json"
        qc.main(["--dataset", str(self.dataset_dir), "--manifest", str(manifest_path), "--json-report", str(report_path), "--dry-run"])
        self.assertFalse(report_path.exists())


if __name__ == "__main__":
    unittest.main()
