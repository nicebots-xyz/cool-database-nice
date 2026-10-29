---
packages:
  hippo: patch
---

### Passwords ignore a trailing newline in the secrets

`deploy/patroni.yml.tmpl` reads the superuser and replication passwords as folded scalars, so a secret created with a trailing newline (`openssl rand -hex 32 | docker secret create …`) no longer becomes a password ending in a space that clients reading the secret with `$(cat …)` cannot match. Secrets without a newline give the same password as before. The stack's config key is now `patroni_v2`.

Clusters bootstrapped from such a secret keep the old password: run `ALTER ROLE` for `postgres` and `replicator` on the leader before redeploying.
