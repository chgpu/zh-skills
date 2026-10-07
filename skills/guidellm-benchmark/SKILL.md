---
description: Benchmark LLM inference endpoints (vLLM, SGLang, etc.) with GuideLLM using docker or nerdctl containers and image ghcr.io/vllm-project/guidellm:latest. Two bundled orchestrators — a concurrency sweep (4 workload shapes x streams 1..256 with per-workload windows, resumable re-runs, and host GPU telemetry — mx-smi or nvidia-smi, auto-detected) and an all-profile runner (synchronous, throughput, concurrent, constant, poisson, sweep). Every run also captures model identity and how the serving container was launched (full inspect plus mounts/devices/ports/env/ulimits/server-args and model-dir listing) into a timestamped folder with csv, json, html, png artifacts and a REPORT.md of links — raw metrics are never loaded into context. Use this skill whenever the user mentions GuideLLM or guidellm, load/throughput benchmarks, latency (TTFT/TPOT) measurements, concurrency sweeps, tok/s vs streams, capacity or saturation testing of an OpenAI-compatible server, GPU telemetry during benchmarks — even if GuideLLM is not named explicitly.
license: MIT
name: guidellm-benchmark
---
# guidellm-benchmark

Run comprehensive load and performance benchmarks against OpenAI-compatible LLM servers (e.g. vLLM, SGLang) using GuideLLM containerized via `docker` or `nerdctl`, and record not only measurements but also **which model exactly** was served and **how the serving container was launched** — benchmark numbers are meaningless a week later without the server args (quantization, `max-num-seqs`, prefix caching, context length...) that produced them.

## Overview

- **GuideLLM Image**: `ghcr.io/vllm-project/guidellm:latest`
- **Runtimes**: `docker` or `nerdctl` (both supported by both orchestrator scripts; serving-container inspect automatically falls back to the other runtime)
- **Network Mode**: `--network host` (GuideLLM reaches localhost endpoints directly)
- **Bundled orchestrators**:
  - `scripts/guidellm_concurrency_sweep.sh` — capacity/saturation study: 4 workload shapes × stream sweep (1..256), per-workload time windows, GPU telemetry for the whole run (`mx-smi`, or `nvidia-smi` fallback on NVIDIA hosts, or `TELEMETRY_CMD`), resumable re-runs, ETA banner
  - `scripts/sweep_summary.py` — turns a finished run dir's `benchmarks.json` files into the curated aggregate table + headlines that get appended to `REPORT.md`
  - `scripts/run_benchmarks.sh` — full load-profile matrix (all 6 GuideLLM profiles), workload token presets, `--dry-run`
- **Artifacts**: `csv`, `json`, `html`, `png` per run + `REPORT.md` index of relative links
- **Output folders** (created in the current working directory): `guidellm_run_YYYYMMDD_HHMMSS/` (all-profile runner) or `guidellm_sweep_YYYYMMDD_HHMMSS/` (concurrency sweep)
- **Metadata captured with every run**: `model_info.json` (endpoint `/v1/models`), `serving_launch_info.txt` (human-readable inspect: image, entrypoint, server args, mounts, devices, ports, env, groups, security opts, ulimits, caps, model-dir listing), `serving_container_inspect.json` (full dump)
- **Context protection**: `REPORT.md` holds environment/launch metadata and relative links; raw benchmark rows and per-request distributions stay in the artifact files and are never dumped into chat.

---

## Quick Start

### Option A — Concurrency sweep (capacity & saturation)

Reproduces the full streams×workload matrix in one command (defaults match the production layout: serving container `vllm-qwen38-27b-w8a8`, endpoint `http://localhost:8000`, models/configs/telemetry dirs under the metax-vllm repo):

