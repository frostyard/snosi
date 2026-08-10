# Policy-as-code

This directory is the repository's policy-as-code entry point for governance
checks such as ACMM `acmm:policy-as-code`.

Concrete OPA, Conftest, Kyverno, or repository-specific policy checks should be
added here when they become enforceable. Existing structural gates remain in
the repository tests and GitHub workflows until they are promoted into this
policy surface.
