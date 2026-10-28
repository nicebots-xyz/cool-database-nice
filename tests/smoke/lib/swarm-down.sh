#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
# Removes the throwaway swarm created by swarm-up.sh.
docker rm -f hippo-lab1 hippo-lab2 hippo-lab3 >/dev/null 2>&1 || true
docker network rm hippo-lab >/dev/null 2>&1 || true
