import { getState, setState } from "./db";
import { isRecord, json } from "./http";
import { gatherLive, readFix, spokenAnswer } from "./live-answer";
import type { Env } from "./types";
import { GEMINI_MODEL, GEMINI_URL, GROQ_MODEL, GROQ_URL, LIMITS } from "./types";

export const CHAT_FALLBACK = "I'm here, sir. I couldn't reach my notes just now. Ask me again in a moment.";

export interface ToolCall {
  id: string;
  type: "function";
  function: {
    name: string;
    arguments: string;
  };
}

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  name?: string;
}

export interface LlmTool {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
}

export interface LlmSuccess {
  ok: true;
  provider: "gemini" | "groq";
  model: string;
  message: ChatMessage;
}

export interface LlmFailure {
  ok: false;
  code: "rate_limited" | "not_configured" | "upstream" | "timeout";
  message: string;
  status?: number;
}

const COOLDOWN_KEY = "gemini_cooldown_until";

export async function completeChat(
  env: Env,
  messages: ChatMessage[],
  tools: LlmTool[] | null,
  options?: { timeoutMs?: number; maxTokens?: number; budgetMs?: number },
): Promise<LlmSuccess | LlmFailure> {
  const started = Date.now();
  const allowance = (): number => {
    const cap = options?.timeoutMs ?? LIMITS.llmTimeoutMs;
    if (!options?.budgetMs) return cap;
    return Math.min(cap, options.budgetMs - (Date.now() - started));
  };
  const cooldownRaw = await getState(env, COOLDOWN_KEY);
  const cooldownUntil = cooldownRaw ? Date.parse(cooldownRaw) : 0;
  const geminiCooling = Number.isFinite(cooldownUntil) && cooldownUntil > Date.now();

  if (env.GEMINI_API_KEY && !geminiCooling) {
    const geminiWait = allowance();
    if (geminiWait < 200) {
      return { ok: false, code: "timeout", message: "The reply missed the latency budget." };
    }
    const gemini = await callProvider("gemini", GEMINI_URL, env.GEMINI_API_KEY, GEMINI_MODEL, messages, tools, geminiWait, options?.maxTokens);
    if (gemini.ok) return gemini;
    if (gemini.code === "rate_limited") {
      await setState(env, COOLDOWN_KEY, new Date(Date.now() + LIMITS.rateLimitCooldownMs).toISOString());
    }
    if (!env.GROQ_API_KEY) return gemini;
    const groqWait = allowance();
    if (groqWait < 200) return gemini;
    const groq = await callProvider("groq", GROQ_URL, env.GROQ_API_KEY, GROQ_MODEL, messages, tools, groqWait, options?.maxTokens);
    if (groq.ok) return groq;
    if (gemini.code === "rate_limited" && groq.code === "rate_limited") {
      return {
        ok: false,
        code: "rate_limited",
        message: "Gemini returned 429 and Groq is also rate limited. The step will resume on a later tick.",
        status: 429,
      };
    }
    return {
      ok: false,
      code: gemini.code === "rate_limited" ? groq.code : gemini.code,
      message: `Gemini failed: ${gemini.message} Groq fallback failed: ${groq.message}`,
      status: groq.status ?? gemini.status,
    };
  }

  if (env.GROQ_API_KEY) {
    const groqWait = allowance();
    if (groqWait < 200) return { ok: false, code: "timeout", message: "The reply missed the latency budget." };
    const groq = await callProvider("groq", GROQ_URL, env.GROQ_API_KEY, GROQ_MODEL, messages, tools, groqWait, options?.maxTokens);
    if (!groq.ok && geminiCooling) {
      return {
        ...groq,
        message: `Gemini is cooling down until ${new Date(cooldownUntil).toISOString()}. ${groq.message}`,
      };
    }
    return groq;
  }

  if (env.GEMINI_API_KEY && geminiCooling) {
    return {
      ok: false,
      code: "rate_limited",
      message: `Gemini is cooling down until ${new Date(cooldownUntil).toISOString()} after a 429, and GROQ_API_KEY is not set.`,
    };
  }

  return {
    ok: false,
    code: "not_configured",
    message: "No LLM key is configured. Set the Worker secret GEMINI_API_KEY or GROQ_API_KEY.",
  };
}

