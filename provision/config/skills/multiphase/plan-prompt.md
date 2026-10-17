Finalize the plan file so that the /multiphase skill can run it in a fresh session with no access to this conversation. Do not start implementing.

1. Resolve ambiguity first. List every open question or ambiguous decision in the plan. Ask me about them and wait for my answers before you edit the plan file.

2. Structure the plan as ordered phases. If it is not already phased, split it into phases now. Use one heading per phase, in execution order: `## Phase N: <title>`. Make each phase self-contained. Implementers receive only their own phase section plus the "Context for implementers" section. Do not use references like "as discussed" or "see above". Each phase section must contain exactly these fields:
   - Goal: one or two sentences.
   - Depends on: earlier phases it needs, or "none".
   - Files in scope: exact paths. The implementer must not touch anything else.
   - Verification command: the exact runnable command, not a description. State the expected result.
   - Done criteria: observable conditions, each one checkable.

3. Keep phases reviewable. One phase must produce a diff that one reviewer can check in one pass. As a guide: one concern per phase, roughly 300 changed lines or fewer. Split any phase that is larger.

4. Add a section titled exactly "Context for implementers". It must hold what our brainstorm decided and the implementers need: key decisions and why, rejected alternatives and why, constraints, gotchas, and open risks. If it is not written in the plan file, the implementers do not know it.

5. When done, reply in at most three lines: confirm the file is saved, give its absolute path, and name any phase you are unsure about. Do not recap the plan.
