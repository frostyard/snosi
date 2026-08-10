#!/usr/bin/env python3
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / "policies/agent-governance.json"
WORKFLOW_PATH = ROOT / ".github/workflows/validate.yml"
WORKFLOW_COMMAND = "python3 ./test/policy-as-code-test.py"


def fail(message: str) -> None:
    raise SystemExit(f"policy-as-code-test: {message}")


try:
    policy = json.loads(POLICY_PATH.read_text())
except (OSError, json.JSONDecodeError) as error:
    fail(f"cannot load {POLICY_PATH.relative_to(ROOT)}: {error}")

expected_top_level = {
    "version",
    "defaultDecision",
    "agentActions",
    "changeControls",
    "protectedBoundaries",
    "exceptions",
}
if set(policy) != expected_top_level:
    fail("policy must contain exactly the version 1 top-level fields")
if policy["version"] != 1:
    fail("unknown policy version")
if policy["defaultDecision"] != "deny":
    fail("default decision must remain deny")

expected_denials = {
    "mergePullRequest",
    "publishRelease",
    "deployProduction",
    "modifyProtectedEnvironment",
    "approveOwnException",
}
actions = policy["agentActions"]
if not isinstance(actions, dict) or set(actions) != expected_denials:
    fail("agentActions must contain exactly the governed autonomous actions")
if any(decision != "deny" for decision in actions.values()):
    fail("all governed autonomous actions must remain denied")

expected_controls = {
    "pullRequestRequired",
    "humanReviewRequired",
    "riskClassificationRequired",
    "validationEvidenceRequired",
    "securityRejectionTestsRequiredForProtectedBoundaries",
}
controls = policy["changeControls"]
if not isinstance(controls, dict) or set(controls) != expected_controls:
    fail("changeControls must contain exactly the required review controls")
if any(value is not True for value in controls.values()):
    fail("all change controls must remain required")

required_boundaries = {
    "authentication",
    "credentials",
    "destructive-disk-operations",
    "encryption",
    "installer",
    "publication",
    "release",
    "secure-boot",
    "signing",
    "tpm",
    "update-verification",
    "workflow-permissions",
}
boundaries = policy["protectedBoundaries"]
if not isinstance(boundaries, list) or any(not isinstance(item, str) for item in boundaries):
    fail("protectedBoundaries must be a list of names")
if len(boundaries) != len(set(boundaries)):
    fail("protectedBoundaries must not contain duplicates")
missing_boundaries = required_boundaries - set(boundaries)
if missing_boundaries:
    fail(f"protected boundaries removed: {', '.join(sorted(missing_boundaries))}")

expected_exceptions = {
    "pullRequestRationaleRequired",
    "compensatingControlsRequired",
    "maintainerApprovalRequired",
}
exceptions = policy["exceptions"]
if not isinstance(exceptions, dict) or set(exceptions) != expected_exceptions:
    fail("exceptions must contain exactly the required controls")
if any(value is not True for value in exceptions.values()):
    fail("all exception controls must remain required")

try:
    workflow = WORKFLOW_PATH.read_text()
except OSError as error:
    fail(f"cannot load validation workflow: {error}")
if workflow.count(WORKFLOW_COMMAND) != 1:
    fail("validate.yml must run the policy gate exactly once")

print("policy-as-code-test: PASSED")
