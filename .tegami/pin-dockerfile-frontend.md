---
packages:
  hippo: patch
---

### Pin the Dockerfile frontend to an exact version

Images are built with `docker/dockerfile:1.27.1` by digest instead of the moving `1` tag, so frontend updates arrive as versioned, cooled-down updates.
