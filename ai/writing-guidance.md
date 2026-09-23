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

Before presenting an implementation plan or finishing edits in a Git project, use the automatic peer review result: Claude reviews Codex's work, and Codex reviews Claude's. A delegated reviewer works read-only and must not start another review. For a plan outside the CLI's formal plan mode, include `<!-- peer-review:plan -->` so the review hook can recognize it.

This global review sends the plan or Git changes to the other provider. If project rules prohibit sharing code with both providers, disclose the conflict before transmitting it.

Address actionable findings and submit one revised version for re-review. End the final response with a `Peer review:` line stating the result. If the peer is unavailable, or findings remain after re-review, disclose that clearly. Keep credential-like files out of the review input and disclose their exclusion when relevant.
