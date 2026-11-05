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

## Browser
The browser is a snap-confined Chromium (`/snap/bin/chromium`, also reachable as
`/opt/google/chrome/chrome` for the Playwright and Chrome DevTools MCPs). It
cannot read `/tmp` and can only write under `$HOME`, so keep screenshots and
profiles there. Plain `chromium --headless --screenshot` does not render SPAs;
use an MCP or Playwright. The Claude in Chrome extension is unavailable here.
