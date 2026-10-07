#!/usr/bin/env bash
#
# guidellm_concurrency_sweep.sh
# Runs a concurrency sweep (streams 1..256) for 4 workload shapes against a
# vLLM server, collecting GPU telemetry (mx-smi or nvidia-smi) for the whole
# run, plus model
# identity and how the serving container was launched (inspect template).
#
# Usage:
#   bash scripts/guidellm_concurrency_sweep.sh                 # fresh run
#   SWEEP_RUN_DIR=./guidellm_sweep_YYYYMMDD_HHMMSS \
#     bash scripts/guidellm_concurrency_sweep.sh               # re-run: skips
#                                                               # already-good
#                                                               # profiles
#   RUNTIME=nerdctl bash scripts/guidellm_concurrency_sweep.sh # GuideLLM via
#                                                               # nerdctl
#
# Overridable via env (defaults = current production layout):
#   SERVING_CONTAINER RUNTIME ENDPOINT GUIDELLM_IMAGE HOST_MODELS_DIR
#   CONFIGS_DIR TOKENIZER_MODEL SWEEP_STREAMS WARMUP WARMUP_STREAMS
#

set -euo pipefail

SERVING_CONTAINER="${SERVING_CONTAINER:-vllm-qwen38-27b-w8a8}"
RUNTIME="${RUNTIME:-docker}"
GUIDELLM_IMAGE="${GUIDELLM_IMAGE:-ghcr.io/vllm-project/guidellm:latest}"
ENDPOINT="${ENDPOINT:-http://localhost:8000}"
HOST_MODELS_DIR="${HOST_MODELS_DIR:-/home/rgainanov/metax-vllm/models}"
CONFIGS_DIR="${CONFIGS_DIR:-/home/rgainanov/metax-vllm/configs}"
TOKENIZER_MODEL="${TOKENIZER_MODEL:-/models/metax-tech/Qwen3.8-27B-W8A8}"
# Baseline stream grid. vLLM's default max_num_seqs is 128
# (SchedulerConfig.DEFAULT_MAX_NUM_SEQS), so 192/256 exceed the admission cap
# and queue — exactly the saturation signal we want to measure.
STREAM_VALUES=(1 4 8 16 32 64 128 192 256)
if [ -n "${SWEEP_STREAMS:-}" ]; then
    read -ra STREAM_VALUES <<< "${SWEEP_STREAMS}"
fi

# Clean up any previous yaml
mkdir -p "${CONFIGS_DIR}"
rm -f "${CONFIGS_DIR}"/guidellm_concurrent_*.yaml \
      "${CONFIGS_DIR}"/guidellm_warmup_*.yaml

declare -A YAML_MAP
YAML_MAP["8k_1k"]="8192:1024"
YAML_MAP["chat_2k_512"]="2048:512"
YAML_MAP["reasoning_4k_2k"]="4096:2048"
YAML_MAP["quick_256_128"]="256:128"

# Per-workload benchmark duration (seconds). Heavier workloads at high
# concurrency need a longer window, otherwise most requests are still
# in-flight when the benchmark ends ("incomplete") and the latency
# statistics are skewed by survivorship bias.
declare -A DURATION_MAP
DURATION_MAP["8k_1k"]="600"
DURATION_MAP["chat_2k_512"]="420"
DURATION_MAP["reasoning_4k_2k"]="600"
DURATION_MAP["quick_256_128"]="180"

# Deterministic list of workload names (assoc arrays iterate unordered),
# used for yaml generation and the report table.
ORDERED_NAMES=()

# Generate yaml files
for name in "${!YAML_MAP[@]}"; do
    ORDERED_NAMES+=("$name")
    IFS=':' read -r prompt output <<< "${YAML_MAP[$name]}"
    duration="${DURATION_MAP[$name]}"
    cat > "${CONFIGS_DIR}/guidellm_concurrent_${name}.yaml" <<EOF
spec:
  backend:
    kind: openai_http
    target: ${ENDPOINT}

  tokenizer:
    kind: huggingface_auto
    model: ${TOKENIZER_MODEL}

  data:
    - kind: synthetic_text
      prompt_tokens: ${prompt}
      output_tokens: ${output}

  constraints:
    - kind: max_duration
      seconds: ${duration}

  profile:
    kind: concurrent

  outputs:
    - kind: csv
      path: /results/benchmarks.csv
    - kind: json
      path: /results/benchmarks.json
    - kind: html
      path: /results/benchmarks.html
    - kind: plot
      path: /results/benchmarks.png
