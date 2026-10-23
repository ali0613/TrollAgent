# RULES.md — TrollAgent Operating Contract

> Every task executed on TrollAgent is bound by this contract. Semantics follow RFC 2119: MUST, MUST NOT, SHOULD, MAY.

## Routing Contract (MUST)

1. **Route first, then act**: on receiving a task, run `skills.list` to search for a matching skill; on a hit, `skills.read` the full instructions and execute them. Don't randomly try tools without checking skills.
2. Output the selected skill's **PRIMARY** path plus a one-line rationale.
3. For complex tasks, pin down the target first: explicit "object app / file path / database / package", no placeholders.
4. No skill hit → compose tools from tool summaries, or propose adding a skill. **Never** force a task into a mismatched tool.

## Tool Usage (MUST NOT)

- **Don't** rely on glob expansion, relative paths after `cd`, or binary grep (`grep -a` is unreliable on Mach-O/binary) — always use absolute paths.
- **Don't** manually `cp/echo` across environments into Alpine `/tmp` (one-way bridge; files written on the iOS side after that are invisible to Alpine). For cross-environment data use the auto-bridge or write from the Alpine side.
- **Don't** modify app binaries / dylibs / databases before confirming the target; read first, then decide.
- **Don't** silently overwrite the user's existing files; back up before any replace/injection (`_bak` or a copy).

## Operational Safety (SHOULD)

- Before system-level operations (injection, signing, capture certs, kernel helpers), do a **read-only probe** (status / file metadata / logs) to confirm the current state first.
- On failure, read the error and fix per the hint; after two consecutive failures of the same kind, switch command/path/approach — no infinite retries.
- When using `bin/` helpers (ldid / opainject / insert_dylib etc.), confirm their dependencies and execute permissions; if the shell can't execute an in-bundle tool, handle it from the app process or via bridging.

## Evidence Contract (MUST)

- Conclusions must carry reproducible evidence: the command as run, absolute file paths, byte counts, hashes, table structures, key lines.
- Distinguish "verified" from "inferred"; explicitly mark fields you couldn't obtain — never fabricate.
- Numbers (size/count/duration) come from real command output, not estimates.

## Conclusion Contract (SHOULD)

- Complex analyses output in **Evidence → Finding → Path** order: evidence first, then the judgment, then the next-step path.
- Multi-step flows (inject→verify, capture→certs, unpack→analyze) follow the workflow recommended by the skill; don't skip steps.

## Self-Check Before Claiming Done (MUST pass)

- [ ] Did I actually execute each step of the workflow (not just read)?
- [ ] Did I use real tool paths / absolute paths?
- [ ] Did I produce reproducible evidence (commands/paths/bytes/hashes/table structure)?
- [ ] Did I distinguish verified from inferred?
- [ ] Did I give a next-step path (or explicitly say "that's it")?

## Failure & Delivery

- When something genuinely can't be done, state the incomplete items, the reason and the impact — don't quietly downgrade and claim done.
- Deliverables come with an accessible path and how to open them.
