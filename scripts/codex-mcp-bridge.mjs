#!/usr/bin/env node

// Dependency-free stdio MCP adapter for current Codex CLI releases. Codex
// removed its deprecated `mcp-server` command, so Claude talks to this small
// bridge, which invokes `codex exec` and `codex exec resume` underneath.

import { spawn } from "node:child_process";
import { statSync } from "node:fs";
import { createInterface } from "node:readline";

const SERVER_NAME = "dotfiles-codex-bridge";
const SERVER_VERSION = "1.0.0";
const DEFAULT_PROTOCOL = "2025-11-25";
const MAX_ERROR_BYTES = 8192;
const running = new Map();

const tools = [
  {
    name: "codex",
    description: "Start a non-interactive Codex task. Defaults to a read-only sandbox and never prompts for approval.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        prompt: { type: "string", minLength: 1 },
        cwd: { type: "string", description: "Absolute working directory; defaults to the bridge process directory." },
        sandbox: { type: "string", enum: ["read-only", "workspace-write"], default: "read-only" },
        "approval-policy": { type: "string", enum: ["never"], default: "never" },
        model: { type: "string", minLength: 1 },
        "developer-instructions": { type: "string" },
      },
      required: ["prompt"],
    },
  },
  {
    name: "codex-reply",
    description: "Continue an existing Codex thread returned by the codex tool.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        threadId: { type: "string", minLength: 1 },
        prompt: { type: "string", minLength: 1 },
        model: { type: "string", minLength: 1 },
      },
      required: ["threadId", "prompt"],
    },
  },
];

function send(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function response(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function errorResponse(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${name} must be a non-empty string`);
  }
  return value;
}

function resolveDirectory(value) {
  const cwd = value === undefined ? process.cwd() : requireString(value, "cwd");
  let stat;
  try {
    stat = statSync(cwd);
  } catch {
    throw new Error(`cwd does not exist: ${cwd}`);
  }
  if (!stat.isDirectory()) throw new Error(`cwd is not a directory: ${cwd}`);
  return cwd;
}

function parseCodexEvent(line, state) {
  if (!line.trim()) return;
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return;
  }
  if (event.type === "thread.started" && typeof event.thread_id === "string") {
    state.threadId = event.thread_id;
  }
  if (event.type === "item.completed" && event.item?.type === "agent_message" &&
      typeof event.item.text === "string") {
    state.content = event.item.text;
  }
  if (event.type === "error" && typeof event.message === "string") {
    state.eventError = event.message;
  }
}

function runCodex(requestId, args, cwd) {
  return new Promise((resolve, reject) => {
    const executable = process.env.CODEX_BIN || "codex";
    const child = spawn(executable, args, {
      cwd,
      env: { ...process.env, NO_COLOR: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const key = JSON.stringify(requestId);
    const state = { threadId: "", content: "", eventError: "", stderr: "" };
    running.set(key, child);

    const output = createInterface({ input: child.stdout });
    output.on("line", (line) => parseCodexEvent(line, state));
    child.stderr.on("data", (chunk) => {
      if (state.stderr.length < MAX_ERROR_BYTES) {
        state.stderr += chunk.toString().slice(0, MAX_ERROR_BYTES - state.stderr.length);
      }
    });
    child.on("error", (error) => {
      running.delete(key);
      reject(new Error(`could not start Codex: ${error.message}`));
    });
    child.on("close", (code, signal) => {
      running.delete(key);
      if (code !== 0) {
        const detail = state.eventError || state.stderr.trim() || `exit code ${code}${signal ? ` (${signal})` : ""}`;
        reject(new Error(`Codex failed: ${detail}`));
        return;
      }
      if (!state.content) {
        reject(new Error("Codex completed without an agent message"));
        return;
      }
      resolve({ threadId: state.threadId, content: state.content });
    });
  });
}

function validateOptionalModel(value) {
  return value === undefined ? undefined : requireString(value, "model");
}

async function callTool(requestId, params) {
  const name = params?.name;
  const input = params?.arguments ?? {};
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new Error("tool arguments must be an object");
  }

  if (name === "codex") {
    const prompt = requireString(input.prompt, "prompt");
    const cwd = resolveDirectory(input.cwd);
    const sandbox = input.sandbox ?? "read-only";
    if (!["read-only", "workspace-write"].includes(sandbox)) {
      throw new Error("sandbox must be read-only or workspace-write");
    }
    if (input["approval-policy"] !== undefined && input["approval-policy"] !== "never") {
      throw new Error("approval-policy must be never for headless delegation");
    }
    const model = validateOptionalModel(input.model);
    const developerInstructions = input["developer-instructions"];
    if (developerInstructions !== undefined && typeof developerInstructions !== "string") {
      throw new Error("developer-instructions must be a string");
    }

    const args = ["-a", "never"];
    if (developerInstructions) {
      args.push("-c", `developer_instructions=${JSON.stringify(developerInstructions)}`);
    }
    args.push("exec", "--json", "--color", "never", "--skip-git-repo-check", "-s", sandbox, "-C", cwd);
    if (model) args.push("-m", model);
    args.push(prompt);
    return runCodex(requestId, args, cwd);
  }

  if (name === "codex-reply") {
    const threadId = requireString(input.threadId, "threadId");
    const prompt = requireString(input.prompt, "prompt");
    const model = validateOptionalModel(input.model);
    const args = ["-a", "never", "exec", "resume", "--json", "--skip-git-repo-check"];
    if (model) args.push("-m", model);
    args.push(threadId, prompt);
    return runCodex(requestId, args, process.cwd());
  }

  throw new Error(`unknown tool: ${String(name)}`);
}

async function handle(message) {
  const { id, method, params } = message;
  if (method === "notifications/initialized") return;
  if (method === "notifications/cancelled") {
    const child = running.get(JSON.stringify(params?.requestId));
    if (child) child.kill("SIGTERM");
    return;
  }
  if (method === "initialize") {
    response(id, {
      protocolVersion: typeof params?.protocolVersion === "string" ? params.protocolVersion : DEFAULT_PROTOCOL,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
    return;
  }
  if (method === "ping") {
    response(id, {});
    return;
  }
  if (method === "tools/list") {
    response(id, { tools });
    return;
  }
  if (method === "tools/call") {
    try {
      const result = await callTool(id, params);
      response(id, {
        content: [{ type: "text", text: result.content }],
        structuredContent: result,
      });
    } catch (error) {
      response(id, {
        content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
        isError: true,
      });
    }
    return;
  }
  if (id !== undefined) errorResponse(id, -32601, `method not found: ${String(method)}`);
}

const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    errorResponse(null, -32700, "parse error");
    return;
  }
  Promise.resolve(handle(message)).catch((error) => {
    if (message.id !== undefined) {
      errorResponse(message.id, -32603, error instanceof Error ? error.message : String(error));
    }
  });
});

function terminate(signal) {
  for (const child of running.values()) child.kill(signal);
  setTimeout(() => process.exit(0), 100).unref();
}

process.on("SIGINT", () => terminate("SIGINT"));
process.on("SIGTERM", () => terminate("SIGTERM"));
