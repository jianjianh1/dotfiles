# Optional skills

Skills are optional references. Choose them when they help with the task, or
when the user requests them. Selecting a skill does not itself require extra
approvals, separate plan documents, worktrees, or test-first steps. Follow
explicitly requested workflows and existing project, permission, and host
operational requirements. Cross-review below remains required.

# Peer review of plans and changes

Before presenting a completed implementation plan or finishing Git edits you made in this task, request a read-only review from the other provider using the `agent-delegate` skill: Claude reviews Codex's work, and Codex reviews Claude's. Skip this step when there is no completed plan or authored Git edit, when outside a Git repository for edit review, or when you are the delegated reviewer. A delegated reviewer must not edit files or request another review. In formal plan mode, Claude submits the reviewed plan with `ExitPlanMode`, and Codex ends with a standalone `<proposed_plan>` block.

This global instruction sends the selected plan or changes to the other provider. If project rules prohibit that sharing, disclose the conflict before transmitting anything. Screen the material for credential-like paths and content, exclude them, and disclose exclusions. Send only edits you made in this task; if pre-existing work cannot be separated, disclose that a scoped review was unavailable. The review instructions are best effort, and read-only mode does not strictly confine Codex's file reads.

Address actionable findings and request one re-review of the revision. End the final response with a `Peer review:` line stating the result and its scope: `the proposed plan` or `Git changes made in this task`. If the peer is unavailable or findings remain after re-review, say so clearly.