```bash
# Fresh sweep (GuideLLM via docker)
bash .agents/skills/guidellm-benchmark/scripts/guidellm_concurrency_sweep.sh

# GuideLLM via nerdctl instead (inspect of the serving container auto-falls-back)
RUNTIME=nerdctl bash .agents/skills/guidellm-benchmark/scripts/guidellm_concurrency_sweep.sh

# Resume/interrupt-safe re-run: skips profiles that already finished with
# 0 errors and >=90% completion, re-measures everything else
SWEEP_RUN_DIR=./guidellm_sweep_20260924_223015 \
  bash .agents/skills/guidellm-benchmark/scripts/guidellm_concurrency_sweep.sh

# Different target / narrower stream grid
SERVING_CONTAINER=<other-name> ENDPOINT=http://localhost:8011 \
  HOST_MODELS_DIR=/path/to/models SWEEP_STREAMS="1 4 16 64" \
  bash .agents/skills/guidellm-benchmark/scripts/guidellm_concurrency_sweep.sh

# Long non-interactive run: survive terminal/session teardown (a previous
# run was killed by SIGHUP when the launching shell exited)
setsid bash .agents/skills/guidellm-benchmark/scripts/guidellm_concurrency_sweep.sh \
  </dev/null >sweep.log 2>&1 &
```

Sweep matrix: workloads `8k_1k` (8192→1024) · `chat_2k_512` (2048→512) · `reasoning_4k_2k` (4096→2048) · `quick_256_128` (256→128) × streams `1 4 8 16 32 64 128 192 256` (= 36 runs), with windows **180 s (quick) / 420 s (chat) / 600 s (reasoning, 8k)**. The 192/256 steps extend past the old 1..128 grid to find the true TTFT knee; with vLLM's default `max_num_seqs=128` (SchedulerConfig.DEFAULT_MAX_NUM_SEQS) they exceed the admission cap and queue — the saturation signal we are measuring. Results land in `guidellm_sweep_*/profiles/<workload>_stream_<N>/`.

### Option B — All load profiles

```bash
# Full profile matrix against a local server
bash .agents/skills/guidellm-benchmark/scripts/run_benchmarks.sh \
  --endpoint http://localhost:8000 \
  --container <serving_container_name_or_id> \
  --runtime docker \
  --models-dir "$PWD/models" \
  --duration 60

# Workload token presets:
#   8k-1k (default: RAG/Agentic 8192 -> 1024)   chat (2048 -> 512)
#   reasoning (4096 -> 2048)                    quick (256 -> 128)
bash .agents/skills/guidellm-benchmark/scripts/run_benchmarks.sh --preset chat

# Preview every command without executing anything
bash .agents/skills/guidellm-benchmark/scripts/run_benchmarks.sh --dry-run
```

### Workload presets

| Preset | Prompt Tokens | Output Tokens | Use Case |
|---|---|---|---|
| `8k-1k` *(default)* | 8,192 | 1,024 | Standard RAG, document Q&A, agentic workflows — heavy prefill, KV pressure |
| `chat` | 2,048 | 512 | Conversational chat with short history |
| `reasoning` | 4,096 | 2,048 | Long-form thinking / reasoning models |
| `quick` | 256 | 128 | Smoke testing container and network connectivity |

Window sizing rule for sweeps: the heavier the workload and the higher the streams, the longer the window must be — if most requests are still in flight at cutoff they count as `incomplete` and the surviving samples bias the latency stats. The defaults above (180/420/600 s) came from exactly that failure at a uniform 180 s.

---

## Choosing the container runtime (docker vs nerdctl)

- Both orchestrators invoke GuideLLM as `$RUNTIME run --rm --network host -v <results>:/results:rw ...`; docker and nerdctl accept the same flags here.
- `run_benchmarks.sh` auto-detects (`nerdctl` if on PATH, else `docker`), `--runtime` / `RUNTIME=` overrides; the sweep script defaults to `docker`.
- **The serving container is independent**: it may run under the other runtime than the one you pick for GuideLLM. Both scripts therefore probe the chosen runtime first and fall back to the other for the serving-container inspect — one of them will see the container as long as it is running.
- Ensure the chosen runtime can pull/run `ghcr.io/vllm-project/guidellm:latest` (image presence is per-runtime).

---

## What gets captured alongside the measurements

Right after the run directory is created (before any benchmark), and **before** the long sweep starts, both scripts save:

| File | Content |
|---|---|
| `model_info.json` | `GET /v1/models` — the model id the endpoint actually serves |
| `serving_launch_info.txt` | `IMAGE`, `ENTRYPOINT`, `CMD` (full server args), `MOUNTS`, `DEVICES`, `PORTS`, `ENV`, `GROUP_ADD`, `SECURITY_OPT`, `ULIMITS`, `CAP_ADD`, then `=== MODEL CHECK ===` listing the host model dir (weights/tokenizer source) |
| `serving_container_inspect.json` | Verbatim full output of `<runtime> inspect <container>` — the ground truth if the template misses a field |
| `REPORT.md` | Environment summary (model id, image, server args, durations, runtime) + relative links to metadata, artifacts and telemetry — never raw metric dumps |
| `metrics.csv` | (sweep only) 1 Hz GPU telemetry (source: `mx-smi` on MetaX hosts, `nvidia-smi` fallback on NVIDIA hosts): timestamp, utilization, memory, temperature, power — written into the run dir next to `REPORT.md` |

Capturing launch info up-front matters for two reasons: a sweep can die hours in (took down a prior run via SIGHUP), and identical model weights served with different `max-num-seqs` / `--no-enable-prefix-caching` / quant flags produce completely different curves. The launch template is defined verbatim in `references/report-template.md`.

---

## Manual execution workflow

If you need a single ad-hoc run instead of the orchestrators:

### 1. Timestamped run directory + metadata

```bash
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RUN_DIR="guidellm_run_${TIMESTAMP}"
mkdir -p "${RUN_DIR}/profiles"
curl -s http://localhost:8000/v1/models > "${RUN_DIR}/model_info.json"
docker inspect <serving_container> --format '<launch template>' \
  > "${RUN_DIR}/serving_launch_info.txt"   # template: references/report-template.md
docker inspect <serving_container> > "${RUN_DIR}/serving_container_inspect.json"
```

### 2. Run GuideLLM once per profile

The image entrypoint is `guidellm`, so the container command **must** start with `run`. Pre-create the profile dir world-writable (Docker would otherwise auto-create it root-owned → `PermissionError`), and mount the model dir as the offline tokenizer source (avoids the HuggingFace download that fails with Errno 101 on air-gapped hosts):

```bash
mkdir -p "$(pwd)/${RUN_DIR}/profiles/concurrent" && chmod 777 "$(pwd)/${RUN_DIR}/profiles/concurrent"
docker run --rm --network host \
  -v "$(pwd)/${RUN_DIR}/profiles/concurrent:/results:rw" \
  -v "$MODELS:/models:ro" \
  ghcr.io/vllm-project/guidellm:latest \
  run \
  --backend kind=openai_http,target=http://localhost:8000 \
  --data kind=synthetic_text,prompt_tokens=8192,output_tokens=1024 \
  --constraint kind=max_duration,seconds=600 \
  --profile kind=concurrent,streams=16,rampup_duration=10 \
  --tokenizer '{"kind":"huggingface_auto","model":"/models","load_kwargs":{"trust_remote_code":true}}' \
  --output kind=csv,path=/results/benchmarks.csv \
  --output kind=json,path=/results/benchmarks.json \
  --output kind=html,path=/results/benchmarks.html \
  --output kind=plot,path=/results/benchmarks.png
```

Profile flags (swap the `--profile` line, everything else stays):

| Profile | `--profile` argument |
|---|---|
| synchronous | `kind=synchronous` |
| throughput | `kind=throughput,max_concurrency=32,rampup_duration=10` |
| concurrent | `kind=concurrent,streams=16,rampup_duration=10` |
| constant | `kind=constant,rate=10,rampup_duration=10` |
| poisson | `kind=poisson,rate=10` + `--seed kind=static,value=42` |
| sweep | `kind=sweep,sweep_size=6,rampup_duration=10` |

**Config-file mode** (what the sweep script uses): put backend/data/constraints/outputs in a YAML, mount the tokenizer/weights dir read-only, override only the profile per run:

```bash
docker run --rm --network host \
  -v "$MODELS:/models:ro" -v "$CFG.yaml:/tmp/w.yaml:ro" \
  -v "$PROFILE_DIR:/results:rw" \
  ghcr.io/vllm-project/guidellm:latest \
  run --config /tmp/w.yaml --profile kind=concurrent,streams=64
```

### 3. Generate `REPORT.md`

Follow [references/report-template.md](references/report-template.md): header + server args + launch-metadata links + artifact link table + how-to-read notes. Do not inline raw measurement tables generated from CSV/JSON dumps; a small hand-curated aggregate summary (peak/saturation per workload) is fine.

---

## Reading a sweep's results

