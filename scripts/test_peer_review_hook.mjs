#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const script = resolve(dirname(fileURLToPath(import.meta.url)), "peer-review-hook.mjs");
const temp = mkdtempSync(join(tmpdir(), "dotfiles-peer-review-test-"));
const repo = join(temp, "repo");
const bin = join(temp, "bin");
const state = join(temp, "state");
const log = join(temp, "calls.log");
const argsLog = join(temp, "args.log");
mkdirSync(repo);
mkdirSync(bin);

function run(binName, args, input, env = {}) {
  const result = spawnSync(binName, args, {
    cwd: repo, input, encoding: "utf8",
    env: { ...process.env, HOME: join(temp, "home"), ...env },
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${binName} failed: ${result.error || result.stderr}`);
  }
  return result.stdout;
}

function git(...args) { return run("git", args); }

function hook(agent, event, env = {}) {
  const raw = run("node", [script, agent], JSON.stringify({
    session_id: `test-${agent}`, cwd: repo, ...event,
  }), {
    DOTFILES_PEER_REVIEW_STATE_DIR: state,
    CODEX_BIN: join(bin, "codex"),
    CLAUDE_BIN: join(bin, "claude"),
    REVIEW_TEST_LOG: log,
    REVIEW_TEST_ARGS_LOG: argsLog,
    CLAUDE_REVIEW_MODEL: "sonnet",
    ...env,
  });
  return JSON.parse(raw);
}

function calls() {
  try { return readFileSync(log, "utf8").trim().split("\n").filter(Boolean); }
  catch { return []; }
}

function modelCalls() {
  try { return readFileSync(argsLog, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse); }
  catch { return []; }
}

writeFileSync(join(bin, "claude"), `#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(process.env.REVIEW_TEST_LOG, "claude\\n");
const args = process.argv.slice(2);
const model = args[args.indexOf("--model") + 1];
const input = fs.readFileSync(0, "utf8");
fs.appendFileSync(process.env.REVIEW_TEST_ARGS_LOG, JSON.stringify({agent:"claude",model,args,input}) + "\\n");
if ((process.env.REVIEW_TEST_LIMIT === "claude" && model === "sonnet") ||
    process.env.REVIEW_TEST_CLAUDE_LIMIT_BOTH === "1") {
  if (process.env.REVIEW_TEST_LIMIT_STYLE === "stderr") {
    process.stderr.write("rate limit exceeded\\n");
  } else {
    process.stdout.write(JSON.stringify({is_error:true,api_error_status:429,
      result:"You've hit your weekly limit"}));
  }
  process.exit(1);
}
if (process.env.REVIEW_TEST_HAIKU_LIMIT === "1" && model === "haiku") {
  process.stderr.write("You've hit your weekly limit\\n");
  process.exit(1);
}
if (process.env.REVIEW_TEST_FAIL === "1") process.exit(2);
const finding = {location:"plan step 1",problem:"Missing rollback",fix:"Add rollback"};
const review = process.env.REVIEW_TEST_ISSUES === "1" ?
  {verdict:"changes",findings:[finding]} : {verdict:"pass",findings:[]};
process.stdout.write(JSON.stringify({structured_output:review}));
`);
writeFileSync(join(bin, "codex"), `#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(process.env.REVIEW_TEST_LOG, "codex\\n");
const args = process.argv.slice(2);
const model = args[args.indexOf("-m") + 1];
const input = fs.readFileSync(0, "utf8");
fs.appendFileSync(process.env.REVIEW_TEST_ARGS_LOG, JSON.stringify({agent:"codex",model,args,input}) + "\\n");
if ((process.env.REVIEW_TEST_LIMIT === "codex" && model === "gpt-6-sol") ||
    process.env.REVIEW_TEST_CODEX_LIMIT_BOTH === "1") {
  process.stdout.write(JSON.stringify({type:"error",message:"rate_limit_exceeded"}) + "\\n");
  process.exit(process.env.REVIEW_TEST_LIMIT_STYLE === "event" ? 0 : 1);
}
if (process.env.REVIEW_TEST_LUNA_FAIL === "1" && model === "gpt-6-luna") {
  process.stderr.write("model unavailable\\n");
  process.exit(2);
}
if (process.env.REVIEW_TEST_FAIL === "1") process.exit(2);
const finding = {location:"plan step 1",problem:"Missing rollback",fix:"Add rollback"};
const review = process.env.REVIEW_TEST_ISSUES === "1" ?
  {verdict:"changes",findings:[finding]} : {verdict:"pass",findings:[]};
process.stdout.write(JSON.stringify({type:"item.completed",item:{type:"agent_message",text:JSON.stringify(review)}}) + "\\n");
`);
run("chmod", ["+x", join(bin, "claude"), join(bin, "codex")]);

try {
  git("init", "-q");
  git("config", "user.name", "Review Test");
  git("config", "user.email", "review@example.invalid");
  writeFileSync(join(repo, "main.js"), "export const value = 1;\n");
  writeFileSync(join(repo, "context.js"), "export const context = 1;\n");
  git("add", "main.js", "context.js");
  git("commit", "-qm", "Initial");

  // A pre-existing edit is included in the baseline but does not cause review.
  writeFileSync(join(repo, "main.js"), "export const value = 2;\n");
  writeFileSync(join(repo, "context.js"), "export const context = 2;\n");
  assert.deepEqual(hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Fix the code" }), {});
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", last_assistant_message: "No changes" }), {});
  assert.equal(calls().length, 0);

  // Plan mode alone does not turn explanations or examples into plans.
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: "Here is the diagnosis." }), {});
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: "Write <proposed_plan>steps</proposed_plan> in a plan." }), {});
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: "```md\n<proposed_plan>\nsteps\n</proposed_plan>\n<!-- peer-review:plan -->\n```" }), {});
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: "~~~md\n<!-- peer-review:plan -->\n~~~" }), {});
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: "<proposed_plan>\nUnclosed example" }), {});
  assert.equal(calls().length, 0);

  // A later edit triggers Claude once, then requires a visible review line.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Fix the code" });
  writeFileSync(join(repo, "main.js"), "export const value = 3;\n");
  let result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: "Fixed it" });
  assert.equal(result.decision, "block");
  assert.match(result.reason, /Claude found no actionable issues in Git changes since this prompt/);
  assert.deepEqual(calls(), ["claude"]);
  assert.equal(modelCalls().at(-1).input.split("\n")
    .find((line) => line.startsWith("Changed since user prompt:")),
  "Changed since user prompt: main.js");
  assert.deepEqual(hook("codex", { hook_event_name: "UserPromptSubmit", prompt: result.reason }), {});
  result = hook("codex", { hook_event_name: "Stop",
    last_assistant_message: "Peer review: Claude found no actionable issues." });
  assert.match(result.reason, /Git changes since this prompt/);
  assert.deepEqual(calls(), ["claude"]);
  result = hook("codex", { hook_event_name: "Stop",
    last_assistant_message: "Peer review: Claude found no actionable issues in Git changes since this prompt." });
  assert.deepEqual(result, {});
  assert.deepEqual(calls(), ["claude"]);

  // Untracked text is part of the change set.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Add a file" });
  writeFileSync(join(repo, "new.js"), "export const added = true;\n");
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Added a file" });
  assert.equal(result.decision, "block");
  assert.equal(calls().length, 2);
  hook("codex", { hook_event_name: "Stop",
    last_assistant_message: "Peer review: Claude found no actionable issues in Git changes since this prompt." });

  // Findings and unavailable reviews name the same per-prompt code scope.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Change code again" });
  writeFileSync(join(repo, "main.js"), "export const value = 4;\n");
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Changed code" },
    { REVIEW_TEST_ISSUES: "1" });
  assert.match(result.reason, /actionable issues in Git changes since this prompt.*Missing rollback/s);
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Changed code" });
  assert.match(result.reason, /found issues in Git changes since this prompt/);
  assert.deepEqual(hook("codex", { hook_event_name: "Stop",
    last_assistant_message: "Peer review: Claude found issues in Git changes since this prompt." }), {});

  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Change code again" });
  writeFileSync(join(repo, "main.js"), "export const value = 5;\n");
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Changed code" },
    { REVIEW_TEST_FAIL: "1" });
  assert.match(result.reason, /review was unavailable for Git changes since this prompt/);
  assert.deepEqual(hook("codex", { hook_event_name: "Stop",
    last_assistant_message: "Peer review: Claude review was unavailable for Git changes since this prompt." }), {});

  // A plan gets one review and one re-review after a revision.
  const first = "<proposed_plan>\nStep 1\n</proposed_plan>";
  const revised = "<proposed_plan>\nStep 1 with rollback\n</proposed_plan>";
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Plan it" });
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan", last_assistant_message: first }, { REVIEW_TEST_ISSUES: "1" });
  assert.equal(result.decision, "block");
  assert.match(result.reason, /the proposed plan.*Missing rollback/s);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan", last_assistant_message: revised });
  assert.equal(result.decision, "block");
  assert.match(result.reason, /no actionable issues/);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan", last_assistant_message: revised.replace("</proposed_plan>", "Peer review: Claude found no actionable issues.\n</proposed_plan>") });
  assert.match(result.reason, /the proposed plan/);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan", last_assistant_message: revised.replace("</proposed_plan>", "Peer review: Claude found no actionable issues in the proposed plan.\n</proposed_plan>") });
  assert.deepEqual(result, {});

  // Plan review does not depend on a Git repository.
  const nonGit = join(temp, "non-git");
  mkdirSync(nonGit);
  result = hook("codex", { hook_event_name: "Stop", cwd: nonGit,
    session_id: "outside-git", last_assistant_message: "<!-- peer-review:plan -->\n# Plan\nDo work" });
  assert.match(result.reason, /Claude found no actionable issues in the proposed plan/);
  result = hook("codex", { hook_event_name: "Stop", cwd: nonGit,
    session_id: "outside-git-formal", permission_mode: "plan",
    last_assistant_message: "<!-- peer-review:plan -->\n# Plain-text plan\nDo work" });
  assert.match(result.reason, /Claude found no actionable issues in the proposed plan/);

  // Claude's ExitPlanMode hook reviews before the plan is presented.
  hook("claude", { hook_event_name: "UserPromptSubmit", prompt: "Plan it" });
  result = hook("claude", { hook_event_name: "PreToolUse", tool_name: "ExitPlanMode", tool_input: { plan: "# Plan\nDo work" } }, { REVIEW_TEST_ISSUES: "1" });
  assert.equal(result.hookSpecificOutput.permissionDecision, "deny");
  result = hook("claude", { hook_event_name: "PermissionRequest", tool_name: "ExitPlanMode",
    tool_input: { plan: "# Plan\nDo work" } });
  assert.equal(result.hookSpecificOutput.decision.behavior, "deny");
  result = hook("claude", { hook_event_name: "PreToolUse", tool_name: "ExitPlanMode", tool_input: { plan: "# Plan\nDo work and rollback" } });
  assert.match(result.systemMessage, /Codex found no actionable issues in the proposed plan/);
  result = hook("claude", { hook_event_name: "PermissionRequest", tool_name: "ExitPlanMode",
    tool_input: { plan: "# Plan\nDo work and rollback" } });
  assert.match(result.systemMessage, /Codex found no actionable issues in the proposed plan/);

  // A Claude usage limit retries the same review with Haiku and names the model.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Plan with fallback" });
  let start = modelCalls().length;
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first }, { REVIEW_TEST_LIMIT: "claude" });
  assert.match(result.reason, /Claude \(haiku fallback\) found no actionable issues/);
  let attempts = modelCalls().slice(start);
  assert.deepEqual(attempts.map((call) => call.model), ["sonnet", "haiku"]);
  assert.equal(attempts[0].input, attempts[1].input);
  assert.ok(attempts.every((call) => call.args.includes("plan") &&
    call.args.includes("Read,Glob,Grep") && call.args.includes("--json-schema")));
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first.replace("</proposed_plan>", "Peer review: Claude passed.\n</proposed_plan>") });
  assert.match(result.reason, /naming haiku/);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first.replace("</proposed_plan>", "Peer review: Claude Haiku fallback found no actionable issues in the proposed plan.\n</proposed_plan>") });
  assert.deepEqual(result, {});

  // A Codex usage limit retries with GPT-6 Luna, including JSON error events.
  hook("claude", { hook_event_name: "UserPromptSubmit", prompt: "Plan with fallback" });
  start = modelCalls().length;
  result = hook("claude", { hook_event_name: "PreToolUse", tool_name: "ExitPlanMode",
    tool_input: { plan: "# Plan\nUse fallback" } },
  { REVIEW_TEST_LIMIT: "codex", REVIEW_TEST_LIMIT_STYLE: "event" });
  assert.match(result.systemMessage, /Codex \(gpt-6-luna fallback\) found no actionable issues/);
  attempts = modelCalls().slice(start);
  assert.deepEqual(attempts.map((call) => call.model), ["gpt-6-sol", "gpt-6-luna"]);
  assert.equal(attempts[0].input, attempts[1].input);
  assert.ok(attempts.every((call) => call.args.includes("read-only") &&
    call.args.includes("--output-schema") && call.args.includes("-a")));

  // Nonzero Codex error events and plain stderr limits also trigger one retry.
  hook("claude", { hook_event_name: "UserPromptSubmit", prompt: "Another plan" });
  start = modelCalls().length;
  result = hook("claude", { hook_event_name: "PreToolUse", tool_name: "ExitPlanMode",
    tool_input: { plan: "# Plan\nAnother fallback" } }, { REVIEW_TEST_LIMIT: "codex" });
  assert.match(result.systemMessage, /gpt-6-luna fallback/);
  assert.equal(modelCalls().length - start, 2);
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Stderr limit" });
  start = modelCalls().length;
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first }, { REVIEW_TEST_LIMIT: "claude", REVIEW_TEST_LIMIT_STYLE: "stderr" });
  assert.match(result.reason, /haiku fallback/);
  assert.equal(modelCalls().length - start, 2);

  // Fallback findings return to the author.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Review findings" });
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first }, { REVIEW_TEST_LIMIT: "claude", REVIEW_TEST_ISSUES: "1" });
  assert.match(result.reason, /haiku fallback.*Missing rollback/s);

  // A shared Claude limit switches to an independent Codex session.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Shared Claude limit" });
  start = modelCalls().length;
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first }, { REVIEW_TEST_CLAUDE_LIMIT_BOTH: "1" });
  assert.match(result.reason, /Codex \(gpt-6-luna fallback; same provider as author\) found no actionable issues/);
  attempts = modelCalls().slice(start);
  assert.deepEqual(attempts.map((call) => [call.agent, call.model]),
    [["claude", "sonnet"], ["claude", "haiku"], ["codex", "gpt-6-luna"]]);
  assert.equal(attempts[0].input, attempts[2].input);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first.replace("</proposed_plan>", "Peer review: Codex gpt-6-luna passed.\n</proposed_plan>") });
  assert.match(result.reason, /same provider as author/);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first.replace("</proposed_plan>", "Peer review: Codex GPT-6 Luna, same-provider fallback, found no actionable issues in the proposed plan.\n</proposed_plan>") });
  assert.deepEqual(result, {});

  // A shared Codex limit likewise switches to an independent Claude session.
  hook("claude", { hook_event_name: "UserPromptSubmit", prompt: "Shared Codex limit" });
  start = modelCalls().length;
  result = hook("claude", { hook_event_name: "PreToolUse", tool_name: "ExitPlanMode",
    tool_input: { plan: "# Plan\nUse same-provider fallback" } },
  { REVIEW_TEST_CODEX_LIMIT_BOTH: "1" });
  assert.match(result.systemMessage, /Claude \(haiku fallback; same provider as author\) found no actionable issues/);
  attempts = modelCalls().slice(start);
  assert.deepEqual(attempts.map((call) => [call.agent, call.model]),
    [["codex", "gpt-6-sol"], ["codex", "gpt-6-luna"], ["claude", "haiku"]]);
  assert.equal(attempts[0].input, attempts[2].input);

  // Sonnet and Haiku hit usage limits; Luna then fails for a different reason.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Shared limit" });
  start = modelCalls().length;
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan",
    last_assistant_message: first },
  { REVIEW_TEST_LIMIT: "claude", REVIEW_TEST_HAIKU_LIMIT: "1", REVIEW_TEST_LUNA_FAIL: "1" });
  assert.match(result.reason, /review was unavailable.*sonnet.*haiku.*weekly limit.*gpt-6-luna.*model unavailable/s);
  assert.equal(modelCalls().length - start, 3);

  // Reviewer failure is disclosed and delegated sessions never recurse.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Plan it" });
  start = modelCalls().length;
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan", last_assistant_message: first }, { REVIEW_TEST_FAIL: "1" });
  assert.match(result.reason, /review was unavailable/);
  assert.equal(modelCalls().length - start, 1);
  result = hook("codex", { hook_event_name: "Stop", permission_mode: "plan", last_assistant_message: first.replace("</proposed_plan>", "Peer review: Claude was unavailable for the proposed plan.\n</proposed_plan>") });
  assert.deepEqual(result, {});
  const before = calls().length;
  assert.deepEqual(hook("codex", { hook_event_name: "Stop", last_assistant_message: first }, { DOTFILES_PEER_REVIEW: "1" }), {});
  assert.equal(calls().length, before);

  // Credential-like files are omitted from review, with disclosure required.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Change auth" });
  writeFileSync(join(repo, "auth.json"), '{"token":"example"}\n');
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Changed auth" });
  assert.match(result.reason, /excluded from peer review/);
  assert.equal(calls().length, before);

  // A credential-shaped value in a normal source file is also excluded.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Change source" });
  const fakeKey = "AKIA" + "ABCDEFGHIJKLMNOP";
  writeFileSync(join(repo, "main.js"), `export const key = "${fakeKey}";\n`);
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Changed source" });
  assert.match(result.reason, /main.js.*excluded from peer review/s);
  assert.equal(calls().length, before);
  for (const name of readdirSync(state)) {
    assert.equal(readFileSync(join(state, name), "utf8").includes(fakeKey), false);
  }
  result = hook("codex", { hook_event_name: "Stop",
    last_assistant_message: "Peer review: Credential-like source content was excluded." });
  assert.deepEqual(result, {});
  assert.equal(calls().length, before);

  // GitHub App tokens receive the same treatment.
  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Change source again" });
  const fakeAppToken = "ghs_" + "A".repeat(36);
  writeFileSync(join(repo, "main.js"), `export const key = "${fakeAppToken}";\n`);
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Changed source" });
  assert.match(result.reason, /excluded from peer review/);
  assert.equal(calls().length, before);

  hook("codex", { hook_event_name: "UserPromptSubmit", prompt: "Add credentials" });
  writeFileSync(join(repo, ".git-credentials"), "https://user:example@host.invalid\n");
  result = hook("codex", { hook_event_name: "Stop", last_assistant_message: "Added credentials" });
  assert.match(result.reason, /\.git-credentials.*excluded from peer review/s);
  assert.equal(calls().length, before);

  // Missing session identity fails visibly instead of sharing state with another session.
  result = hook("codex", { hook_event_name: "UserPromptSubmit", session_id: null, prompt: "Plan" });
  assert.match(result.systemMessage, /missing session_id/);
  result = hook("codex", { hook_event_name: "Stop", session_id: null, last_assistant_message: "Done" });
  assert.match(result.reason, /missing session_id/);

  process.stdout.write("peer review hook tests passed\n");
} finally {
  rmSync(temp, { recursive: true, force: true });
}