EOF
done

START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BASE_DIR="$(pwd)"
# Reuse an existing run directory if SWEEP_RUN_DIR is set (re-run mode that
# skips already-successful profiles); otherwise create a fresh timestamped one.
if [ -n "${SWEEP_RUN_DIR:-}" ] && [ -d "${SWEEP_RUN_DIR}" ]; then
    RUN_DIR="${SWEEP_RUN_DIR}"
else
    RUN_DIR="${BASE_DIR}/guidellm_sweep_${TIMESTAMP}"
fi
mkdir -p "${RUN_DIR}"

echo "============================================================"
echo "Complete Sweep Orchestration V2 — Qwen3.8-27B"
echo "Start Time:         ${START_TIME}"
echo "Output Directory:   ${RUN_DIR}"
echo "Stream values:      ${STREAM_VALUES[*]}"
echo "Container Runtime:  ${RUNTIME}"
echo "Profiles:           ${#YAML_MAP[@]} workloads × ${#STREAM_VALUES[@]} stream steps = $((${#YAML_MAP[@]} * ${#STREAM_VALUES[@]})) runs"
# Duration estimate: sum(per-workload window × stream steps) + ~45 s
# container/tokenizer overhead per run. Report it — under-estimating the
# wall time is how a sweep "dies" in a closed terminal.
WINDOW_S=0
for name in "${!YAML_MAP[@]}"; do
    WINDOW_S=$(( WINDOW_S + DURATION_MAP[$name] * ${#STREAM_VALUES[@]} ))
done
OVRH_S=$(( ${#YAML_MAP[@]} * ${#STREAM_VALUES[@]} * 45 ))
echo "Estimated time:     ~$(( (WINDOW_S + OVRH_S) / 60 )) min total"
echo "                   ($(( WINDOW_S / 60 )) min of measurement windows +"
echo "                    ~$(( OVRH_S / 60 )) min per-run overhead)"
echo "Warm-up:            ${WARMUP:-1} (300 s quick 256/128, streams=${WARMUP_STREAMS:-32} + 30 s drain; fresh runs only; WARMUP=0 disables)"
echo "Progress check:     ls <run_dir>/profiles | wc -l   # ${#YAML_MAP[@]} x ${#STREAM_VALUES[@]} = done"
echo "============================================================"

# Start GPU telemetry (run on host; writes metrics.csv directly into the run
# dir, next to REPORT.md). Tool selection: TELEMETRY_CMD override (a
# space-separated command; the CSV path is appended as its last argument) >
# mx-smi (MetaX) > nvidia-smi (NVIDIA hosts) > disabled. Only start a new
# telemetry session for a fresh run; in re-run mode a live collector (or an
# existing CSV) is left untouched. Never run two collectors: a second writer
# duplicates 1-Hz rows in metrics.csv.
echo "Starting GPU telemetry in background on host..."
start_telemetry() {
    rm -f "${RUN_DIR}/metrics.csv"
    if [ -n "${TELEMETRY_CMD:-}" ]; then
        # shellcheck disable=SC2086
        ${TELEMETRY_CMD} "${RUN_DIR}/metrics.csv" \
            > "${RUN_DIR}/telemetry_start.log" 2>&1 &
    elif command -v mx-smi >/dev/null 2>&1; then
        # mx-smi forbids -t when writing to a file, so we poll -l 1000 and
        # kill it at the end.
        mx-smi -l 1000 -o "${RUN_DIR}/metrics.csv" \
            --show-memory --show-usage --show-temperature --show-pmbus-power \
            > "${RUN_DIR}/telemetry_start.log" 2>&1 &
    elif command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=timestamp,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
            --format=csv -l 1 \
            > "${RUN_DIR}/metrics.csv" \
            2> "${RUN_DIR}/telemetry_start.log" &
    else
        echo "No mx-smi or nvidia-smi found; telemetry disabled."
        return 0
    fi
    TELEMETRY_PID=$!
}
TELEMETRY_PID=""
if [ -n "${SWEEP_RUN_DIR:-}" ]; then
    if pgrep -f 'mx-smi -l 1000|nvidia-smi --query-gpu=timestamp' >/dev/null 2>&1; then
        echo "Telemetry already running, reusing it."
        TELEMETRY_PID="$(pgrep -f 'mx-smi -l 1000|nvidia-smi --query-gpu=timestamp' | head -1)"
    elif [ -s "${RUN_DIR}/metrics.csv" ]; then
        echo "Existing metrics.csv found; leaving telemetry untouched."
    else
        start_telemetry
    fi
else
    start_telemetry
fi
echo "Telemetry PID: ${TELEMETRY_PID:-none}"

# Start vLLM server-side metrics poller (run on host: the serving endpoint
# exposes Prometheus /metrics). This is what attributes the 192/256
# oversubscription steps to scheduler behavior (queue depth, KV-cache usage,
# preemptions) rather than just the TTFT curve. Writes server_metrics.csv
# into the run dir. The poller runs as `bash -c` with a marker as $0 so it
# can be found/stopped by pattern without matching the sweep script itself.
# In re-run mode a live poller (or an existing file) is left untouched; a
# fresh poller appends (header written only when the file is new).
echo "Starting vLLM /metrics poller in background on host..."
start_server_metrics() {
    [ -s "${RUN_DIR}/server_metrics.csv" ] || \
        printf 'epoch,metric,value\n' > "${RUN_DIR}/server_metrics.csv"
    # bash -c body: $1 = csv path, $2 = endpoint; $0 carries the marker so
    # pgrep/pkill -f can find the loop (and only the loop).
    bash -c '
        out="$1"; url="$2"
        while :; do
            ts=$(date +%s)
            curl -s --max-time 2 "$url/metrics" 2>/dev/null |
                grep -E "^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|gpu_cache_usage_info|num_preemptions(_total)?)(\{| )" 2>/dev/null |
                sed -E "s/^vllm:/$ts,/" |
                sed -E "s/[[:space:]]+([0-9eE.+-]+)$/,\\1/" >> "$out" || true
            sleep 2
        done' "__sweep_server_metrics" "${RUN_DIR}/server_metrics.csv" \
        "${ENDPOINT}" > "${RUN_DIR}/server_metrics_start.log" 2>&1 &
    SERVER_METRICS_PID=$!
}
SERVER_METRICS_PID=""
if [ -n "${SWEEP_RUN_DIR:-}" ]; then
    if pgrep -f '__sweep_server_metrics' >/dev/null 2>&1; then
        echo "Server-metrics poller already running, reusing it."
        SERVER_METRICS_PID="$(pgrep -f '__sweep_server_metrics' | head -1)"
    elif [ -s "${RUN_DIR}/server_metrics.csv" ]; then
        echo "Existing server_metrics.csv found; leaving it untouched."
    else
        start_server_metrics
    fi
else
    start_server_metrics
fi
echo "Server-metrics PID: ${SERVER_METRICS_PID:-none}"

# verify server ready
wait_for_server() {
    for i in {1..30}; do
        if curl -s --connect-timeout 5 "${ENDPOINT}/v1/models" >/dev/null 2>&1; then
            echo "Server ready."
            return 0
        fi
        sleep 5
    done
    echo "ERROR: Server did not become ready."
    return 1
}
wait_for_server

# ------------------------------------------------------------------
# Capture model identity + how the serving container was launched.
# Done up-front so the info survives even if the sweep dies mid-run.
# ------------------------------------------------------------------
echo "Capturing model / launch metadata into ${RUN_DIR}..."

# The serving container may live under either runtime — try the chosen one
# first, then the other available runtime.
CANDIDATES=("$RUNTIME")
for alt in docker nerdctl; do
    [ "$alt" = "$RUNTIME" ] || CANDIDATES+=("$alt")
done
INSPECT_RUNTIME=""
for rt in "${CANDIDATES[@]}"; do
    if command -v "$rt" >/dev/null 2>&1 && \
       $rt inspect "$SERVING_CONTAINER" >/dev/null 2>&1; then
        INSPECT_RUNTIME="$rt"
        break
    fi
done

MODEL_ID="unknown"
SERVING_IMAGE="unknown"
if [ -n "$INSPECT_RUNTIME" ]; then
    echo "Inspecting '${SERVING_CONTAINER}' via ${INSPECT_RUNTIME}..."
    $INSPECT_RUNTIME inspect "$SERVING_CONTAINER" \
        > "${RUN_DIR}/serving_container_inspect.json" 2>/dev/null || true
    SERVING_IMAGE="$($INSPECT_RUNTIME inspect --format '{{.Config.Image}}' \
        "$SERVING_CONTAINER" 2>/dev/null || echo unknown)"
    $INSPECT_RUNTIME inspect "$SERVING_CONTAINER" --format '
IMAGE: {{.Config.Image}}
ENTRYPOINT: {{json .Config.Entrypoint}}
CMD: {{json .Config.Cmd}}
MOUNTS:
{{range .Mounts}}  {{.Source}} -> {{.Destination}} ({{.Mode}})
{{end}}DEVICES:
{{range .HostConfig.Devices}}  {{.PathOnHost}} -> {{.PathInContainer}} {{.CgroupPermissions}}
{{end}}PORTS:
{{range $p, $b := .NetworkSettings.Ports}}  {{$p}} -> {{$b}}
{{end}}ENV:
{{range .Config.Env}}  {{.}}
{{end}}GROUP_ADD:
  {{.HostConfig.GroupAdd}}
SECURITY_OPT:
  {{.HostConfig.SecurityOpt}}
ULIMITS:
  {{range .HostConfig.Ulimits}}  {{.Name}}={{.Soft}}:{{.Hard}}
{{end}}CAP_ADD:
  {{.HostConfig.CapAdd}}' > "${RUN_DIR}/serving_launch_info.txt" 2>&1 || true
else
    echo "Warning: could not inspect '${SERVING_CONTAINER}' via docker/nerdctl."
    echo "(container inspect unavailable: ${SERVING_CONTAINER})" \
        > "${RUN_DIR}/serving_launch_info.txt"
fi

# What the GuideLLM container will see as tokenizer/model weights.
{
    echo "=== MODEL CHECK (tokenizer source: ${HOST_MODELS_DIR}) ==="
    ls -la "${HOST_MODELS_DIR}" 2>&1 || true
} >> "${RUN_DIR}/serving_launch_info.txt"

# Model identity as the OpenAI-compatible endpoint reports it.
curl -s --connect-timeout 10 "${ENDPOINT}/v1/models" \
    > "${RUN_DIR}/model_info.json" 2>/dev/null || true
if [ -s "${RUN_DIR}/model_info.json" ]; then
    MODEL_ID="$(python3 - "${RUN_DIR}/model_info.json" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1]))["data"][0]["id"])
except Exception:
    pass
PYEOF
)"
    MODEL_ID="${MODEL_ID:-unknown}"
fi
echo "Model id: ${MODEL_ID}"
echo "Serving image: ${SERVING_IMAGE}"

# ------------------------------------------------------------------
# Warm-up: absorb JIT / allocator / cold-start effects so the first
# grid step measures steady state, not a warming engine (serving
# benchmark methodology: 100+ requests or 10k output tokens before
# measuring, then let the queue drain). Skipped in re-run mode: the
# server already served the original sweep.
# ------------------------------------------------------------------
if [ "${WARMUP:-1}" != "0" ] && [ -z "${SWEEP_RUN_DIR:-}" ]; then
    warmup_yaml="${CONFIGS_DIR}/guidellm_warmup_quick.yaml"
    cat > "${warmup_yaml}" <<EOF
spec:
  backend:
    kind: openai_http
    target: ${ENDPOINT}

  tokenizer:
    kind: huggingface_auto
    model: ${TOKENIZER_MODEL}

  data:
    - kind: synthetic_text
      prompt_tokens: 256
      output_tokens: 128

  constraints:
    - kind: max_duration
      seconds: 300

  profile:
    kind: concurrent

  outputs:
    - kind: json
      path: /results/benchmarks.json
EOF
    warmup_dir="${RUN_DIR}/warmup"
    mkdir -p "${warmup_dir}"
    chmod 777 "${warmup_dir}" 2>/dev/null || true
    echo "Warm-up before the grid: quick 256/128, streams=${WARMUP_STREAMS:-32}, 300 s..."
    if "$RUNTIME" run --rm \
            --network host \
            -v "${HOST_MODELS_DIR}:/models:ro" \
            -v "${warmup_yaml}:/tmp/warmup.yaml:ro" \
            -v "${warmup_dir}:/results:rw" \
            "$GUIDELLM_IMAGE" \
            run --config /tmp/warmup.yaml \
            --profile "kind=concurrent,streams=${WARMUP_STREAMS:-32}"; then
        echo "Warm-up complete; letting the queue drain (30 s)..."
        sleep 30
    else
        echo "Warm-up failed (continuing with the grid); check the serving container."
    fi
fi

# Run each workload × each stream
for name in "${!YAML_MAP[@]}"; do
    for stream in "${STREAM_VALUES[@]}"; do
        echo "------------------------------------------------------------"
        echo "Running: ${name} streams=${stream}"
        echo "------------------------------------------------------------"

        profile_dir="${RUN_DIR}/profiles/${name}_stream_${stream}"

        # Skip a run if it already completed successfully in a previous
        # execution of this script (reuse the same RUN_DIR): no errors and
        # at least 90% of the requests finished within the window.
        if [ -s "${profile_dir}/benchmarks.json" ]; then
            if python3 - "${profile_dir}/benchmarks.json" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
metrics = data["benchmarks"][0]["metrics"]
totals = metrics["request_totals"]
ok, err, incomplete = totals["successful"], totals["errored"], totals["incomplete"]
total = totals["total"]
sys.exit(0 if total > 0 and err == 0 and (ok / total) >= 0.90 else 1)
PYEOF
            then
                echo "Skipping (already successful): ${name} streams=${stream}"
                continue
            fi
        fi

        mkdir -p "${profile_dir}"
        # World-writable so the non-root GuideLLM container can write /results.
        # A missing target would be auto-created root-owned by Docker and the
        # run would die with `PermissionError: /results/benchmarks.csv`.
        chmod 777 "${profile_dir}" 2>/dev/null || true

        config_file="${CONFIGS_DIR}/guidellm_concurrent_${name}.yaml"

        # ensure server ready between runs
        for i in {1..10}; do
            if curl -s "${ENDPOINT}/v1/models" >/dev/null 2>&1; then
                break
            fi
            sleep 5
        done

        CMD=(
            "$RUNTIME" run --rm
            --network host
            -v "${HOST_MODELS_DIR}:/models:ro"
            -v "${config_file}:/tmp/${name}.yaml:ro"
            -v "${profile_dir}:/results:rw"
            "$GUIDELLM_IMAGE"
            run --config /tmp/${name}.yaml
            --profile 'kind=concurrent,streams='"${stream}"
        )
        echo "Command: ${CMD[*]}"
        if "${CMD[@]}"; then
            echo "Completed: ${name} streams=${stream}"
        else
            echo "FAILED: ${name} streams=${stream} (exit $?)"
        fi
    done
done

# Stop telemetry. Kill by command pattern, and by PID only after verifying
# /proc/<pid>/cmdline still matches a collector pattern: a PID captured at
# startup may be stale (PID reuse) and must not TERM an unrelated process.
echo "Stopping telemetry (PID ${TELEMETRY_PID:-?})..."
if [ -n "${TELEMETRY_PID}" ] && \
   tr '\0' ' ' < "/proc/${TELEMETRY_PID}/cmdline" 2>/dev/null | \
       grep -qE 'mx-smi -l 1000|nvidia-smi --query-gpu=timestamp'; then
    kill "${TELEMETRY_PID}" 2>/dev/null || true
fi
pkill -f 'mx-smi -l 1000' 2>/dev/null || true
pkill -f 'nvidia-smi --query-gpu=timestamp' 2>/dev/null || true

# Stop the server-metrics poller. Same stale-PID guard as telemetry: only
# kill after /proc/<pid>/cmdline still carries the poller marker.
echo "Stopping server-metrics poller (PID ${SERVER_METRICS_PID:-?})..."
if [ -n "${SERVER_METRICS_PID}" ] && \
   tr '\0' ' ' < "/proc/${SERVER_METRICS_PID}/cmdline" 2>/dev/null | \
       grep -q '__sweep_server_metrics'; then
    kill "${SERVER_METRICS_PID}" 2>/dev/null || true
fi
pkill -f '__sweep_server_metrics' 2>/dev/null || true
sleep 3

# Generate REPORT.md
{
    echo "# GuideLLM Concurrency Sweep Report — ${MODEL_ID}"
    echo
    echo "- **Run Start**: ${START_TIME}"
    echo "- **Run directory**: \`$(basename "${RUN_DIR}")\`"
    echo "- **Target endpoint**: \`${ENDPOINT}\`"
    echo "- **Model id (from /v1/models)**: \`${MODEL_ID}\`"
    echo "- **Serving container**: ${SERVING_CONTAINER} (inspected via ${INSPECT_RUNTIME:-unavailable})"
    echo "- **Serving image**: \`${SERVING_IMAGE}\`"
    echo "- **GuideLLM image**: \`${GUIDELLM_IMAGE}\`"
    echo "- **Container runtime**: \`${RUNTIME}\`"
    echo "- **Tokenizer (synthetic prompts)**: \`${TOKENIZER_MODEL}\`"
    echo "- **Streams sweep**: ${STREAM_VALUES[*]}"
    echo "- **Total runs**: $((${#YAML_MAP[@]} * ${#STREAM_VALUES[@]}))"
    echo "- **Warm-up**: \`${WARMUP:-1}\` (300 s quick 256/128 at streams=${WARMUP_STREAMS:-32} + 30 s queue drain; fresh runs only — skipped when \`SWEEP_RUN_DIR\` is set)"
    echo
    echo "## Server launch arguments (from container CMD)"
    echo
    echo '```json'
    echo "$($INSPECT_RUNTIME inspect --format '{{json .Config.Cmd}}' "$SERVING_CONTAINER" 2>/dev/null || echo '"unavailable"')"
    echo '```'
    echo
    echo "## Workload durations"
    echo
    echo "| Workload | Prompt → Output | Window |"
    echo "|---|---|---|"
    for name in "${ORDERED_NAMES[@]}"; do
        IFS=':' read -r prompt output <<< "${YAML_MAP[$name]}"
        echo "| ${name} | ${prompt} → ${output} | ${DURATION_MAP[$name]} s |"
    done
    echo
    echo "## Model & launch metadata (captured with the measurements)"
    echo
    echo "- Endpoint model list: [\`model_info.json\`](model_info.json)"
    echo "- Launch configuration (mounts, devices, ports, env, groups, ulimits):"
    echo "  [\`serving_launch_info.txt\`](serving_launch_info.txt)"
    echo "- Full container dump: [\`serving_container_inspect.json\`](serving_container_inspect.json)"
    echo
    echo "## How to read the results"
    echo
    echo "Each run directory \`profiles/<workload>_stream_<N>/\` contains"
    echo "\`benchmarks.csv\`, \`benchmarks.json\`, \`benchmarks.html\`, \`benchmarks.png\`."
    echo
    echo "**Completion rate** = \`successful / total\` requests. Requests still in"
    echo "flight when the window closes are counted as \`incomplete\`. A low"
    echo "completion rate at high concurrency is the signature of **oversaturation**"
    echo "(the queue never drains within the window) — a measurement of the"
    echo "saturation point, not a failure. The \`errored\` count is the real failure"
    echo "indicator; it should be 0 everywhere for a healthy sweep."
    echo
    echo "Append an aggregate summary table and any incident notes to this file"
    echo "after the sweep (see the example results reference in the skill)."
    echo
    echo "## Artifacts"
    echo
    echo "- [profiles/](profiles/) — one directory per workload × stream step"
    echo
    echo "## GPU telemetry"
    echo
    echo "- Telemetry CSV (1 Hz: timestamp, utilization, memory, temperature,"
    echo "  power; source: mx-smi or nvidia-smi, whichever is on the host):"
    echo "  [\`metrics.csv\`](metrics.csv)"
    echo "  If two collectors were ever active, deduplicate by the time column."
    echo
    echo "## Scheduler telemetry (vLLM \`${ENDPOINT}/metrics\`, 2 s sampling)"
    echo
    echo "- Queue depth, KV-cache usage and preemption counters:"
    echo "  [\`server_metrics.csv\`](server_metrics.csv)"
    echo "  Use it to attribute the oversubscription steps (streams >"
    echo "  max_num_seqs): rising \`num_requests_waiting\` /"
    echo "  \`kv_cache_usage_perc\` with a growing \`num_preemptions_total\`"
    echo "  is the KV-cache-oversubscription signature behind the TTFT knee."
    echo
    echo "---"
    echo "*Report generated by guidellm-benchmark skill.*"
} > "${RUN_DIR}/REPORT.md"

echo "============================================================"
echo "All ${#YAML_MAP[@]} × ${#STREAM_VALUES[@]} runs complete. Report: ${RUN_DIR}/REPORT.md"
echo "============================================================"
