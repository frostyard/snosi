#!/usr/bin/env python3
"""Offline, shape-only preflight for a disposable secure Snow bootc lab run.

This does not authenticate artifacts, inspect registry state, or start a VM.
"""

from datetime import datetime
import io
import json
import re
import sys
from urllib.parse import urlsplit


MAX_BYTES = 65536
FIELDS = frozenset({
    "schema", "family", "product", "installer_iso_url",
    "installer_iso_sha256", "image_n", "image_n_plus_1",
    "version_n", "version_n_plus_1", "target_ref", "cosign_key_sha256",
})
FORBIDDEN_FIELDS = frozenset({"recovery_key", "mok_password"})
HEX = r"[0-9a-f]{64}"
DIGEST_REF = r"ghcr\.io/frostyard/snow@sha256:" + HEX
TAG_REF = r"ghcr\.io/frostyard/snow:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}"
ISO_PATH = r"(?:/[^?#\s]*)?/snosi-installer_[0-9]{14}_x86-64\.iso"
VERSION = "%Y%m%d%H%M%S"


class InvalidManifest(Exception):
    def __init__(self, field, reason):
        super().__init__(f"{field}: {reason}")


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            # Arbitrary JSON keys could themselves contain sensitive bytes.
            safe_field = key if key in FIELDS | FORBIDDEN_FIELDS else "manifest"
            raise InvalidManifest(safe_field, "duplicate field")
        result[key] = value
    return result


def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def version_valid(value):
    if not matches(value, r"[0-9]{14}"):
        return False
    try:
        return datetime.strptime(value, VERSION).strftime(VERSION) == value
    except ValueError:
        return False


def iso_valid(value):
    # urlsplit silently strips tabs/newlines; reject them before parsing.
    if not isinstance(value, str) or re.search(r"[\x00-\x20\x7f]", value):
        return False
    try:
        url = urlsplit(value)
    except ValueError:
        return False
    return (url.scheme == "https" and
            matches(url.netloc, r"[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?") and
            not url.query and not url.fragment and
            "?" not in value and "#" not in value and
            matches(url.path, ISO_PATH))


def validate(data):
    if not isinstance(data, dict):
        raise InvalidManifest("manifest", "expected object")
    for field in sorted(FIELDS - data.keys()):
        raise InvalidManifest(field, "missing field")
    for field in sorted(data.keys() - FIELDS):
        safe_field = field if field in FORBIDDEN_FIELDS else "manifest"
        raise InvalidManifest(safe_field, "unexpected field")

    if type(data["schema"]) is not int or data["schema"] != 1:
        raise InvalidManifest("schema", "expected integer 1")
    for field, expected in (("family", "bootc"), ("product", "snow")):
        if data[field] != expected or not isinstance(data[field], str):
            raise InvalidManifest(field, "unexpected identity")
    if not iso_valid(data["installer_iso_url"]):
        raise InvalidManifest("installer_iso_url", "expected versioned HTTPS ISO URL")
    for field in ("installer_iso_sha256", "cosign_key_sha256"):
        if not matches(data[field], HEX):
            raise InvalidManifest(field, "expected lowercase SHA-256 hex")
    for field in ("image_n", "image_n_plus_1"):
        if not matches(data[field], DIGEST_REF):
            raise InvalidManifest(field, "expected immutable Snow digest ref")
    if data["image_n"] == data["image_n_plus_1"]:
        raise InvalidManifest("image_n_plus_1", "must differ from image_n")
    for field in ("version_n", "version_n_plus_1"):
        if not version_valid(data[field]):
            raise InvalidManifest(field, "expected valid UTC timestamp")
    if data["version_n_plus_1"] <= data["version_n"]:
        raise InvalidManifest("version_n_plus_1", "must be later than version_n")
    if not matches(data["target_ref"], TAG_REF):
        raise InvalidManifest("target_ref", "expected tagged Snow ref")


def main(argv):
    if len(argv) != 2:
        raise InvalidManifest("manifest", "expected one file argument")
    try:
        with open(argv[1], "rb") as source:
            content = source.read(MAX_BYTES + 1)
    except OSError:
        raise InvalidManifest("manifest", "cannot read file") from None
    if len(content) > MAX_BYTES:
        raise InvalidManifest("manifest", "file too large")
    try:
        # The input has already been bounded in bytes before json.load parses it.
        data = json.load(io.StringIO(content.decode("utf-8")), object_pairs_hook=unique_pairs)
    except (UnicodeError, json.JSONDecodeError):
        raise InvalidManifest("manifest", "invalid JSON") from None
    validate(data)
    print("manifest: valid")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except InvalidManifest as error:
        print(error, file=sys.stderr)
        sys.exit(1)
