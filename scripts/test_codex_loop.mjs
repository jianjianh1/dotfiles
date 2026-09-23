#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, chmodSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const SCRIPT = fileURLToPath(new URL("./codex-loop.mjs", import.meta.url));

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "codex-loop-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, "fake-codex");
  writeFileSync(bin, `#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(process.env.CODEX_LOOP_QUEUE_LOG, JSON.stringify(process.argv.slice(2)) + "\\n");
process.exit(Number(process.env.CODEX_LOOP_FAKE_EXIT || 0));
`);
  chmodSync(bin, 0o755);
  const env = {
    ...process.env,
    CODEX_THREAD_ID: "test-thread",
    CODEX_LOOP_STATE_DIR: root,
    CODEX_LOOP_CODEX_BIN: bin,
    CODEX_LOOP_QUEUE_LOG: join(root, "queue.jsonl"),
    CODEX_LOOP_TEST_NO_SPAWN: "1",
    CODEX_LOOP_TEST_NOW_MS: "1800000000000",
  };
  const call = (args, at = 1800000000000, input) => {
    const result = spawnSync(process.execPath, [SCRIPT, ...args], {
      cwd: root, env: { ...env, CODEX_LOOP_TEST_NOW_MS: String(at) },
      input: input && JSON.stringify(input), encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return result.stdout.trim();
  };
  const state = () => JSON.parse(readFileSync(join(root, "test-thread.json"), "utf8"));
  const queued = () => {
    try { return readFileSync(env.CODEX_LOOP_QUEUE_LOG, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)); }
    catch { return []; }
  };
  const fire = (job, at) => call(["__worker", "test-thread", job.id, job.token], at);
  const prompt = (turn, at) => {
    const message = queued().at(-1)[4];
    return JSON.parse(call(["hook"], at, { hook_event_name: "UserPromptSubmit", session_id: "test-thread", turn_id: turn, prompt: message }));
  };
  const stop = (turn, at) => JSON.parse(call(["hook"], at, { hook_event_name: "Stop", session_id: "test-thread", turn_id: turn }));
  return { root, env, call, state, queued, fire, prompt, stop };
}

test("fixed loops queue one run, coalesce missed ticks, and reject cancelled runs", (t) => {
  const f = fixture(t);
  f.call(["start", "--mode", "fixed", "--every", "5m", "--prompt", "check deploy"]);
  let job = f.state().jobs[0];
  f.fire(job, job.due);
  assert.equal(f.queued().length, 1);
  f.fire(job, job.due);
  assert.equal(f.queued().length, 1);
  assert.deepEqual(f.prompt("turn-1", job.due), {});
  f.stop("turn-1", job.due + 16 * 60_000);
  job = f.state().jobs[0];
  assert.equal(job.due, 1800000000000 + 25 * 60_000);
  f.fire(job, job.due);
  assert.equal(f.queued().length, 2);
  f.call(["stop", job.id], job.due);
  assert.match(JSON.stringify(f.prompt("turn-2", job.due)), /block/);
  assert.equal(f.state().jobs.length, 0);
});

test("adaptive loops use the chosen delay, then one fallback before stopping", (t) => {
  const f = fixture(t);
  f.call(["start", "--mode", "adaptive", "--prompt", "check CI"]);
  let job = f.state().jobs[0];
  f.fire(job, job.due);
  f.prompt("turn-a", job.due);
  assert.match(f.call(["next", job.id, "7m", "--reason", "CI is still running"], job.due), /7m/);
  f.stop("turn-a", job.due);
  job = f.state().jobs[0];
  assert.equal(job.due, 1800000000000 + 8 * 60_000);
  f.fire(job, job.due);
  f.prompt("turn-b", job.due);
  f.stop("turn-b", job.due);
  job = f.state().jobs[0];
  assert.equal(job.due, 1800000000000 + 28 * 60_000);
  f.fire(job, job.due);
  f.prompt("turn-c", job.due);
  f.stop("turn-c", job.due);
  assert.equal(f.state().jobs.length, 0);
});

