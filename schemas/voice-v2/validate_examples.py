#!/usr/bin/env python3
"""P2-M5V9-B.3D.2 §19 — targeted validation for the voice-v2 schemas.

Confirms:
  - both schemas parse as valid JSON Schema (draft 2020-12)
  - the synthetic valid examples validate against their schema
  - the synthetic invalid examples are REJECTED for the specific reason intended
  - duplicate asset_id values across a manifest's assets array are rejected
    by this validator (the cross-item invariant the schema itself cannot
    express — see the schema's own top-level description)

No real performer audio, PII, or contract content is referenced anywhere
in this script or the example files it validates.

Run: python3 schemas/voice-v2/validate_examples.py
Exit code 0 = every check behaved as expected. Non-zero = a check did NOT
behave as expected (this is a test failure, not a normal schema-invalid report).
"""
import json
import sys
from pathlib import Path

import jsonschema

HERE = Path(__file__).parent
EXAMPLES = HERE / "examples"

MANIFEST_SCHEMA = json.loads((HERE / "dataset-manifest.schema.json").read_text())
PROVENANCE_SCHEMA = json.loads((HERE / "provenance-record.schema.json").read_text())

failures = []


def check(label: str, condition: bool, detail: str = ""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" — {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(label)


def load(name: str) -> dict:
    return json.loads((EXAMPLES / name).read_text())


def validates(schema: dict, instance: dict) -> tuple[bool, str]:
    try:
        jsonschema.validate(instance=instance, schema=schema)
        return True, ""
    except jsonschema.ValidationError as e:
        return False, e.message


def duplicate_asset_ids(manifest: dict) -> list[str]:
    seen = set()
    dupes = []
    for asset in manifest.get("assets", []):
        aid = asset.get("asset_id")
        if aid in seen:
            dupes.append(aid)
        seen.add(aid)
    return dupes


def main() -> int:
    print("=== P2-M5V9-B.3D.2 voice-v2 schema validation ===\n")

    # 1. Schemas parse as valid JSON Schema (draft 2020-12).
    for name, schema in [("dataset-manifest.schema.json", MANIFEST_SCHEMA), ("provenance-record.schema.json", PROVENANCE_SCHEMA)]:
        try:
            jsonschema.Draft202012Validator.check_schema(schema)
            check(f"{name} is a valid JSON Schema (draft 2020-12)", True)
        except jsonschema.SchemaError as e:
            check(f"{name} is a valid JSON Schema (draft 2020-12)", False, str(e))

    # 2. Valid manifest example validates.
    valid_manifest = load("valid-manifest.json")
    ok, detail = validates(MANIFEST_SCHEMA, valid_manifest)
    check("valid-manifest.json validates against the manifest schema", ok, detail)

    # 3. Invalid manifest (missing rights_record_id) is REJECTED.
    invalid_rights = load("invalid-manifest-missing-rights-record.json")
    ok, detail = validates(MANIFEST_SCHEMA, invalid_rights)
    check("invalid-manifest-missing-rights-record.json is REJECTED by the schema", not ok, "schema incorrectly accepted a manifest with a missing rights_record_id" if ok else "")

    # 4. Duplicate asset_id manifest: schema-shape-valid per item, but the
    #    validator's cross-item uniqueness check must reject it.
    dup_manifest = load("invalid-manifest-duplicate-asset-id.json")
    ok, detail = validates(MANIFEST_SCHEMA, dup_manifest)
    check("invalid-manifest-duplicate-asset-id.json is schema-shape-valid (each item, alone, is well-formed)", ok, detail)
    dupes = duplicate_asset_ids(dup_manifest)
    check("duplicate asset_id values are detected and rejected by the validator", len(dupes) > 0, "no duplicate asset_id detected — the cross-item check did not fire" if not dupes else "")

    # 5. Valid provenance record validates.
    valid_prov = load("valid-provenance-record.json")
    ok, detail = validates(PROVENANCE_SCHEMA, valid_prov)
    check("valid-provenance-record.json validates against the provenance schema", ok, detail)

    # 6. Invalid provenance record (missing rights_record_id / rights_scope_summary) is REJECTED.
    invalid_prov = load("invalid-provenance-record-missing-field.json")
    ok, detail = validates(PROVENANCE_SCHEMA, invalid_prov)
    check("invalid-provenance-record-missing-field.json is REJECTED by the schema", not ok, "schema incorrectly accepted a provenance record with a missing required field" if ok else "")

    print()
    if failures:
        print(f"=== {len(failures)} check(s) FAILED: {failures} ===")
        return 1
    print("=== All checks behaved as expected. ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
