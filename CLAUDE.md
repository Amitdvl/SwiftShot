# Projects

See @AGENTS.md for available CLI tools, build commands, and conventions.

## Conventions
- After any task that starts Docker containers, run `~/scripts/docker-cleanup.sh` before finishing.
- After any code change to SwiftShot-Native, always rebuild the binary and package it into `dist/` before committing. The user must always have a fresh binary.
- After each session: always `git push` AND rebuild/repackage the binary into `dist/`. Never end a session without both.