test("one-time reminders finish once; session end pauses and resume rearms", (t) => {
  const f = fixture(t);
  f.call(["once", "--in", "45m", "--prompt", "remind me to push"]);
  let job = f.state().jobs[0];
  f.call(["hook"], 1800000000000 + 10 * 60_000, { hook_event_name: "SessionEnd", session_id: "test-thread" });
  f.fire(job, job.due);
  assert.equal(f.queued().length, 0);
  f.call(["hook"], 1800000000000 + 46 * 60_000, { hook_event_name: "SessionStart", session_id: "test-thread", source: "resume" });
  job = f.state().jobs[0];
  assert.equal(job.due, 1800000000000 + 47 * 60_000);
  f.fire(job, job.due);
  assert.equal(f.queued().length, 1);
  f.prompt("reminder-turn", job.due);
  f.stop("reminder-turn", job.due);
  assert.equal(f.state().jobs.length, 0);
});

test("queue failures retry without leaving a pending run", (t) => {
  const f = fixture(t);
  f.call(["start", "--mode", "fixed", "--every", "1m", "--prompt", "check"]);
  const job = f.state().jobs[0];
  f.env.CODEX_LOOP_FAKE_EXIT = "1";
  const result = spawnSync(process.execPath, [SCRIPT, "__worker", "test-thread", job.id, job.token], {
    cwd: f.root, env: { ...f.env, CODEX_LOOP_TEST_NOW_MS: String(job.due) }, encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  const next = f.state().jobs[0];
  assert.equal(next.retryCount, 1);
  assert.equal(next.pendingRun, null);
  assert.equal(next.due, job.due + 60_000);
  assert.equal(next.status, "scheduled");
});

test("durations round seconds to minutes and reject invalid values", (t) => {
  const f = fixture(t);
  assert.match(f.call(["start", "--mode", "fixed", "--every", "61s"]), /every 2m/);
  assert.match(f.call(["start", "--mode", "adaptive", "--first", "7m"]), /first run in 7m/);
  const result = spawnSync(process.execPath, [SCRIPT, "start", "--mode", "fixed", "--every", "0m"], {
    cwd: f.root, env: f.env, encoding: "utf8",
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /duration/);
});

test("bare loops reread the shared Claude prompt and expire after seven days", (t) => {
  const f = fixture(t);
  mkdirSync(join(f.root, ".claude"));
  writeFileSync(join(f.root, ".claude", "loop.md"), "check the release branch");
  f.call(["start", "--mode", "fixed", "--every", "1m"]);
  let job = f.state().jobs[0];
  f.fire(job, job.due);
  assert.match(f.queued()[0][4], /check the release branch/);
  f.prompt("turn-1", job.due);
  f.stop("turn-1", job.due);
  writeFileSync(join(f.root, ".claude", "loop.md"), "check the hotfix branch");
  job = f.state().jobs[0];
  f.fire(job, job.due);
  assert.match(f.queued()[1][4], /check the hotfix branch/);
  f.prompt("turn-2", job.due);
  f.stop("turn-2", job.due);
  job = f.state().jobs[0];
  f.fire(job, 1800000000000 + 7 * 24 * 60 * 60_000 + 1);
  assert.equal(f.state().jobs.length, 0);
});

test("concurrent starts keep every job", async (t) => {
  const f = fixture(t);
  const commands = Array.from({ length: 8 }, (_, index) => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [SCRIPT, "start", "--mode", "fixed", "--every", "5m", "--prompt", `check ${index}`], {
      cwd: f.root, env: f.env, stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(stderr)));
    child.on("error", reject);
  }));
  await Promise.all(commands);
  assert.equal(f.state().jobs.length, 8);
  assert.equal(new Set(f.state().jobs.map((job) => job.id)).size, 8);
});

test("installed symlink runs and stale queued prompts fail closed", (t) => {
  const f = fixture(t);
  const link = join(f.root, "codex-loop");
  symlinkSync(SCRIPT, link);
  const listed = spawnSync(link, ["list"], { cwd: f.root, env: f.env, encoding: "utf8" });
  assert.equal(listed.status, 0, listed.stderr);
  assert.match(listed.stdout, /No scheduled jobs/);
  const rejected = JSON.parse(f.call(["hook"], 1800000000000, {
    hook_event_name: "UserPromptSubmit", session_id: "test-thread", turn_id: "stale",
    prompt: "<!-- dotfiles-codex-loop job=1234abcd run=1234567890abcdef -->\nstale",
  }));
  assert.equal(rejected.decision, "block");
});
