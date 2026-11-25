# ADR-009 — LLM Provider, Models, and Agent Framework

| Field    | Value                                                                              |
|----------|------------------------------------------------------------------------------------|
| Status   | Draft                                                                              |
| Decider  | Saru                                                                               |
| Due      | Phase 0 (framework + provider chosen); API key with spending limit set before Phase 2 |
| PRD Ref  | Section 12 — "Provider and model tiers; framework (direct SDK vs LangGraph vs other); MCP library; local fallback model" |

---

## Context

The Agent service (Phase 2) needs four things decided before writing any agent code:

1. **LLM provider** — which company's API do you call? (Anthropic, OpenAI, Groq, etc.)
2. **Model tiers** — which model for the main agent loop, which for cheaper/faster calls?
3. **Agent framework** — do you call the LLM API directly, or use a framework that manages
   tool calling, retries, and multi-agent routing for you?
4. **Local fallback model** — what runs offline in CI or when the API is down?

These four decisions interact: some frameworks only support some providers. The MCP library
choice is also tied to the framework. All of this must be locked in before Phase 2 so the
eval harness (Section 7.4) is designed around a stable interface.

---

## Part 1 — LLM Provider

### Option 1A — Anthropic (Claude)

**Models available:**
- `claude-opus-5-5` — most capable, most expensive (~$15/M input tokens, ~$75/M output)
- `claude-sonnet-5-5` — balanced capability and cost (~$3/M input, ~$15/M output)
- `claude-haiku-5-5` — fast and cheap (~$0.80/M input, ~$4/M output)

**Pros:**
- Claude is built for tool use — the tool-calling API is well-designed and reliable
- MCP (Model Context Protocol) was created by Anthropic; the Python MCP SDK is first-party
  and works best with Claude
- Claude follows complex multi-step instructions reliably, important for the saga explanation
  in J8 (order-support agent)
- Strong safety and instruction-following for the guardrail requirements (AG-08)
- This project is built with Claude Code — familiarity with the same provider across
  the whole stack reduces cognitive overhead

**Cons:**
- More expensive per token than some alternatives for the top-tier model
- Requires Anthropic account; API key management via Anthropic Console

**Rough cost estimate (Phase 2–4, development only):**
- ~100 test conversations × ~2,000 tokens/conversation = ~200K tokens/month
- With Haiku for most calls: ~$0.16/month. With Sonnet: ~$0.60/month. Well within any budget.
- Load test (Phase 5): ~1,000 agent conversations — budget ~$5–$15 depending on model

---

### Option 1B — OpenAI (GPT-4o / GPT-4o-mini)

**Models available:**
- `gpt-4o` — high capability (~$2.50/M input, ~$10/M output)
- `gpt-4o-mini` — fast and cheap (~$0.15/M input, ~$0.60/M output)

**Pros:**
- Very large ecosystem — most tutorials, blog posts, and StackOverflow answers target OpenAI
- gpt-4o-mini is extremely cheap for the eval harness
- Good tool-calling support
- OpenAI Python SDK (`openai`) is well-maintained

**Cons:**
- MCP is an Anthropic standard — using it with OpenAI requires the `openai-mcp` adapter or
  a framework layer; not as seamless
- Some agent frameworks (LangGraph) are developed by LangChain which has closer OpenAI ties,
  but all major frameworks support both
- gpt-4o is cheaper than claude-sonnet-5-5 on output but the gap is not dramatic

**Rough cost estimate:** Similar to Anthropic at development volumes.

---

### Option 1C — Groq (Llama 3.1, Mixtral)

**Models available:**
- `llama-3.3-70b-versatile` — capable open-weight model, free tier available
- `llama-3.1-8b-instant` — very fast, very cheap

**Pros:**
- Groq has an extremely fast inference API (tokens per second is 10–100× OpenAI/Anthropic)
  — good for the first-token latency requirement (AG-01: ≤ 3 s p95)
- Free tier exists for development; cheap paid tier
- Open-weight models mean you can run the same model locally with Ollama

**Cons:**
- Tool calling support is less mature and reliable than Anthropic/OpenAI for complex schemas
- The MCP ecosystem targets Anthropic first; Groq support is community-maintained
- Llama models are less capable than Claude Sonnet or GPT-4o on complex reasoning tasks
  (order support explanation, admin catalog summarization)
- The eval harness results (AG-03) may require different thresholds to pass

**Rough cost estimate:** Cheapest option; almost free at development volumes.

---

### Option 1D — Multi-Provider (Primary + Fallback)

**What it is:** Use one provider as the primary (e.g. Anthropic Claude Sonnet) and configure
a fallback to a cheaper/faster model (e.g. Claude Haiku or Groq Llama) for simple tasks or
when the primary is slow.

**Pros:**
- Implements the AG-04 fallback requirement naturally
- Cost-optimises by routing simple queries to cheap models
- Resilient to provider outages

**Cons:**
- More complex agent code from day one
- Eval harness must test against all tiers
- Two API keys to manage, two spending limits to monitor

