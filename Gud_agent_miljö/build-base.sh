#!/usr/bin/env bash
# Bygger den delade agent-basimagen lokalt (en gång per maskin, eller när Dockerfile.agent-base
# ändras). Nya projekt gör `FROM agent-base:latest` i sin egen Dockerfile istället för att
# duplicera apt/npm-installationen. Se projektmall.md §3b.
set -euo pipefail
cd "$(dirname "$0")"
docker build -t agent-base:latest -f Dockerfile.agent-base .
echo "agent-base:latest byggd. Projekt som gör 'FROM agent-base:latest' kan nu byggas/byggas om."
