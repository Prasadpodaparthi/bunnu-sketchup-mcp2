## TASK

Continue executing the implementation plan for dropping the SketchUp Extension Warehouse build variant (v0.3.1).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents)
- Assume what task to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-08-24-drop-warehouse-variant-design.md`
- Plan: `docs/superpowers/plans/2026-08-24-drop-warehouse-variant.md`
- **Execution ledger (read this — it is the authoritative record, not the todo list):** `.superpowers/sdd/2026-08-24-drop-warehouse-variant/progress.md`

Read all three. The plan has been trimmed: Tasks 1-4 now carry only their commit refs. The full original text is in git history at commit `21798c0`.

The ledger holds every ruling made on the user's behalf, every deferred minor finding, and the per-task review outcomes. It survives compaction; conversation memory does not.

## PROGRESS

Branch: `chore/drop-warehouse-variant`. Merge base: `13172a3`.

**Completed tasks:**
- [x] Task 1: Delete `extension.json`, collapse the version triple to a pair — `255d78b`, `2de1528`
- [x] Task 2: Remove the build variant from `package.rb`, `.gitignore`, `main.rb` — `7854c95`
- [x] Task 3: Collapse the `eval_enabled` default in `config.rb` — `5e92ed3`
- [x] Task 4: Remove catalogue mentions from the Python-facing texts — `7b24091`

Also on the branch: `21798c0` (controller's mid-flight plan corrections) and `c7b0d19` (plan trim).

**Remaining tasks:**
- [ ] Task 5: Bump version to 0.3.1 in six places + `uv lock`
- [ ] Task 6: Rewrite `README.md`, `CLAUDE.md`, the cookbook, and four in-code comments; refresh the test counts
- [ ] Task 7: Strip the Extension Warehouse submission procedure from `docs/release.md` (~220 of 346 lines)
- [ ] Task 8: Final verification — **Steps 1-8 and 10 only**, see Ruling R1 below

**Current state:** clean checkpoint. Working tree has no modified tracked files. Ruby `416 runs, 1116 assertions, 0 failures`; Python `177 passed`. No subagents in flight.

## SESSION CONTEXT

### Execution method

Run via `superpowers:subagent-driven-development`: one fresh implementer subagent per task, then a task review (spec compliance + code quality), then a scoped re-review for any fix round. Dispatch model is `opus` (from claude-mesh config `runtime.dispatch_model`) — pass it explicitly on every `Agent` call.

Task briefs for 5-8 are **already extracted** in the workspace as `task-5-brief.md` … `task-8-brief.md`. Briefs 2 and 3 were re-extracted after plan corrections; brief 1 is stale by design.

### Rulings already made (full text with cost-if-wrong in the ledger)

- **R1** — Task 8's Step 9 (`git rm -r docs/superpowers/`) is moved OUT of Task 8 and runs only after the final whole-branch review. The plan's own step order would delete the plan and spec the reviewer must read. Task 8's implementer executes Steps 1-8 and 10 only.
- **R2/R3** — the plan's `git add -A <paths>` commit steps were defective: naming a path already removed by `git rm` aborts with `pathspec did not match any files`. Fixed in the plan. Also: **never** run a bare `git add -A .` or `git add .` — the worktree holds an untracked, un-`.gitignore`d `.venv.broken-task8/` (leftover junk from an unrelated session) that a broad add would sweep into a commit.
- **R4** — a reviewer proposed adding a direct test for the loader's `ext.version`. Rejected after empirical disproof: setting the loader to `9.9.9` and running the full suite goes red, because the build test runs `ruby package.rb`, whose post-build check ties the loader to `package.rb`'s `VERSION`, which `test_version_pair.rb` ties to `SERVER_VERSION`. The three-way invariant is already closed at test time; a direct test would be the exact redundancy this branch exists to remove.
- **R5/R6** — two out-of-scope observations dismissed with reasons (a self-review grep of mine was unachievable; `release.md:158` dies with the §7 block Task 7 deletes).
- **R7** — Task 3's scope was expanded mid-flight: five further `BuildProfile` references were assigned to no task and would have failed the end-of-plan grep gate. All cleared.
- **R8** — `test_eval_enabled_default_is_false_when_missing` needs no change: the validator failing closed on a malformed payload stays correct under the new open default, for the same reason a corrupt pref fails closed.

### Traps found but not yet hit — carry these into the tasks that own them

- **Task 5:** `tests/test_compat.py:109` `test_python_version_matches_installed_metadata` asserts `compat.CLIENT_VERSION == version("sketchup-mcp2")` — i.e. `__version__` against the **installed distribution metadata**, currently `0.3.0`. The moment the bump lands, that test fails until the editable install refreshes. `uv` appears to re-sync on `uv run` and the plan runs `uv lock` first, but a failure there means "refresh the editable install", not "the bump is wrong".
- **Task 5:** consider folding in the deferred minor at `tests/test_version_tool.py:87` — a third weak `assert ".rbz" in ...` that Task 4's brief failed to name, so only 2 of 3 were strengthened. Suggested fix: `assert f"mcp_for_sketchup_v{compat.MAX_RUBY}.rbz" in payload["error"]` (that test patches nothing, so interpolation is correct and bump-proof).
- **Task 6:** `CLAUDE.md`'s "Arbitrary-code risk is guarded in three layers" bullet is now **factually wrong**, not merely stale — layer 1 ("off by default") and the fresh-install confirm no longer hold. `task-6-brief.md:83-98` already carries the corrected two-layer replacement. `CLAUDE.md:36,37,102` are also the last `build_profile` mentions outside `release.md`.
- **Task 7:** `docs/release.md:158` mentions `build_profile` and sits inside the §7 block (lines 123-300) that Task 7 deletes wholesale. No separate edit needed.

### Deferred minor findings — hand these to the final whole-branch review

The ledger lists eleven, each with file:line. The load-bearing ones:

1. `mcp_for_sketchup/package.rb:19` — comment says the loader declares metadata via `Sketchup::Extension.new`; it actually calls `SketchupExtension.new`, and no `Sketchup::Extension` constant exists. One word.
2. `tests/test_version_tool.py:87` — the third weak `.rbz` assertion (above).
3. `test/test_config.rb:276-284` — `test_read_default_sentinel_round_trip_for_eval_enabled` keeps a name and comment citing the sentinel design Task 3 deleted, and asserts only `StubReader`'s own behaviour.
4. `test/support/config_reset.rb:10` — `reset_all!` sets `eval_enabled = nil`, so the effective gate now flips closed→open between every test. Every gate-sensitive test sets state explicitly today, so nothing passes vacuously, but it is a trap for the next test author; one comment defuses it.
5. `test/test_package_output.rb:64` — the `.rbz` cleanup is not in an `ensure`, so a failing assertion leaves the artifact on disk.

### Two things that will bite you operationally

- **Subagent reports get truncated in delivery.** Three of four review reports in the last session were cut mid-sentence and had to be re-requested via `SendMessage`. Instruct reviewers to keep reports under ~60 lines and to put Spec Compliance, Issues and Assessment **first**, compressing Strengths.
- **Counting slips are this branch's recurring failure mode.** Five times a claim was made whose every individual statement was true but whose enumeration was wrong — most of them mine, in the plan text. Reviewers caught all five. Tell implementers and reviewers explicitly to verify *counts and sets*, not just individual truths.

## PLAN QUALITY WARNING

The plan was written for a large task and may contain:
- Errors or inaccuracies in implementation details
- Oversights about edge cases or dependencies
- Assumptions that don't match the actual codebase
- Missing steps or incomplete instructions

This has already happened five times in Tasks 1-4 (wrong version-literal count, broken `git add` command, suppressed stderr in the build test, a non-existent Ruby class name, and a two-of-three assertion set). Expect more in Tasks 5-8.

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the documents listed above, including the ledger
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
