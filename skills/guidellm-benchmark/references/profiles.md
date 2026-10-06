# GuideLLM Load Profiles Reference

GuideLLM provides several benchmark profiles for evaluating LLM inference servers. Each profile implements a distinct request scheduling strategy to characterize server behavior under different load conditions.

---

## 1. Synchronous Profile (`synchronous`)

### Purpose
Measures baseline sequential latency without request contention or queuing delay. Requests are dispatched one at a time: the next request is sent only after the previous response completes.

### CLI Syntax
```bash
--profile kind=synchronous
```

### When to Use
- Evaluating raw model generation speed (Time to First Token / TTFT and Inter-Token Latency / ITL).
- Testing single-user latency before applying concurrent load.

---

## 2. Throughput Profile (`throughput`)

### Purpose
Discovers the server's peak generation throughput by saturating parallel execution with multiple concurrent requests.

### CLI Syntax
```bash
--profile kind=throughput,max_concurrency=32,rampup_duration=10
```

### Parameters
- `max_concurrency`: Maximum number of parallel request streams (default or recommended: 16 to 64 depending on GPU capacity).
- `rampup_duration`: Seconds to linearly ramp up concurrency to prevent shock loads.

---

## 3. Concurrent Profile (`concurrent`)

### Purpose
Maintains a fixed number of simultaneous active streams. Whenever a stream's request finishes, a new request is immediately dispatched on that stream.

### CLI Syntax
```bash
# Single concurrency level
--profile kind=concurrent,streams=16,rampup_duration=10

# Multi-strategy concurrency evaluation
--profile '{"kind":"concurrent","streams":[1,2,4,8,16,32]}'
```

### When to Use
- Simulating fixed concurrent active user sessions (e.g. 8, 16, 32 users chatting concurrently).
- Measuring latency degradation as concurrent streams increase.

---

## 4. Constant Rate Profile (`constant` / `async`)

### Purpose
Sends requests at a fixed Poisson-free target rate (requests per second) regardless of server response times. Demonstrates queue buildup when arrival rate exceeds capacity.

### CLI Syntax
```bash
# Single rate
--profile kind=constant,rate=10,rampup_duration=10

# Multi-rate evaluation
--profile '{"kind":"constant","rate":[5,10,20]}'
```

### Parameters
- `rate`: Target requests per second (can be a list for stepped tests).
- `rampup_duration`: Time in seconds to ramp up to the target rate.
- `max_concurrency`: Maximum concurrent in-flight requests cap.

---

## 5. Poisson Profile (`poisson`)

### Purpose
Generates asynchronous request arrival times modeled by a Poisson distribution around target rate(s). This is the standard mathematical model for real-world user traffic where requests arrive independently at random intervals.

### CLI Syntax
```bash
--profile kind=poisson,rate=10 --seed kind=static,value=42
```

### Parameters
- `rate`: Target mean arrival rate (req/s).
- `--seed kind=static,value=<num>`: Ensures reproducible request intervals across runs.
- `max_concurrency`: Guard against runaway queues during temporary server slowdowns.

---

## 6. Sweep Profile (`sweep`)

### Purpose
The default, comprehensive benchmark in GuideLLM. It automatically runs an adaptive sequence:
1. Runs a `synchronous` strategy to establish the single-request baseline rate.
2. Runs a `throughput` strategy to discover peak throughput.
3. Automatically runs interpolated rate strategies between baseline and peak throughput.

### CLI Syntax
```bash
--profile kind=sweep,sweep_size=6,rampup_duration=10
```

### Parameters
- `sweep_size`: Total number of strategies in the sweep (including sync and peak throughput).
- `strategy_type`: Strategy used for interpolation (`constant` or `poisson`, default: `constant`).
- `rampup_duration`: Ramp-up time per strategy step.

---

## Common Constraints

Constraints govern when each strategy stops:

