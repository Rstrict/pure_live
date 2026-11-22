# Loopback TLS test fixture

`localhost-key.pem` is a throwaway P-256 private key committed on purpose so the
repository audit has a real, parseable key to exempt. It protects nothing.

- **Trust scope:** nothing. No local server, client or test loads it; it exists
  only as bytes for `tool/tests/test_repository_secret_audit.py`.
- **Exemption rule:** `tool/audit_repository.py` exempts exactly this path with
  exactly the SHA-256 recorded in `PUBLIC_TLS_TEST_KEYS`. Copying the file
  elsewhere, re-saving it, or changing one byte all fall back to a `private_key`
  error — that is what the regression test asserts.
- **Provenance:** generated locally during the quality-gate repair for this fork.
  The value it replaced was pinned in the audit script but the file itself was
  never committed, so the exemption had no bytes to match and the gate failed on
  a missing file rather than on a real secret.

Do not replace this with a key from a real deployment, and do not widen the
allowlist: an entry that is not exactly reproduced by the recorded digest is a
scanner bypass.
