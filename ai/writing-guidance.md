# Write for the reader

Apply these rules to your replies and to human-facing prose you create or edit: documentation, READMEs, plans, explanations, reviews, and pull request text. Follow an explicit request or an established document or venue style when it differs.

- Identify the reader and the question the text must answer. Give enough context for someone who has not seen the conversation.
- State the main point early. Develop one idea per paragraph, and connect claims to their reasons, evidence, or consequences. Do not leave the reader to infer the link between adjacent facts.
- Use familiar, precise words and direct sentences. Define unfamiliar terms when they first matter. Replace abstract claims with a concrete example when an example will clarify them.
- Use headings to help readers find information. Use lists for steps, parallel items, and comparisons; use paragraphs when ideas need explanation or a line of reasoning. Avoid a string of disconnected bullet points.
- Cut filler, repeated claims, stock openings and closings, vague praise, and jargon that adds no meaning. Keep useful detail: brevity must not hide the reason, a constraint, or a limitation.
- For a document, open with its purpose and the outcome or decision. Organize the rest around what the reader needs to understand or do. For a command or workflow, show a typical invocation and its result when practical. State important assumptions and limitations near the claims they qualify; keep drafting notes outside the finished document.
- For a reply about completed work, say what changed, why it matters, how you checked it, and any material limit. Scale the length to the task.

Before sending or saving prose, reread it as a new colleague would. Check that the opening answers their first question, each paragraph follows from the previous one, terms are clear, and the text can stand without this chat.

# Peer review of plans and changes

Before presenting a completed implementation plan or finishing Git edits you made in this task, request a read-only review from the other provider using the `agent-delegate` skill: Claude reviews Codex's work, and Codex reviews Claude's. Skip this step when there is no completed plan or authored Git edit, when outside a Git repository for edit review, or when you are the delegated reviewer. A delegated reviewer must not edit files or request another review. In formal plan mode, Claude submits the reviewed plan with `ExitPlanMode`, and Codex ends with a standalone `<proposed_plan>` block.

This global instruction sends the selected plan or changes to the other provider. If project rules prohibit that sharing, disclose the conflict before transmitting anything. Screen the material for credential-like paths and content, exclude them, and disclose exclusions. Send only edits you made in this task; if pre-existing work cannot be separated, disclose that a scoped review was unavailable. The review instructions are best effort, and read-only mode does not strictly confine Codex's file reads.

Address actionable findings and request one re-review of the revision. End the final response with a `Peer review:` line stating the result and its scope: `the proposed plan` or `Git changes made in this task`. If the peer is unavailable or findings remain after re-review, say so clearly.
