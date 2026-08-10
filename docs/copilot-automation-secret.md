# Copilot automation secret

Frostyard's canonical GitHub Actions secret for assigning work to Copilot is
`COPILOT_ASSIGNMENT_TOKEN`. Both automation workflows in this repository use
that name:

- `.github/workflows/ai-fix-requested.yml`
- `.github/workflows/copilot-review-apply.yml`

The secret is a user-scoped token because comments and assignments made with an
installation `GITHUB_TOKEN` cannot invoke the Copilot coding agent. The token
must belong to a Copilot-licensed maintainer and be limited to Frostyard's
participating repositories. For a fine-grained token, grant only the Actions,
Contents, Issues, and Pull requests read/write access required by GitHub's agent
assignment and comment APIs.

## Fleet rollout

An organization administrator owns the credential and repository access. Apply
changes in this order so a workflow reference is never renamed to an unavailable
secret:

1. Create or update the organization Actions secret named
   `COPILOT_ASSIGNMENT_TOKEN`.
2. Grant it to `frostyard/snosi`, `frostyard/pilothouse`, `frostyard/lab`,
   `frostyard/testsuite`, and `frostyard/updex` using selected-repository
   access. Confirm each repository reports access without printing the value.
3. In each participating repository, change both Copilot automation workflows
   to reference the canonical name. Do not retain aliases for the historical
   `COPILOT_AGENT_TOKEN` or `COPILOT_ASSIGN_PAT` spellings; aliases hide drift
   and make failures repository-dependent.
4. Manually dispatch each workflow with a valid open issue or eligible open
   same-repository pull request/review. Verify that the run passes the missing
   secret guard and reaches the fixed GitHub API operation.
5. Review the Actions run and resulting assignment/comment, then remove any
   obsolete repository-level aliases after all consumers are migrated.

Repository pull requests can perform step 3 and add drift guards, but they
cannot create or expose an organization secret. Do not merge a rename in a
repository until an administrator confirms step 2 for that repository.

## Failure and rotation

A missing secret must fail visibly with
`COPILOT_ASSIGNMENT_TOKEN is not configured`; it must not silently skip a
requested assignment or fall back to `GITHUB_TOKEN`. An invalid, expired, or
under-scoped token likewise leaves a failed workflow run for investigation.

Rotate the user token in the organization secret without changing workflow
files. To suspend automation, remove repository access to the organization
secret or disable the workflows. Never print the token, copy it into issue or
pull-request text, commit it, or pass it to repository-authored executable
content.
