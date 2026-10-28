---
packages:
  hippo: patch
---

### The Python lock file no longer stays in an image layer

The base image mounts `requirements.lock` for the Patroni install instead of copying it in, so the file is no longer kept in a layer of its own.