Parse `benchmarks.json` per profile (keys: `metrics.request_totals`, `requests_per_second`, `time_to_first_token_ms`, `time_per_output_token_ms`, `output_tokens_per_second`) — not by dumping JSON into chat. For the run-level aggregate table, **do not hand-transcribe numbers** (a hand-typed table drifted from the JSON in a real sweep): generate it and append its output to `REPORT.md`:

```bash
python3 scripts/sweep_summary.py <guidellm_sweep_YYYYMMDD_HHMMSS>
```

- **Three counters**: `successful` / `errored` / `incomplete` (from `request_totals`). `request_totals` also carries a `total` key (and more) — compute completion as `successful / (successful + errored + incomplete)`, never `successful / sum(dict.values())`.
  - `completion = successful / total`. Requests still in flight at the window cutoff are `incomplete` — at high streams a falling completion rate is the signature of **oversaturation**, a measurement of where the queue stops draining, *not* a failure. A healthy sweep has `errored = 0` everywhere.
  - Re-run mode uses exactly this: `errored == 0 && completion >= 0.90` → profile is "already good" and skipped.
- **Saturation point** = first stream step where median TTFT jumps past ~10 s (pre-queued requests dominate).
- **Single-stream rows** baseline decode: median TPOT ≈ per-token latency; output tok/s ≈ `output_tokens / TPOT`.
- **GPU correlation**: overlay `metrics.csv` (1 Hz, in the run dir) on the timeline of a run to see utilization/memory/power at saturation.
- Worked example with full tables — peaks, saturation points, per-run rows and the incidents log of the `guidellm_sweep_20260924_223015` run (Qwen3.8-27B-W8A8, 28 runs, 0 errors): [references/example-sweep-qwen38-27b.md](references/example-sweep-qwen38-27b.md).

---

## Reporting rule (protect the context)

When reporting to the user: summary of environment + paths to `REPORT.md` + at most a few headline numbers (peak tok/s, saturation streams). Never paste CSV rows, full `benchmarks.json`, or per-request latency distributions into chat or the report — link them instead. Compact curated aggregate tables (like the example reference) are the only acceptable exception, and they belong appended to `REPORT.md`, not sent as chat walls of numbers.

---

## Operational gotchas