export async function chatResponse(request: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, reply: CHAT_FALLBACK, provider: null });
  }
  if (!isRecord(body) || !Array.isArray(body.messages)) {
    return json({ ok: false, reply: CHAT_FALLBACK, provider: null });
  }
  const messages: ChatMessage[] = [];
  for (const item of body.messages) {
    if (!isRecord(item)) continue;
    const role = item.role;
    if (role !== "system" && role !== "user" && role !== "assistant") continue;
    const content = typeof item.content === "string" ? item.content.trim().slice(0, 4000) : "";
    if (!content) continue;
    messages.push({ role, content });
    if (messages.length >= 20) break;
  }
  if (!messages.some((message) => message.role === "user")) {
    return json({ ok: false, reply: CHAT_FALLBACK, provider: null });
  }
  const question = [...messages].reverse().find((message) => message.role === "user")?.content ?? "";
  const live = await gatherLive(env, question, readFix(body.location));
  if (live?.reply) {
    return json({ ok: true, reply: live.reply, provider: "gemini" });
  }
  let chatMessages = messages;
  if (live?.notes) {
    chatMessages = [
      {
        role: "system",
        content:
          "Use these notes to answer in one or two spoken sentences. Give the fact. Do not say you will search. Do not mention links or URLs.\n" +
          live.notes,
      },
      ...messages,
    ];
  }
  const result = await completeChat(env, chatMessages, null);
  if (!result.ok) {
    console.error("chat failed", result.code);
    return json({ ok: false, reply: CHAT_FALLBACK, provider: null });
  }
  const reply = spokenAnswer(result.message.content ?? "");
  if (!reply) {
    console.error("chat returned an empty reply", result.provider);
    return json({ ok: false, reply: CHAT_FALLBACK, provider: result.provider });
  }
  return json({ ok: true, reply, provider: result.provider });
}

async function callProvider(
  provider: "gemini" | "groq",
  url: string,
  apiKey: string,
  model: string,
  messages: ChatMessage[],
  tools: LlmTool[] | null,
  timeoutMs: number = LIMITS.llmTimeoutMs,
  maxTokens: number = 2048,
): Promise<LlmSuccess | LlmFailure> {
  const body: Record<string, unknown> = {
    model,
    messages: messages.map(toWireMessage),
    temperature: 0.2,
    max_tokens: maxTokens,
  };
  if (tools && tools.length > 0) body.tools = provider === "gemini" ? geminiTools(tools) : tools;
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await response.text();
    const rateLimited =
      response.status === 429 ||
      response.status === 500 ||
      response.status === 502 ||
      response.status === 503 ||
      response.status === 504 ||
      (response.status >= 400 && /RESOURCE_EXHAUSTED|rate_limit_exceeded|rate limit|overloaded|UNAVAILABLE/i.test(text));
    if (rateLimited) {
      return {
        ok: false,
        code: "rate_limited",
        message: `${provider} is busy (HTTP ${response.status}).`,
        status: response.status,
      };
    }
    if (!response.ok) {
      return {
        ok: false,
        code: "upstream",
        message: `${provider} could not answer (HTTP ${response.status}): ${providerError(text)}`,
        status: response.status,
      };
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(text) as unknown;
    } catch {
      return { ok: false, code: "upstream", message: `${provider} returned a body that was not JSON.` };
    }
    const message = readAssistantMessage(parsed);
    if (!message) return { ok: false, code: "upstream", message: `${provider} returned no assistant message.` };
    return { ok: true, provider, model, message };
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    const timedOut = name === "TimeoutError" || name === "AbortError";
    return {
      ok: false,
      code: timedOut ? "timeout" : "upstream",
      message: `${provider} request failed: ${err instanceof Error ? err.message : "unknown error"}`,
    };
  }
}

/** Gemini's OpenAI endpoint rejects additionalProperties inside tool schemas. */
export function geminiTools(tools: LlmTool[]): LlmTool[] {
  return tools.map((tool) => ({
    type: "function",
    function: {
      name: tool.function.name,
      description: tool.function.description,
      parameters: geminiSchema(tool.function.parameters) as Record<string, unknown>,
    },
  }));
}

function geminiSchema(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((item) => geminiSchema(item));
  if (!value || typeof value !== "object") return value;
  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (key === "additionalProperties" || key === "$schema" || key === "strict") continue;
    out[key] = geminiSchema(item);
  }
  if (out.type === "object" && (out.properties == null || typeof out.properties !== "object")) out.properties = {};
  return out;
}

