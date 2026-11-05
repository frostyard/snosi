#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""A JSON Schema validator for exactly the subset that core's v1.json uses.

frostyard/core docs/specs/schemas/problem-report/v1.json (schema
frostyard.problem/1) uses only these keywords: type, const, enum, pattern,
required, properties, additionalProperties (false), $ref to #/$defs/...,
allOf with if/then, items, minItems, maxItems, maxLength, minimum, maximum,
and boolean schemas. The validator refuses any other keyword, so a later
schema that needs more fails here instead of passing without a check.

No pip dependency. Patterns follow ECMA-262 semantics as the spec's rule 8
requires: `$` matches only at the very end of the input, so a trailing newline
fails. Python's `$` also matches before a final newline, so every unescaped
`$` outside a character class becomes `\\Z`.

Usage as a library: validate(schema, instance) returns a list of error
strings (empty when valid). Usage as a command:
  json_schema_subset.py SCHEMA.json DOC.json...      validate whole documents
  json_schema_subset.py --def NAME SCHEMA.json VALUE  validate one JSON value
                                                      against #/$defs/NAME
"""

import json
import re
import sys

KNOWN = {
    "$schema", "$id", "title", "description", "$defs",
    "type", "const", "enum", "pattern", "required", "properties",
    "additionalProperties", "$ref", "allOf", "if", "then", "items",
    "minItems", "maxItems", "maxLength", "minimum", "maximum",
}

_PATTERNS = {}


def _ecma_pattern(pattern):
    """Translate the `$` anchors of an ECMA pattern to Python's `\\Z`."""
    out = []
    in_class = False
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\" and i + 1 < len(pattern):
            out.append(pattern[i:i + 2])
            i += 2
            continue
        if in_class:
            if ch == "]":
                in_class = False
        elif ch == "[":
            in_class = True
        elif ch == "$":
            out.append(r"\Z")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _compiled(pattern):
    if pattern not in _PATTERNS:
        _PATTERNS[pattern] = re.compile(_ecma_pattern(pattern))
    return _PATTERNS[pattern]


def _type_ok(name, value):
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "null":
        return value is None
    raise ValueError(f"unsupported type {name!r}")


def _equal(a, b):
    # JSON equality: true is not 1.
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    return type(a) is type(b) and a == b


def _resolve(root, ref):
    if not ref.startswith("#/$defs/"):
        raise ValueError(f"unsupported $ref {ref!r}")
    return root["$defs"][ref[len("#/$defs/"):]]


def _check(root, schema, value, path, errors):
    if schema is True:
        return
    if schema is False:
        errors.append(f"{path}: not allowed")
        return
    if not isinstance(schema, dict):
        raise ValueError(f"schema at {path} is not an object or boolean")
    unknown = set(schema) - KNOWN
    if unknown:
        raise ValueError(f"unsupported keyword(s) {sorted(unknown)} at {path}")

    if "$ref" in schema:
        _check(root, _resolve(root, schema["$ref"]), value, path, errors)
    if "type" in schema and not _type_ok(schema["type"], value):
        errors.append(f"{path}: not of type {schema['type']}")
        return
    if "const" in schema and not _equal(schema["const"], value):
        errors.append(f"{path}: not the constant {schema['const']!r}")
    if "enum" in schema and not any(_equal(v, value) for v in schema["enum"]):
        errors.append(f"{path}: {value!r} is not in the enum")
    if isinstance(value, str):
        if "pattern" in schema and not _compiled(schema["pattern"]).search(value):
            errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: longer than {schema['maxLength']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: above {schema['maximum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: more than {schema['maxItems']} items")
        if "items" in schema:
            for index, item in enumerate(value):
                _check(root, schema["items"], item, f"{path}[{index}]", errors)
    if isinstance(value, dict):
        for name in schema.get("required", []):
            if name not in value:
                errors.append(f"{path}: missing required {name!r}")
        props = schema.get("properties", {})
        for name, item in value.items():
            if name in props:
                _check(root, props[name], item, f"{path}.{name}", errors)
            elif "additionalProperties" in schema:
                if schema["additionalProperties"] is not False:
                    raise ValueError("only additionalProperties: false is supported")
                errors.append(f"{path}: unknown field {name!r}")
    for sub in schema.get("allOf", []):
        if set(sub) - {"if", "then"}:
            # A plain allOf member: apply it.
            _check(root, sub, value, path, errors)
            continue
        probe = []
        _check(root, sub["if"], value, path, probe)
        if not probe and "then" in sub:
            _check(root, sub["then"], value, path, errors)


def validate(schema, instance, root=None):
    errors = []
    _check(root if root is not None else schema, schema, instance, "$", errors)
    return errors


def validate_def(schema, name, value):
    return validate(schema["$defs"][name], value, root=schema)


def main(argv):
    if len(argv) >= 4 and argv[1] == "--def":
        schema = json.load(open(argv[3], encoding="utf-8"))
        errors = validate_def(schema, argv[2], json.loads(argv[4]))
        for error in errors:
            print(error, file=sys.stderr)
        return 1 if errors else 0
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    schema = json.load(open(argv[1], encoding="utf-8"))
    rc = 0
    for path in argv[2:]:
        errors = validate(schema, json.load(open(path, encoding="utf-8")))
        for error in errors:
            print(f"{path}: {error}", file=sys.stderr)
        if errors:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
