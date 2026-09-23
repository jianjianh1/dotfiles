---
name: grill-me
description: Interview the user about an unfinished idea, decision, or plan when they ask to be grilled or questioned. Resolve important choices one question at a time before planning or execution; use premortem-analysis to critique a concrete plan.
---

# Grill me

Use Matt Pocock's [[grilling]] skill for its decision-tree method. Load its
`SKILL.md` through the available skill tool, or read it from the advertised
skill path. If no skill path is advertised, check
`~/.agents/skills/grilling/SKILL.md` and `~/.claude/skills/grilling/SKILL.md`.
If it is not installed, explain that the dotfiles repo's `install.sh`
installs the dependency and stop the interview.

This entry point adapts the upstream method for Claude Code and Codex. Its
session rules take precedence where the upstream skill differs:

1. Inspect available project facts before asking the user; use the tools at
   hand to answer discoverable questions. Do not delegate fact-finding merely
   because the upstream skill suggests it.
2. Map the decisions that depend on each other, then ask **one** high-value
   question per turn. Offer a recommended answer with its reason, and wait
   for the user's answer before choosing the next question.
3. Challenge vague or conflicting answers with a focused follow-up. Accept
   "I don't know" as an open question; identify what evidence would settle it
   instead of inventing a decision.
4. When the important branches are resolved or the user ends the interview,
   recap the decisions, assumptions, and remaining open questions in chat.
   Do not create files or start implementing the subject of the interview
   unless the user asks for that next step.

For a specific plan that is already settled and needs failure analysis,
use [[premortem-analysis]] instead of restarting discovery.
