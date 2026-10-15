# Contributing to Teddy

Read the repository's [engineering guidance](../ted/AGENTS.md), [product contract](../ted/PROJECT.md) and [implementation record](../ted/IMPLEMENTATION.md) first. Use Devbox for development tools and preserve upstream license notices.

From the Teddy folder, run `devbox run -- bash scripts/check-teddy.sh` for native static analysis and the curated TED regression suite. See [README.md](README.md) for platform prerequisites and private builds. Use `devbox run -- bash scripts/build-teddy-macos.sh` for an isolated, immutable macOS build; never modify a running app bundle.

The retained Dart tests cover shared widgets, player controls and TED behavior. Tests do not establish coverage on untested native platforms; record device validation separately.
