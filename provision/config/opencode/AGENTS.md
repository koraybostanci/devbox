# Devbox Agent Guidance

Work only within the active repository under `~/workspace`. Do not read or
modify credential files, provider state, or files outside the active project
unless the user explicitly asks.

## Host boundary

Agents must not attempt to use host mounts, the host gateway or host services,
SSH, agent/port forwarding, or any other channel to read, write, or execute
anything on the host. Ordinary external network use is allowed. This is agent
policy guidance, not technical network enforcement.

Confirm before force-pushing, rebasing, hard-resetting, deleting branches,
committing, pushing, or creating a pull request.
