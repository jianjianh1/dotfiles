#!/usr/bin/env node

// Session-scoped prompt scheduling for Codex CLI. Only the user's explicit
// $loop request creates jobs; hooks and workers maintain those jobs afterward.
import { randomBytes } from "node:crypto";
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(import.meta.url);
const STATE_DIR = process.env.CODEX_LOOP_STATE_DIR || join(homedir(), ".local", "state", "dotfiles-codex-loop");
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const MAX_JOBS = 50;
const MAX_AGE = 7 * 24 * HOUR;
const MAX_PROMPT_BYTES = 25_000;
const MARKER = /^<!-- dotfiles-codex-loop job=([a-f0-9]{8}) run=([a-f0-9]{16}) -->\n/;
const MAINTENANCE = `Continue unfinished work from this conversation. Then tend the current branch's pull request: check new review comments, failed CI, and merge conflicts. If nothing is pending, look for a small, relevant cleanup or bug fix. Do not start a new initiative. Only push, delete, or take another irreversible action when the conversation already authorized it.`;

function now() {
  const override = Number(process.env.CODEX_LOOP_TEST_NOW_MS);
  return Number.isFinite(override) && override > 0 ? override : Date.now();
}

function fail(message) {
  throw new Error(message);
}

function threadId(value = process.env.CODEX_THREAD_ID) {
  if (!value || !/^[a-zA-Z0-9_-]{1,100}$/.test(value)) fail("$loop needs an active Codex CLI thread (CODEX_THREAD_ID is missing).");
  return value;
}

function paths(thread) {
  threadId(thread);
  return { file: join(STATE_DIR, `${thread}.json`), lock: join(STATE_DIR, `${thread}.lock`) };
}

function ensureDir() {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  chmodSync(STATE_DIR, 0o700);
}

function readState(thread) {
  const { file } = paths(thread);
  try { return JSON.parse(readFileSync(file, "utf8")); }
  catch (error) {
    if (error.code === "ENOENT") return { thread, paused: false, jobs: [] };
    throw error;
  }
}

