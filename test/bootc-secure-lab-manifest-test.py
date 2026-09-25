#!/usr/bin/env python3
"""Offline CLI fixtures for the manual Snow bootc lab manifest preflight."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


VALIDATOR = Path(__file__).with_name("bootc-secure-lab-manifest.py")
SPEC = Path(__file__).resolve().parents[1] / "docs/specs/bootc-secure-lab-handoff.md"
VALID = {
    "schema": 1,
    "family": "bootc",
    "product": "snow",
    "installer_iso_url": "https://repository.example/isos/native/v1/snosi-installer_20260924010101_x86-64.iso",
    "installer_iso_sha256": "a" * 64,
    "image_n": "ghcr.io/frostyard/snow@sha256:" + "b" * 64,
    "image_n_plus_1": "ghcr.io/frostyard/snow@sha256:" + "c" * 64,
    "version_n": "20260924010101",
    "version_n_plus_1": "20260925010101",
    "target_ref": "ghcr.io/frostyard/snow:lab-channel_1",
    "cosign_key_sha256": "d" * 64,
}


class ManifestCliTest(unittest.TestCase):
    def invoke(self, payload, *, raw=False):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            path.write_text(payload if raw else json.dumps(payload), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(VALIDATOR), str(path)],
                capture_output=True, text=True, check=False,
            )

    def assert_rejected(self, payload, field, *, raw=False):
        result = self.invoke(payload, raw=raw)
        self.assertNotEqual(result.returncode, 0, field)
        self.assertEqual(result.stdout, "")
        self.assertIn(field, result.stderr)
        self.assertNotIn("ghcr.io/", result.stderr)
        self.assertNotIn("repository.example", result.stderr)
        self.assertNotIn("private-credential-sentinel", result.stderr)

    def test_valid_synthetic_manifest_is_accepted(self):
        result = self.invoke(VALID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "manifest: valid\n")
        self.assertEqual(result.stderr, "")

    def test_missing_and_extra_fields_are_refused(self):
        for field in VALID:
            with self.subTest(missing=field):
                payload = VALID.copy()
                del payload[field]
                self.assert_rejected(payload, field)
        for field in ("unknown", "recovery_key", "mok_password"):
            with self.subTest(extra=field):
                self.assert_rejected({**VALID, field: "private-credential-sentinel"},
                                     "manifest" if field == "unknown" else field)
        self.assert_rejected({**VALID, "private-credential-sentinel": "secret"}, "manifest")

    def test_wrong_identity_and_schema_are_refused(self):
        for field, value in (
            ("schema", True), ("schema", 1.0), ("schema", 2),
            ("family", "native-ab"), ("product", "snow-ab"),
        ):
            with self.subTest(field=field, value=value):
                self.assert_rejected({**VALID, field: value}, field)

    def test_iso_must_be_https_versioned_filename(self):
        for value in (
            "https://repository.example/isos/native/v1/snosi-installer-latest-x86-64.iso",
            "http://repository.example/isos/native/v1/snosi-installer_20260924010101_x86-64.iso",
            "https://repository.example/isos/native/v1/snosi-installer_20260924010101_x86-64.iso?next=latest",
            "https:///snosi-installer_20260924010101_x86-64.iso",
            "https://repository.example/snosi-installer_20260924010101_x86-64.iso/extra",
            "https://reposi\ntory.example/snosi-installer_20260924010101_x86-64.iso",
        ):
            with self.subTest(url=value):
                self.assert_rejected({**VALID, "installer_iso_url": value}, "installer_iso_url")

    def test_hashes_must_be_lowercase_sha256_hex(self):
        for field in ("installer_iso_sha256", "cosign_key_sha256"):
            for value in ("a" * 63, "A" * 64, "g" * 64, 42):
                with self.subTest(field=field, value=value):
                    self.assert_rejected({**VALID, field: value}, field)

    def test_only_distinct_lowercase_snow_digest_refs_are_accepted(self):
        for field in ("image_n", "image_n_plus_1"):
            for value in (
                "ghcr.io/frostyard/snow:latest",
                "ghcr.io/frostyard/snow-ab@sha256:" + "b" * 64,
                "ghcr.io/elsewhere/snow@sha256:" + "b" * 64,
                "ghcr.io/frostyard/Snow@sha256:" + "b" * 64,
                "ghcr.io/frostyard/snow@sha256:" + "B" * 64,
            ):
                with self.subTest(field=field, value=value):
                    self.assert_rejected({**VALID, field: value}, field)
        self.assert_rejected({**VALID, "image_n_plus_1": VALID["image_n"]}, "image_n_plus_1")

    def test_versions_must_be_distinct_ascending_valid_utc_timestamps(self):
        for field, value in (
            ("version_n", "20260230010101"),
            ("version_n", "2026092401010"),
            ("version_n", 20260924010101),
            ("version_n_plus_1", VALID["version_n"]),
            ("version_n_plus_1", "20260923010101"),
        ):
            with self.subTest(field=field, value=value):
                self.assert_rejected({**VALID, field: value}, field)

    def test_target_is_tagged_snow_only(self):
        for value in (
            VALID["image_n"], "ghcr.io/frostyard/snow:",
            "ghcr.io/frostyard/snow:bad tag", "ghcr.io/frostyard/snow:.bad",
            "ghcr.io/frostyard/snow-ab:lab", "ghcr.io/frostyard/Snow:lab",
            "ghcr.io/elsewhere/snow:lab", "ghcr.io/frostyard/snow:" + "x" * 129,
        ):
            with self.subTest(target=value):
                self.assert_rejected({**VALID, "target_ref": value}, "target_ref")

    def test_malformed_json_duplicate_keys_and_non_object_are_refused(self):
        for text, field in (
            ('{"schema": 1,', "manifest"),
            ('[]', "manifest"),
            (json.dumps(VALID)[:-1] + ', "schema": 1}', "schema"),
            ('{"schema": 1, "schema": 1}', "schema"),
            ('{"private-credential-sentinel": 1, "private-credential-sentinel": 2}', "manifest"),
        ):
            with self.subTest(text=text[:20]):
                self.assert_rejected(text, field, raw=True)

    def test_missing_or_oversized_file_fails_without_echoing_path_or_contents(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private-credential-sentinel.json"
            result = subprocess.run([sys.executable, str(VALIDATOR), str(path)],
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("private-credential-sentinel", result.stderr)
        result = self.invoke("private-credential-sentinel" + " " * 70000, raw=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private-credential-sentinel", result.stderr)

    def test_spec_pins_schema_and_lab_evidence(self):
        spec = SPEC.read_text(encoding="utf-8")
        for field in VALID:
            with self.subTest(field=field):
                self.assertIn(f"`{field}`", spec)
        rules = " ".join(spec.split("## Rules", 1)[1].split("## Derived artifacts", 1)[0].split())
        for requirement in (
            r"ISO.*verify its bytes against `installer_iso_sha256`",
            r"`image_n` and `image_n_plus_1` with Cosign.*committed key",
            r"`target_ref`.*`image_n_plus_1`.*before.*after.*stage",
            r"\.status\.staged\.image\.imageDigest.*N\+1",
            r"fresh-boot `.status.booted.image.imageDigest` equality to N\+1",
            r"`bootc rollback`.*reboot to N.*\.status\.booted\.image\.imageDigest.*`image_n`",
            r"BLOCKED/unproven",
        ):
            with self.subTest(requirement=requirement):
                self.assertRegex(rules, re.compile(requirement, re.IGNORECASE))


if __name__ == "__main__":
    unittest.main()
