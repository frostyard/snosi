# Change Risk Tiers

Classify every pull request by the highest applicable tier. When a change spans
multiple areas or its impact is uncertain, use the higher tier. The
classification sets the minimum review and validation depth; it does not replace
the gates in the [PR review rubric](review-rubric.md).

| Tier | Typical changes | Minimum evidence |
| --- | --- | --- |
| **1 — Low** | Documentation, comments, and metadata with no runtime or policy effect | Review the rendered or generated result and explain why runtime behavior is unchanged. |
| **2 — Moderate** | Tests, developer tooling, routine dependency updates, sysext packages, and non-security CI changes | Run the targeted tests or build for the affected component and obtain review from someone familiar with that area. |
| **3 — High** | Image or profile composition, installers, boot/update behavior, privileged services, workflow permissions, and publication logic | Run applicable contract or integration tests, document failure and rollback behavior, and obtain maintainer approval. |
| **4 — Critical** | Signing or trust roots, credentials, Secure Boot, TPM policy, destructive disk operations, authentication boundaries, and release promotion controls | Document the threat and rollback model, run the relevant end-to-end security checks, and obtain approval from a maintainer familiar with the security boundary. |

## Classification process

1. Add `Risk tier: <1-4> — <reason>` to the pull request summary.
2. Identify the highest-risk behavior touched, including workflow permissions,
   generated artifacts, and transitive effects.
3. List the validation evidence required by that tier in the pull request.
4. Reclassify the pull request if its scope changes during review.

A documentation-only change is not automatically Tier 1 when it changes a
security, release, or operational contract. Similarly, a small diff can be
high-risk when it changes a trust boundary.

Security vulnerabilities must still be reported privately according to
[`SECURITY.md`](../SECURITY.md); risk classification does not make public
disclosure appropriate.