| Constraint | Syntax | Description |
|---|---|---|
| `max_duration` | `--constraint kind=max_duration,seconds=60` | Stop strategy after N elapsed seconds. |
| `max_requests` | `--constraint kind=max_requests,count=500` | Stop strategy after N requests are processed. |
| `over_saturation` | `--constraint kind=over_saturation,min_seconds=30` | Auto-abort if server latency explodes due to saturation. |

---

## Workload Token Sizing (Prompt vs Output)

Selecting realistic prompt and output token lengths is critical for representative benchmarking. The historical toy default of 256/128 tokens severely under-tests prefill attention mechanisms and KV cache allocation:

| Workload Preset | Prompt Tokens | Output Tokens | Rationale |
|---|---|---|---|
| **Standard / RAG (Default)** | **8,192** | **1,024** | Represents production RAG, document analysis, and coding agent prompts. Exercises chunked prefill, TTFT under load, and high KV-cache memory pressure. |
| **Conversational Chat** | **2,048** | **512** | Typical multi-turn user conversation with moderate context history. |
| **Reasoning / Chain-of-Thought** | **4,096** | **2,048** | Models with extended reasoning chains (o1/DeepSeek-R1 style) generating detailed output tokens. |
| **Smoke / Quick Test** | **256** | **128** | Lightweight sanity check for container networking and API connectivity. |

---

## Concurrency Sweep Methodology

What `scripts/guidellm_concurrency_sweep.sh` does beyond a single `concurrent` run, and why it is shaped that way.

### The matrix

- **Workloads × streams**: 4 token shapes (table above) × stream steps `1 4 8 16 32 64 128` → 28 runs. Streams go up to the serving `--max-num-seqs` (e.g. 128), so the top step probes genuine server admission rather than client-side throttling.
- **One config YAML per workload** (`guidellm_concurrent_<name>.yaml`) holds backend, tokenizer, data, window constraint and outputs; only `--profile kind=concurrent,streams=N` is overridden from the CLI per run. The tokenizer must be a real HF path mounted into the GuideLLM container (`-v <host-models>:/models:ro`) so synthetic token counts match the served tokenizer.

### Per-workload windows (not one global duration)

| Workload | Window | Why |
|---|---|---|
| quick_256_128 | 180 s | Tiny requests; even 128 streams drain fast |
| chat_2k_512 | 420 s | Moderate output × high streams needs room |
| reasoning_4k_2k | 600 s | 2048 output tokens dominate; few requests fit in a short window |
| 8k_1k | 600 s | Heavy prefill + queue growth; TTFT at 128 streams can exceed 4 minutes |

A uniform short window causes the real failure mode: requests still in flight
at cutoff become `incomplete`, and the latency stats of the survivors are
biased low ("survivorship"). The sweep's resume logic (skip only
`errored==0 && completion>=90%`) is what makes re-running with longer windows
cheap — finished short-window runs stay, incomplete-heavy ones get re-measured.

### Interpreting sweep outputs

- Falling `completion` at high streams marks the **saturation point**, not a regression; the guide used for the example sweep is "first median TTFT > 10 s".
- `errored > 0` in any row is a real incident (engine crash, transport error) — recover the server and re-run with `SWEEP_RUN_DIR` to replace just those rows.
- GPU telemetry (1 Hz; `mx-smi` on MetaX hosts, `nvidia-smi` fallback on NVIDIA hosts) runs for the whole sweep, so individual runs can be correlated by wall-clock placement of their directories' mtime window.

### Failure modes the orchestrator defends against

- **Root-owned `/results`** — the profile dir is `mkdir -p`'d and `chmod 777`'d before `docker run`. A missing bind-mount target is auto-created root-owned by Docker, and the non-root GuideLLM container (uid 1001) then dies with `PermissionError: /results/benchmarks.csv`.
- **Air-gapped tokenizer download** — the YAML sets `tokenizer: huggingface_auto` on the mounted model dir (`-v <host-models>:/models:ro`), so GuideLLM never reaches HuggingFace. Without it, output finalization fails with `httpx.ConnectError: [Errno 101] Network is unreachable` and `html`/`png` are lost (csv/json survive).
