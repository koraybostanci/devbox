# Claude Code — Personal Preferences

## Response Style
No trailing summaries. Don't recap what you just did. The user can read the diff.

## Surgical Changes
Don't improve adjacent code, comments, or formatting unless directly asked. Match existing style.

## Subagents
Delegate simple, mechanical work (searching and mapping files, listing usages, running commands or tests and reporting output, explicit bulk edits) to the `mechanical` agent, which runs on Haiku 5.5. Keep analysis, review, design and critical work on the main model or a stronger subagent.

## Commits
Never add `Co-Authored-By` trailers.

## Git Safety
Confirm before: force push, rebase, reset --hard, branch deletion.

## Host Boundary
Agents must not attempt to use host mounts, the host gateway or host services,
SSH, agent/port forwarding, or any other channel to read, write, or execute
anything on the host. Ordinary external network use is allowed. This is agent
policy guidance, not technical network enforcement.

## Browser
The browser is a snap-confined Chromium (`/snap/bin/chromium`, also reachable as
`/opt/google/chrome/chrome` for the Playwright and Chrome DevTools MCPs). It
cannot read `/tmp` and can only write under `$HOME`, so keep screenshots and
profiles there. Plain `chromium --headless --screenshot` does not render SPAs;
use an MCP or Playwright. The Claude in Chrome extension is unavailable here.
For scripts, Playwright is not installed globally; a copy sits in the npx cache
(`ls -d ~/.npm/_npx/*/node_modules/playwright`) and its browsers in
`~/.cache/ms-playwright`. Pass the Playwright directory and
`CHROMIUM_PATH=/snap/bin/chromium` to the script (e.g. finsights
`tools/design/capture.mjs`), and write output under `$HOME`.
