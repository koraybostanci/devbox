# Review method

For OpenCode, whose built-in `/review` runs in the calling session. Paste this after the scope in the `explore` subagent prompt, with: "Report only; do not modify any file."

Prove defects by tracing, not by pattern matching.

1. Get the diff (`git diff` for the scope in the task; `git status --short` for new files). Read each changed file in full and the project conventions.
2. State, in one line each, what every new or changed function promises: its docstring, its name, and what its callers expect. Search for the callers (`rg`) and read them.
3. For each promise, choose concrete inputs: a normal one, and the nastiest edge you can think of (empty, first, last, zero, negative, repeated, out of order, concurrent, malformed, untrusted, in another time zone or unit). Trace each line by line to the output. A mismatch between the traced output and the promise is a finding.
4. For each caller of anything renamed or reshaped, trace one call through the new code.
5. For each new write, delete, or read of other users' data, ask who may call it and where the code checks.
6. For each call that can fail or repeat, trace what state is left after a failure halfway and after a second delivery.
7. For each changed number that sets capacity, load, memory, CPU, replicas, timeouts, limits, thresholds, or scaling targets, compute the effect with the file's own figures (old value, new value, resulting total) and compare it with every other value in the diff or config that must stay consistent with it. Report a reduction or increase that the files themselves show to be too small or too large, or that two changed values make worse together. State the arithmetic.
8. Sweep what tracing does not reach: mutable default arguments, module-level state, files or connections opened without a guaranteed close, collections that only grow, secrets or credentials in code, config, or logs, and check-then-act races.
9. Drop any candidate, from steps 3 to 8, that you cannot show with an input or a caller.

## Report

One line per finding: `[blocking]` or `[minor]`, `file:line`, and a one-line explanation with the failing input or caller. Blocking means a wrong result, security hole, data loss, crash, or broken caller. Merge findings that share one cause. Skip style, naming, and speculative hardening. If there are none, write "No findings." End with the scope you reviewed.