1. **Container subcommand**: always `run` before any GuideLLM flags — the entrypoint is `/opt/app-root/bin/guidellm`; bare flags replace the command and fail to parse.
2. **Network**: always `--network host`, otherwise `localhost:8000` inside the container is not the host server.
3. **Outputs**: repeat `--output kind=csv|json|html|plot,path=/results/...` (plot → PNG) and mount the profile dir `:rw`.
4. **Long sweeps die with the terminal**: launch with `setsid ... </dev/null >log 2>&1 &` (SIGHUP hit a previous run and killed the orchestrator silently).
5. **Resume, don't restart**: `SWEEP_RUN_DIR=<existing dir>` re-runs only failed/incomplete profiles — healthy 36-run sweeps re-check in seconds.
6. **The server can die mid-sweep** (engine crash, GPU driver wedging — e.g. MetaX ringbuf exhaustion leaves a zombie worker when the container has no `--init`). The orchestrator only probes `/v1/models` between runs; it will not resurrect the container. Recovery: fix/recreate the serving container (prefer `--init` so workers get reaped), then resume with `SWEEP_RUN_DIR`. Record what happened as an incident note appended to `REPORT.md`.
7. **GPU telemetry is auto-selected**: `TELEMETRY_CMD` override (a space-separated command that gets the CSV path as its last arg) → `mx-smi` (MetaX; `-t` cannot be combined with `-o file`, so the script polls with `-l 1000`) → `nvidia-smi` (`--query-gpu=timestamp,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv -l 1`) → disabled. Never run two collectors: a second writer duplicates 1-Hz rows in `metrics.csv` (dedupe by the time column if it happened). At the end the script kills by PID **and** by command pattern — a PID captured at start can be stale (PID reuse) and a manually-started collector would otherwise keep writing after the sweep ends.
8. **YAML configs are regenerated** at every sweep invocation (stale `guidellm_concurrent_*.yaml` cleaned first) — edits to them do not survive a re-run; change `YAML_MAP`/`DURATION_MAP` in the script instead.
9. **GuideLLM needs no GPU**: weights are mounted `:ro`, the profile dir `:rw` — nothing else. It only talks HTTP to the endpoint, so no `/dev/*` or `shm_size` tuning applies to the benchmark container (those matter only for the serving side, see repo compose files for MetaX).
10. **`/results` must be pre-created and world-writable** — both scripts `mkdir -p` the profile dir and `chmod 777` it before `docker run`. If the bind-mount target is missing at run time, Docker auto-creates it **root-owned** and the non-root GuideLLM container (uid 1001) dies with `PermissionError: /results/benchmarks.csv`.
11. **Offline tokenizer (air-gapped hosts)** — GuideLLM loads its tokenizer from HuggingFace unless told otherwise; with no external network that download fails during output finalization with `httpx.ConnectError: [Errno 101] Network is unreachable`, so `csv`/`json` land but `html`/`png` are lost. Both scripts avoid it: the sweep mounts `HOST_MODELS_DIR` and sets `tokenizer: huggingface_auto` in the YAML; `run_benchmarks.sh` mounts `--models-dir` (auto-detected from the serving container's model arg when omitted) and passes `--tokenizer '{"kind":"huggingface_auto","model":"/models",...}'`. Treat `html`/`png` as best-effort — `csv`/`json` are the source of truth.
12. **Quoting the ETA**: the sweep banner prints an estimate (sum of windows × stream steps + ~45 s per-run overhead). For the default 36-run matrix that is **~4.5 h of windows + ~27 min ≈ 5 h** — under-quoting is how the run "dies in a closed terminal". Progress in one line: `ls <run_dir>/profiles | wc -l` (36 = done).
13. **Non-default host layout**: the script defaults are one specific production layout. On any other machine set all four: `SERVING_CONTAINER` (inspect target), `HOST_MODELS_DIR` (host path with the tokenizer files; mounted to `/models` and listed in launch info), `TOKENIZER_MODEL` (path *inside* the GuideLLM container, i.e. under `/models`), and `CONFIGS_DIR` (else the script `mkdir -p`s a stray dir in the default layout).
14. **Checking GPU visibility in the serving image**: the vLLM image entrypoint is `vllm serve`, so a bare `docker run ... image python3 -c ...` parses `python3` as a server flag and fails. Use `docker run --rm --gpus all --entrypoint python3 <vllm-image> -c "import torch; print(torch.cuda.is_available())"`. If `cuInit` returns 802 "system not yet initialized" on a Hopper SXM in a KVM VM without NVSwitch devices (`Fabric State: In Progress`, fabricmanager "NVSwitch driver: Nothing to do"), and NVLink is not needed there: `/etc/modprobe.d/nvidia-nvlink.conf` → `options nvidia NVreg_NvLinkDisable=1` (modprobe.d name *with* the `NVreg_` prefix; `/proc/driver/nvidia/params` shows it *without*), reload the nvidia modules, `systemctl disable --now nvidia-fabricmanager` → `cuInit` returns 0.
15. **`request_totals` has a `total` key (and more)** — compute completion from `successful/(successful+errored+incomplete)` only; `successful/sum(dict.values())` understates it 2×.
16. **Verify engine defaults from the running version, not from memory** — defaults change between releases (vLLM's `max_num_seqs` default was 1024 in some v1-scheduler builds and 128 in v0.23; claiming the wrong one flipped the whole "do 192/256 queue or get admitted" analysis). Check the source (`vllm/config/scheduler.py` → `DEFAULT_MAX_NUM_SEQS`) **and** the exact serving container: `docker exec <serving_container> python3 -c "from vllm.config.scheduler import SchedulerConfig; print(SchedulerConfig.DEFAULT_MAX_NUM_SEQS)"`. Same for any server knob that shapes the sweep (`max_num_batched_tokens`, chunked prefill, prefix caching).

---

## Deep-Dive References

- [GuideLLM Load Profiles Reference](references/profiles.md) — mechanics of synchronous/throughput/concurrent/constant/poisson/sweep profiles, constraints, workload sizing, and the concurrency-sweep methodology.
- [Report Template & Guidelines](references/report-template.md) — `REPORT.md` layout, the launch-metadata inspect template, and sweep-report structure.
- [Example sweep results (Qwen3.8-27B)](references/example-sweep-qwen38-27b.md) — a finished 28-run sweep: environment, per-workload peaks, saturation points, incidents.