**Recommendation for learning:** Start with one provider, one model tier. Add multi-tier routing
in Phase 4 when you understand how the agent behaves. Keep it simple in Phase 2.

---

## Part 2 — Agent Framework

### Option 2A — Direct SDK (No Framework)

**What it is:** Call the LLM API directly using the provider's Python SDK. Manage the tool-calling
loop yourself.

**How it works:**
```python
# Pseudocode for a tool-calling loop
while steps < max_steps:
    response = anthropic.messages.create(model=..., tools=tools, messages=history)
    if response.stop_reason == "tool_use":
        results = run_tools(response.tool_calls)
        history.append(results)
    else:
        return response.content  # final answer
```

**Pros:**
- You understand every line of code — no "magic" from a framework
- Best learning outcome: you implement tool calling, grounding checks, max-step limits, and
  token budgets yourself, which is exactly what the PRD requires you to learn
- Zero framework dependency — if the provider changes their API slightly, you fix one file
- MCP server is separate from the agent loop; you can use the official `mcp` Python package
  to build the tool server without any framework

**Cons:**
- More boilerplate: you write the loop, the tool dispatcher, the history management,
  the streaming handler, and the error handling yourself
- Multi-agent routing (the optional Router agent in Phase 4) requires you to design the
  handoff protocol from scratch
- No built-in observability hooks — you add OTel spans yourself (but AG-09 requires this anyway)

**Complexity for a solo learner:** Medium. The loop is ~50–80 lines. It is one of the most
educational things you will write in this project. Strongly recommended for Phases 2–3.

---

### Option 2B — LangGraph (LangChain)

**What it is:** A graph-based agent framework where you define agent states as nodes and
transitions as edges. Built on top of LangChain.

**How it works:** You define a graph of "nodes" (functions that call the LLM or run tools)
and "edges" (conditions for transitioning between nodes). LangGraph manages the loop.

**Pros:**
- Built-in support for multi-agent routing (the Router agent in Phase 4 would be easy)
- Good streaming support
- Large community and many tutorials
- Human-in-the-loop is a supported first-class concept (checkpoints, interrupts)

**Cons:**
- LangChain is known for being over-abstracted — many layers of abstraction between your code
  and the actual LLM call, making debugging harder
- LangGraph adds a dependency on LangChain core which has a history of breaking changes
- For 3 simple agents (shopping, order support, admin), the graph model is overkill in Phase 2
- The grounding check (AG-03, every SKU/price must come from a tool result) requires you
  to write custom logic anyway — the framework does not do this for you
- MCP integration is via a LangChain adapter, not the native MCP SDK

**Complexity for a solo learner:** Medium initially (good tutorials), but the abstraction layer
makes debugging harder when something goes wrong. "Why did the agent call the wrong tool?" is
harder to answer when LangGraph manages the loop.

---

### Option 2C — PydanticAI

**What it is:** A newer, type-safe agent framework built by the Pydantic team. Uses Pydantic
models for tool inputs/outputs.

**How it works:** Agents are Python classes. Tools are decorated functions with Pydantic-typed
arguments. The framework manages the loop.

**Pros:**
- Type safety end-to-end: tool inputs and outputs are validated by Pydantic, which catches
  schema mismatches at development time
- Cleaner, less abstracted than LangChain
- Good MCP support via `pydantic-ai-mcp`
- Strongly integrates with the existing Python type annotation ecosystem

**Cons:**
- Newer project — less community material, fewer tutorials, potential for API changes
- Multi-provider support is good but not as battle-tested as LangChain
- Smaller community than LangGraph for multi-agent patterns

**Complexity for a solo learner:** Low-Medium. Cleaner than LangGraph. Worth watching.

---

### Option 2D — CrewAI

**What it is:** A multi-agent framework where you define "agents" with roles and "tasks" that
agents perform. Good for the admin catalog agent pattern (batch task + human approval).

**Pros:**
- Purpose-built for multi-agent collaboration — the Router agent pattern is natural
- Good for the admin catalog batch tasks (summarise 10 SKUs, propose descriptions)

**Cons:**
- Overkill for a shopping assistant (single-agent, single-turn is most of Phase 2)
- Adds another abstraction layer; debugging tool call failures is harder
- Less suited to the streaming requirement (AG-01) compared to direct SDK or LangGraph

**Complexity for a solo learner:** Medium. Best suited if multi-agent routing is a primary goal.

---

## Part 3 — Local Fallback Model

The PRD requires a fallback for when the LLM API is down or slow (AG-04). It also says:
"Local tests can swap in a recorded-response or small local model to avoid cost."

### Option 3A — Recorded Responses (Cassettes)

**What it is:** In tests and CI, play back pre-recorded LLM responses instead of calling
the real API. Like VCR cassettes for HTTP calls.

**How it works:** A test fixture records a real conversation once, saves the responses to a
JSON file, and replays them in future runs. The agent code does not know the difference.

**Pros:**
- Zero cost in CI — no API calls
- Deterministic tests (same response every time)
- Fast — no network round trip
- Simple to implement with `pytest-recording` or a custom fixture

