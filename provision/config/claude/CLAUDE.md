# Claude Code — Personal Preferences

## Response Style
No trailing summaries. Don't recap what you just did. The user can read the diff.

## Surgical Changes
Don't improve adjacent code, comments, or formatting unless directly asked. Match existing style.

## Commits
Never add `Co-Authored-By` trailers.

## Git Safety
Confirm before: force push, rebase, reset --hard, branch deletion.

## Host Boundary
Agents must not attempt to use host mounts, the host gateway or host services,
SSH, agent/port forwarding, or any other channel to read, write, or execute
anything on the host. Ordinary external network use is allowed. This is agent
policy guidance, not technical network enforcement.