function writeState(thread, state) {
  const { file } = paths(thread);
  const temp = `${file}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  writeFileSync(temp, JSON.stringify(state), { mode: 0o600 });
  renameSync(temp, file);
}

function withState(thread, fn) {
  ensureDir();
  const { lock } = paths(thread);
  const sleeper = new Int32Array(new SharedArrayBuffer(4));
  let acquired = false;
  for (let attempt = 0; attempt < 200; attempt++) {
    try { mkdirSync(lock, { mode: 0o700 }); acquired = true; break; }
    catch (error) {
      if (error.code !== "EEXIST") throw error;
      try {
        if (Date.now() - statSync(lock).mtimeMs > 30_000) rmSync(lock, { recursive: true, force: true });
      } catch { /* another process removed the lock */ }
      Atomics.wait(sleeper, 0, 0, 25);
    }
  }
  if (!acquired) fail("$loop state is busy; retry in a moment.");
  try {
    const state = readState(thread);
    const result = fn(state);
    writeState(thread, state);
    return result;
  } finally {
    rmSync(lock, { recursive: true, force: true });
  }
}

function duration(value, { adaptive = false } = {}) {
  const match = /^([1-9][0-9]*)(s|m|h|d)$/i.exec(String(value || ""));
  if (!match) fail("Use a duration such as 5m, 2h, or 1d.");
  const unit = match[2].toLowerCase();
  const multiplier = { s: 1_000, m: MINUTE, h: HOUR, d: 24 * HOUR }[unit];
  const ms = Math.ceil(Number(match[1]) * multiplier / MINUTE) * MINUTE;
  if (!Number.isSafeInteger(ms) || ms < MINUTE) fail("The interval must be at least one minute.");
  if (adaptive && ms > HOUR) fail("Adaptive intervals must be between one minute and one hour.");
  return ms;
}

function formatDuration(ms) {
  if (ms % (24 * HOUR) === 0) return `${ms / (24 * HOUR)}d`;
  if (ms % HOUR === 0) return `${ms / HOUR}h`;
  return `${ms / MINUTE}m`;
}

function newId(state) {
  let id;
  do { id = randomBytes(4).toString("hex"); }
  while (state.jobs.some((job) => job.id === id));
  return id;
}

function arm(job, due) {
  job.due = due;
  job.token = randomBytes(8).toString("hex");
  job.status = "scheduled";
}

function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code === "EPERM"; }
}

function ensureWorker(thread) {
  if (process.env.CODEX_LOOP_TEST_NO_SPAWN === "1") return;
  withState(thread, (state) => {
    if (state.paused || !state.jobs.some((job) => job.status === "scheduled" || job.status === "pending" || job.status === "running")) return;
    if (processAlive(state.workerPid)) return;
    const child = spawn(process.execPath, [SCRIPT, "__worker", thread], {
      detached: true, stdio: "ignore", env: { ...process.env, CODEX_THREAD_ID: thread },
    });
    state.workerPid = child.pid;
    child.unref();
  });
}

function projectRoot(cwd) {
  try { return execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); }
  catch { return cwd; }
}

function defaultPrompt(job) {
  for (const file of [join(projectRoot(job.cwd), ".claude", "loop.md"), join(homedir(), ".claude", "loop.md")]) {
    try {
      const content = readFileSync(file).subarray(0, MAX_PROMPT_BYTES).toString("utf8").trim();
      if (content) return content;
    } catch { /* an unreadable default does not disable the loop */ }
  }
  return MAINTENANCE;
}

function queuedMessage(job, run) {
  const prompt = job.prompt || defaultPrompt(job);
  const intro = job.mode === "once" ? "One-time reminder" : "Scheduled loop iteration";
  const next = job.mode === "adaptive" ? `\n\nAfter this iteration, call codex-loop next ${job.id} <1m-1h> --reason "<reason>" and report the delay and reason, or call codex-loop stop ${job.id} when the task is complete. Do this before your final response.` : "";
  return `<!-- dotfiles-codex-loop job=${job.id} run=${run} -->\n${intro} ${job.id}: ${prompt}${next}`;
}

function parseOptions(args) {
  const options = {};
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (!["--mode", "--every", "--first", "--prompt", "--in", "--at", "--reason"].includes(key) || i + 1 >= args.length) fail(`Unknown or incomplete option: ${key}`);
    options[key.slice(2)] = args[++i];
  }
  return options;
}

function createJob(command, args) {
  const thread = threadId();
  const options = parseOptions(args);
  const mode = command === "once" ? "once" : options.mode;
  if (!["fixed", "adaptive", "once"].includes(mode)) fail("Choose --mode fixed or --mode adaptive.");
  if (mode === "fixed" && !options.every) fail("Fixed loops need --every <duration>.");
  if (mode === "once" && Number(Boolean(options.in)) + Number(Boolean(options.at)) !== 1) fail("Reminders need exactly one of --in <duration> or --at <ISO time>.");
  if (mode === "once" && !options.prompt?.trim()) fail("Reminders need a prompt.");
  if (mode !== "once" && (options.in || options.at)) fail("Use once for one-time reminders.");
  if (options.first && mode !== "adaptive") fail("Only adaptive loops accept --first.");
  if (options.at && !/T\d\d:\d\d(?::\d\d(?:\.\d+)?)?(?:Z|[+-]\d\d:\d\d)$/.test(options.at)) fail("Use ISO time with an explicit timezone offset.");
  const interval = mode === "fixed" ? duration(options.every) : null;
  if (interval >= MAX_AGE) fail("Fixed intervals must be shorter than the seven-day job lifetime.");
  const first = mode === "adaptive" ? (options.first ? duration(options.first, { adaptive: true }) : MINUTE) : null;
  const due = mode === "fixed" ? now() + interval : mode === "adaptive" ? now() + first :
    options.in ? now() + duration(options.in) : Date.parse(options.at);
  if (!Number.isFinite(due) || due <= now()) fail("Reminder time must be in the future.");
  if (options.prompt && Buffer.byteLength(options.prompt) > MAX_PROMPT_BYTES) fail("Prompt exceeds 25,000 bytes.");
  const cwd = resolve(process.cwd());
  const job = withState(thread, (state) => {
    state.jobs = state.jobs.filter((entry) => entry.mode === "once" || entry.created + MAX_AGE > now());
    if (state.jobs.length >= MAX_JOBS) fail("A thread can have at most 50 scheduled jobs.");
    const entry = { id: newId(state), thread, cwd, mode, prompt: options.prompt?.trim() || "", interval, created: now(), due,
      token: "", status: "scheduled", pendingRun: null, activeTurnId: null, fallbackCount: 0, retryCount: 0, requestedDelay: null };
    state.jobs.push(entry);
    arm(entry, due);
    return entry;
  });
  ensureWorker(thread);
  return `${job.id}: ${mode === "fixed" ? `every ${formatDuration(interval)}` : mode === "adaptive" ? `adaptive (first run in ${formatDuration(first)})` : `once at ${new Date(due).toLocaleString()}`} — ${job.prompt || "default maintenance prompt"}`;
}

function listJobs() {
  const state = readState(threadId());
  if (!state.jobs.length) return "No scheduled jobs in this Codex thread.";
  return state.jobs.map((job) => `${job.id} ${job.mode} ${job.status}${state.paused ? " (session paused)" : ""} next=${new Date(job.due).toLocaleString()} ${job.prompt || "default maintenance prompt"}${job.error ? ` error=${job.error}` : ""}`).join("\n");
}

function stopJob(id) {
  const thread = threadId();
  const removed = withState(thread, (state) => {
    const before = state.jobs.length;
    state.jobs = id === "all" ? [] : state.jobs.filter((job) => job.id !== id);
    return before - state.jobs.length;
  });
  return removed ? `Stopped ${removed} job${removed === 1 ? "" : "s"}.` : `No job named ${id}.`;
}

function nextJob(id, value, reason) {
  if (!reason?.trim()) fail("Adaptive scheduling needs --reason <text>.");
  const delay = duration(value, { adaptive: true });
  withState(threadId(), (state) => {
    const job = state.jobs.find((entry) => entry.id === id);
    if (!job || job.mode !== "adaptive" || job.status !== "running") fail("No running adaptive loop has that ID.");
    job.requestedDelay = delay;
    job.requestedReason = reason.trim().slice(0, 500);
  });
  return `${id}: next run ${formatDuration(delay)} after this turn — ${reason.trim()}`;
}

function hook(event) {
  const thread = threadId(event.session_id);
  if (!existsSync(paths(thread).file)) {
    return event.hook_event_name === "UserPromptSubmit" && MARKER.test(event.prompt || "") ?
      { decision: "block", reason: "This scheduled loop run no longer exists." } : {};
  }
  if (event.hook_event_name === "UserPromptSubmit") {
    const match = MARKER.exec(event.prompt || "");
    if (!match) return {};
    let accepted = false;
    withState(thread, (state) => {
      const job = state.jobs.find((entry) => entry.id === match[1]);
      if (!state.paused && job && job.pendingRun === match[2] && job.status === "pending" &&
          (job.mode === "once" || job.created + MAX_AGE > now())) {
        job.activeTurnId = event.turn_id;
        job.status = "running";
        accepted = true;
      }
    });
    return accepted ? {} : { decision: "block", reason: "This scheduled loop run was cancelled, expired, or superseded." };
  }
  if (event.hook_event_name === "Stop") {
    let rearmed = false;
    withState(thread, (state) => {
      for (const job of [...state.jobs]) {
        if (job.activeTurnId !== event.turn_id || job.status !== "running") continue;
        job.activeTurnId = null;
        job.pendingRun = null;
        job.retryCount = 0;
        if (job.mode === "once" || job.created + MAX_AGE <= now()) {
          state.jobs = state.jobs.filter((entry) => entry.id !== job.id);
          continue;
        }
        if (job.mode === "fixed") {
          let due = job.due + job.interval;
          while (due <= now()) due += job.interval;
          arm(job, due);
          rearmed = true;
        } else if (job.requestedDelay) {
          job.fallbackCount = 0;
          arm(job, now() + job.requestedDelay);
          rearmed = true;
          job.requestedDelay = null;
        } else if (job.fallbackCount === 0) {
          job.fallbackCount = 1;
          arm(job, now() + 20 * MINUTE);
          rearmed = true;
        } else {
          state.jobs = state.jobs.filter((entry) => entry.id !== job.id);
        }
      }
    });
    if (rearmed) ensureWorker(thread);
    return {};
  }
  if (event.hook_event_name === "SessionEnd") {
    withState(thread, (state) => {
      state.paused = true;
      for (const job of state.jobs) {
        job.token = randomBytes(8).toString("hex");
        job.pendingRun = null;
        job.activeTurnId = null;
        job.status = "scheduled";
      }
    });
    return {};
  }
  if (event.hook_event_name === "SessionStart" && ["startup", "resume"].includes(event.source)) {
    withState(thread, (state) => {
      state.paused = false;
      state.jobs = state.jobs.filter((job) => job.mode === "once" || job.created + MAX_AGE > now());
      for (const job of state.jobs) {
        if (job.status === "running") continue;
        job.pendingRun = null;
        job.activeTurnId = null;
        const due = job.due <= now() ? now() + MINUTE : job.due;
        arm(job, due);
      }
    });
    ensureWorker(thread);
  }
  return {};
}

function dispatch(thread, id, token) {
  const run = randomBytes(8).toString("hex");
  let message;
  let claimed = false;
  withState(thread, (current) => {
    const target = current.jobs.find((entry) => entry.id === id && entry.token === token);
    if (!target || current.paused || target.status !== "scheduled") return;
    if (target.mode !== "once" && target.created + MAX_AGE <= now()) {
      current.jobs = current.jobs.filter((entry) => entry.id !== id);
      return;
    }
    message = queuedMessage(target, run);
    target.pendingRun = run;
    target.status = "pending";
    target.error = null;
    claimed = true;
  });
  if (!claimed) return;
  const result = spawnSync(process.env.CODEX_LOOP_CODEX_BIN || "codex", ["queue", "--thread", thread, "--message", message], {
    encoding: "utf8", timeout: 30_000, maxBuffer: 64 * 1024,
  });
  if (result.status === 0) return;
  withState(thread, (current) => {
    const target = current.jobs.find((entry) => entry.id === id && entry.pendingRun === run);
    if (!target) return;
    target.pendingRun = null;
    target.retryCount++;
    target.error = String(result.error?.message || result.stderr || `codex queue exited ${result.status}`).trim().slice(0, 300);
    if (target.retryCount <= 3 && !current.paused) arm(target, now() + Math.min(2 ** (target.retryCount - 1) * MINUTE, 4 * MINUTE));
    else target.status = "error";
  });
}

async function worker(thread) {
  const singlePass = process.env.CODEX_LOOP_TEST_NO_SPAWN === "1";
  try {
    while (true) {
      const state = readState(thread);
      if (state.paused || !state.jobs.some((job) => ["scheduled", "pending", "running"].includes(job.status)) ||
          (!singlePass && state.workerPid !== process.pid)) return;
      const due = state.jobs.filter((job) => job.status === "scheduled" && job.due <= now());
      for (const job of due) dispatch(thread, job.id, job.token);
      if (singlePass) return;
      const nextDue = Math.min(...state.jobs.filter((job) => job.status === "scheduled").map((job) => job.due));
      const wait = Number.isFinite(nextDue) ? Math.max(250, Math.min(5_000, nextDue - now())) : 5_000;
      await new Promise((done) => setTimeout(done, wait));
    }
  } finally {
    if (!singlePass) withState(thread, (state) => {
      if (state.workerPid === process.pid) state.workerPid = null;
    });
  }
}

async function main(args) {
  const [command, ...rest] = args;
  if (command === "hook") {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    process.stdout.write(`${JSON.stringify(hook(JSON.parse(Buffer.concat(chunks).toString("utf8"))))}\n`);
    return;
  }
  if (command === "__worker") return worker(...rest);
  let output;
  if (command === "start" || command === "once") output = createJob(command, rest);
  else if (command === "list") output = listJobs();
  else if (command === "stop") output = stopJob(rest[0] || fail("Specify a job ID or all."));
  else if (command === "next") {
    const options = parseOptions(rest.slice(2));
    output = nextJob(rest[0], rest[1], options.reason);
  } else fail("Usage: codex-loop start --mode fixed --every 5m [--prompt text] | start --mode adaptive [--first 5m] [--prompt text] | once --in 45m --prompt text | once --at ISO --prompt text | list | stop <id|all> | next <id> <duration> --reason text");
  process.stdout.write(`${output}\n`);
}

if (process.argv[1] && realpathSync(resolve(process.argv[1])) === realpathSync(SCRIPT)) {
  main(process.argv.slice(2)).catch((error) => {
    if (process.argv[2] === "hook") process.stdout.write(`${JSON.stringify({ systemMessage: `$loop hook failed: ${error.message}` })}\n`);
    else console.error(`codex-loop: ${error.message}`);
    process.exitCode = 1;
  });
}

export { duration, hook, readState, worker };