export interface SmsProbe {
  legacy_gemini: string;
  legacy_groq: string;
  chat_ok: boolean;
  chat_code: string;
  chat_error: string;
}

/** One raw tool call, with additionalProperties left in, plus the path SMS chat now uses. */
export async function probeSmsChat(env: Env, tools: LlmTool[]): Promise<SmsProbe> {
  const messages: ChatMessage[] = [
    { role: "system", content: "Reply in one short sentence." },
    { role: "user", content: "Say hello in five words." },
  ];
  const [legacyGemini, legacyGroq] = await Promise.all([
    legacyToolPost(env, "gemini", GEMINI_URL, env.GEMINI_API_KEY, GEMINI_MODEL, messages, tools),
    legacyToolPost(env, "groq", GROQ_URL, env.GROQ_API_KEY, GROQ_MODEL, messages, tools),
  ]);
  const chat = await completeChat(env, messages, tools, { timeoutMs: 8_000, maxTokens: 40 });
  return {
    legacy_gemini: legacyGemini,
    legacy_groq: legacyGroq,
    chat_ok: chat.ok,
    chat_code: chat.ok ? "ok" : chat.code,
    chat_error: chat.ok ? "" : providerError(chat.message),
  };
}

async function legacyToolPost(
  env: Env,
  provider: string,
  url: string,
  apiKey: string | undefined,
  model: string,
  messages: ChatMessage[],
  tools: LlmTool[],
): Promise<string> {
  void env;
  const key = (apiKey ?? "").trim();
  if (!key) return "not_configured";
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({
        model,
        messages: messages.map(toWireMessage),
        temperature: 0.2,
        max_tokens: 40,
        tools,
      }),
      signal: AbortSignal.timeout(8_000),
    });
    const text = await response.text();
    if (response.ok) return `ok ${response.status}`;
    return `${provider} HTTP ${response.status}: ${providerError(text)}`;
  } catch (err) {
    return `${provider} request failed: ${providerError(err instanceof Error ? err.message : "unknown error")}`;
  }
}

function providerError(text: string): string {
  const clean = text
    .replace(/Bearer\s+\S+/gi, "Bearer [redacted]")
    .replace(/[A-Za-z0-9+/=_-]{24,}/g, "[redacted]")
    .replace(/\+\d[\d\s().-]{6,}/g, "[number]")
    .replace(/\s+/g, " ")
    .trim();
  return clean.slice(0, 280);
}

function toWireMessage(message: ChatMessage): Record<string, unknown> {
  const wire: Record<string, unknown> = {
    role: message.role,
    content: message.content,
  };
  if (message.tool_calls?.length) wire.tool_calls = message.tool_calls;
  if (message.tool_call_id) wire.tool_call_id = message.tool_call_id;
  if (message.name) wire.name = message.name;
  return wire;
}

function readAssistantMessage(payload: unknown): ChatMessage | null {
  if (!payload || typeof payload !== "object") return null;
  const choices = (payload as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || !choices[0] || typeof choices[0] !== "object") return null;
  const message = (choices[0] as { message?: unknown }).message;
  if (!message || typeof message !== "object") return null;
  const record = message as { content?: unknown; tool_calls?: unknown };
  const content = typeof record.content === "string" ? record.content : null;
  const toolCalls = normalizeToolCalls(record.tool_calls);
  if (!content && toolCalls.length === 0) return null;
  return {
    role: "assistant",
    content,
    tool_calls: toolCalls.length ? toolCalls : undefined,
  };
}

function normalizeToolCalls(value: unknown): ToolCall[] {
  if (!Array.isArray(value)) return [];
  const calls: ToolCall[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") continue;
    const record = item as { id?: unknown; function?: unknown };
    const fn = record.function;
    if (!fn || typeof fn !== "object") continue;
    const name = (fn as { name?: unknown }).name;
    if (typeof name !== "string" || !name) continue;
    const args = (fn as { arguments?: unknown }).arguments;
    calls.push({
      id: typeof record.id === "string" && record.id ? record.id : `call_${calls.length}`,
      type: "function",
      function: {
        name,
        arguments: typeof args === "string" ? args : JSON.stringify(args ?? {}),
      },
    });
  }
  return calls;
}