**Cons:**
- Does not test the actual LLM behaviour — only the agent loop logic
- Recorded responses become stale when you change the prompt or tool schemas
- Does not test the fallback *to* a live model — just the replay mechanism

**Complexity for a solo learner:** Low. Recommended for the eval harness (Section 7.4) and CI.

---

### Option 3B — Ollama (Local LLM)

**What it is:** Run a small open-weight model (e.g. Llama 3.2 3B, Qwen 2.5 7B) locally via
Ollama. The agent code uses the same OpenAI-compatible API; only the base URL changes.

**How it works:**
```
Agent code → openai.Client(base_url="http://localhost:11434/v1") → Ollama → local model
```

**Pros:**
- Tests the full LLM loop without spending money
- Tests the actual fallback path (AG-04) — if the production provider is replaced with
  the local model, the agent should degrade gracefully
- No API key needed for CI
- Good for offline development

**Cons:**
- Requires ~4–8 GB of RAM/VRAM for a useful model
- Small local models (3B–7B) are noticeably less capable than Claude Sonnet or GPT-4o
  — tool calling success rates are lower
- Ollama must be running as a separate process (not easily containerised in Compose for all platforms)
- Adds a Compose or setup step for every developer

**Complexity for a solo learner:** Medium. Good to have for the fallback chaos test in Phase 5
(AG-04: "chaos test with LLM endpoint blocked"). Not needed from Phase 0.

---

### Option 3C — Groq Free Tier as CI Fallback

**What it is:** Use Groq's free tier (rate-limited) in CI instead of the primary provider.
Groq supports Llama models which are fast and cheap.

**Pros:**
- Real LLM calls in CI, not recorded responses
- Fast (Groq inference speed is very high)
- Free tier covers low-volume CI

**Cons:**
- Rate limits on the free tier — parallel CI jobs may hit limits
- Different model than production — eval results may not be comparable
- Requires a separate Groq API key in CI secrets

---

## Comparison Table

| Criterion                      | Anthropic | OpenAI | Groq | Direct SDK | LangGraph | PydanticAI | Recorded | Ollama |
|--------------------------------|-----------|--------|------|------------|-----------|------------|----------|--------|
| MCP integration quality        | Native    | Adapter | Adapter | Native | Adapter | Good | N/A | N/A |
| Tool-calling reliability       | High      | High   | Medium | — | — | — | — | Low-Medium |
| Learning value (agent loop)    | —         | —      | —    | Highest    | Low       | Medium     | — | — |
| Multi-agent routing ease       | —         | —      | —    | Manual     | Easy      | Medium     | — | — |
| Debug transparency             | —         | —      | —    | High       | Low       | Medium     | — | — |
| Dev cost (100 convos/month)    | ~$0.60    | ~$0.30 | ~$0  | — | — | — | $0 | $0 |
| Load test cost (1,000 convos)  | ~$5–15    | ~$3–10 | ~$1  | — | — | — | $0 | $0 |
| CI determinism                 | —         | —      | —    | — | — | — | Perfect | Low |

---

## Questions to Help You Decide

**On provider:**
1. Do you already have an Anthropic API key, or would you need to sign up? Same for OpenAI.
   The practical answer might be "whichever account I already have".
2. Is MCP a technology you specifically want to learn deeply? If yes, Anthropic is the natural
   choice since they created it. If MCP is just a means to an end, OpenAI works fine too.
3. How important is cost sensitivity? At development volumes (100–200 test conversations)
   all three providers are under $2/month. At load-test volumes the difference is ~$10. Is
   that a meaningful constraint for you?

**On framework:**
4. Is building the agent loop from scratch interesting to you, or do you want to focus on the
   higher-level patterns (tool design, evaluation, guardrails)? If the former, Option 2A is
   better. If the latter, Option 2B or 2C lets you skip the boilerplate.
5. Have you used LangChain/LangGraph before? If yes and you found it frustrating, Option 2A
   or 2C is a better experience. If you have no prior exposure, Option 2A's directness is
   the safest starting point for a learning project.
6. How important is the Router/multi-agent pattern to you? If you plan to implement the optional
   Router agent (Phase 4), LangGraph or CrewAI make that easier. If you will stick to 3 direct
   agents, the direct SDK is simpler.

**On fallback:**
7. Do you have a machine with enough RAM (8+ GB free) to run Ollama locally? If yes, it is
   worth having for the Phase 5 chaos test. If not, recorded responses in CI are sufficient.
8. Will CI run against the real LLM API (and consume budget), or do you want zero-cost CI?
   This determines whether recorded responses or a free-tier fallback is the right choice.

---

## Decision: [TBD]

**Provider:** …

**Primary model:** …

**Cheap/fast model (for simple tasks or eval):** …

**Agent framework:** …

**CI / local fallback strategy:** …

**Monthly API spending limit on the key:** $…

**Rationale:** …

---

## Consequences

*To be filled in after the decision.*
