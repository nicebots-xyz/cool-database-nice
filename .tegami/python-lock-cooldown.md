---
packages:
  hippo: patch
---

### Lock Patroni's Python dependencies with a 7-day cooldown

The lock only takes releases at least 7 days old, matching Renovate's cooldown for PyPI updates.
