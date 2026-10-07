#!/usr/bin/env python3
# scripts/bench-parallel-load.py
#
# Standalone load/performance benchmark -- NOT part of the pytest/BATS test
# suite (make test / test-all / test-pytest never run this). It mutates live
# Ollama server settings (OLLAMA_NUM_PARALLEL, temporarily OLLAMA_MAX_LOADED_
# MODELS) and restarts the service to apply them, which briefly evicts every
# model currently loaded stack-wide -- run it when nothing else needs Ollama.
#
# Goal: understand the real impact of OLLAMA_NUM_PARALLEL on performance,
# answer quality, and host load when multiple requests hit the same model
# concurrently. Fires N concurrent requests at one model under each
# requested NUM_PARALLEL value in turn, measuring per-request time-to-
# first-token (TTFT) and total completion time, plus host load/memory
# during the batch. Quality is NOT auto-graded -- full transcripts are
# saved for manual review.
#
# Usage:
#   python3 scripts/bench-parallel-load.py [options]
#   make bench-parallel-load MODEL=phi4:14b-q8_0 NUM_PARALLEL_VALUES=1,3
#
# Options (all optional, see --help):
#   --model               Model to benchmark (default: phi4:14b-q8_0)
#   --num-parallel-values Comma list of OLLAMA_NUM_PARALLEL values to test (default: 1,3)
#   --concurrency          Concurrent requests per scenario (default: 4)
#   --max-tokens           Per-request max_tokens (default: 400)
#   --prompts-file         One prompt per line; overrides the built-in default prompts
#   --prompt-template      Used with --prompt-topics if --prompts-file not given
#   --prompt-topics        Comma list substituted into --prompt-template's {topic}
#   --with-tools           Offer a stub tool (tool_choice=auto); skipped automatically
#                          if the model isn't tagged "tools" in LiteLLM's /model/info
#   --results-dir           Where to write the markdown report (default: bench-results/)
#   --litellm-url           Default: http://localhost:9000
#
# Safety: switching OLLAMA_NUM_PARALLEL away from its current live value also
# temporarily pins OLLAMA_MAX_LOADED_MODELS=1 for that scenario (so the
# per-slot KV multiplier only ever applies to the one model under test, not
# whatever else is loaded) -- both are restored to their original live values
# at the end, in a finally block, even on failure. Quadlet regeneration is
# diffed against a full backup before reload to confirm ONLY ollama.container
# changed (same pattern as D-049/D-047).

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

import httpx

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE_CONFIG_FILE = os.path.expanduser(os.environ.get("CONFIG_FILE", "~/ai-stack/configs/config.json"))
QUADLET_DIR = os.path.expanduser("~/.config/containers/systemd")
OLLAMA_QUADLET = os.path.join(QUADLET_DIR, "ollama.container")

DEFAULT_PROMPTS = [
    "Describe Open WebGUI knowledge manage features, brief, high level and common uses.",
    "Describe how to create an LLM Agent around a specific LLM Model as an mcp tool. Include a definition for this element.",
    "Describe how to create an LLM SubAgent around a specific LLM Model as an mcp tool. Include a definition for this element.",
    "Describe how an LLM Agent and LLM SubAgent, implemented as mcp tools, would work together.",
]

STUB_TOOL = [
    {
        "type": "function",
        "function": {
            "name": "search_docs",
            "description": "Search internal documentation for a topic.",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        },
    }
]


def _read_secret(name: str) -> str:
    env_val = os.environ.get(name.upper(), "")
    if env_val:
        return env_val
    result = subprocess.run(
        ["podman", "run", "--rm", "--secret", name, "docker.io/library/alpine:latest",
         "sh", "-c", f"cat /run/secrets/{name}"],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def _sh(cmd: list, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def _live_ollama_env() -> dict:
    out = _sh(["podman", "exec", "ollama", "env"]).stdout
    env = {}
    for line in out.splitlines():
        if line.startswith("OLLAMA_"):
            k, _, v = line.partition("=")
            env[k] = v
    return env


def _backup_quadlets() -> str:
    backup_dir = f"/tmp/bench-parallel-load-quadlet-backup-{int(time.time())}"
    os.makedirs(backup_dir, exist_ok=True)
    for f in os.listdir(QUADLET_DIR):
        if f.endswith(".container"):
            shutil.copy(os.path.join(QUADLET_DIR, f), os.path.join(backup_dir, f))
    return backup_dir


def _wait_ollama_healthy(timeout=60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = httpx.get("http://localhost:11434/api/version", timeout=3.0)
            if r.status_code == 200:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def set_ollama_env(num_parallel: int, max_loaded_models: int) -> None:
    """Edit live config.json's ollama.environment, regenerate quadlets (diff-verified
    to touch only ollama.container), reload systemd, restart, wait for health."""
    with open(LIVE_CONFIG_FILE) as f:
        cfg = json.load(f)
    before_env = dict(cfg["services"]["ollama"]["environment"])

    backup_dir = _backup_quadlets()

    cfg["services"]["ollama"]["environment"] = {
        **before_env,
        "OLLAMA_NUM_PARALLEL": str(num_parallel),
        "OLLAMA_MAX_LOADED_MODELS": str(max_loaded_models),
    }
    with open(LIVE_CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)

    gen = _sh(
        ["bash", os.path.join(PROJECT_ROOT, "scripts", "configure.sh"), "generate-quadlets"],
        env={**os.environ, "CONFIG_FILE": LIVE_CONFIG_FILE},
    )
    if gen.returncode != 0:
        raise RuntimeError(f"generate-quadlets failed:\n{gen.stdout}\n{gen.stderr}")

    changed = []
    for f in os.listdir(QUADLET_DIR):
        if not f.endswith(".container"):
            continue
        backup_f = os.path.join(backup_dir, f)
        live_f = os.path.join(QUADLET_DIR, f)
        if not os.path.exists(backup_f) or open(backup_f).read() != open(live_f).read():
            changed.append(f)
    if changed != ["ollama.container"]:
        raise RuntimeError(
            f"generate-quadlets changed more than just ollama.container: {changed} "
            f"-- refusing to reload. Backup left at {backup_dir} for manual recovery."
        )

    _sh(["systemctl", "--user", "daemon-reload"])
    _sh(["systemctl", "--user", "restart", "ollama.service"])
    if not _wait_ollama_healthy():
        raise RuntimeError("ollama.service did not become healthy after restart")


def unload_model(model: str, timeout=30) -> None:
    """Force-evict a model from Ollama immediately (keep_alive=0), bypassing
    LiteLLM -- this is benchmark housekeeping, not a governed chat request."""
    try:
        httpx.post(
            "http://localhost:11434/api/chat",
            json={"model": model, "messages": [{"role": "user", "content": "."}],
                  "stream": False, "keep_alive": 0, "options": {"num_predict": 1}},
            timeout=timeout,
        )
    except Exception:
        pass
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            loaded = httpx.get("http://localhost:11434/api/ps", timeout=5.0).json().get("models", [])
            if not any(m.get("name") == model for m in loaded):
                return
        except Exception:
            pass
        time.sleep(1)


def snapshot_load() -> dict:
    loadavg = open("/proc/loadavg").read().split()[:3]
    free_out = _sh(["free", "-m"]).stdout
    avail_mb = None
    for line in free_out.splitlines():
        if line.startswith("Mem:"):
            avail_mb = int(line.split()[6])
    return {"load1": float(loadavg[0]), "load5": float(loadavg[1]), "load15": float(loadavg[2]),
            "mem_available_mb": avail_mb, "ts": time.time()}


def load_sampler(stop_event: threading.Event, samples: list, interval=2):
    while not stop_event.is_set():
        samples.append(snapshot_load())
        stop_event.wait(interval)


def run_single_request(litellm_url, headers, model, prompt, max_tokens, tools, barrier, idx):
    payload = {
        "model": model, "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens, "temperature": 0.0, "stream": True,
        "stream_options": {"include_usage": True},
    }
    # tools, if any, were already resolved per-model by the caller (a stub tool
    # offered to a model untagged "tools" would error, not just no-op)
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"

    barrier.wait()
    send_ts = time.time()
    first_token_ts = None
    text_parts = []
    tool_called = False
    finish_reason = None
    usage = {}

    try:
        with httpx.Client(timeout=600.0) as client:
            with client.stream("POST", f"{litellm_url}/chat/completions", json=payload, headers=headers) as resp:
                if resp.status_code != 200:
                    body = resp.read().decode(errors="replace")
                    return {"idx": idx, "model": model, "prompt": prompt, "error": f"HTTP {resp.status_code}: {body[:300]}"}
                for line in resp.iter_lines():
                    if not line or not line.startswith("data:"):
                        continue
                    data = line[len("data:"):].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    choice = (chunk.get("choices") or [{}])[0]
                    delta = choice.get("delta", {})
                    if delta.get("content") and first_token_ts is None:
                        first_token_ts = time.time()
                    if delta.get("content"):
                        text_parts.append(delta["content"])
                    if delta.get("tool_calls"):
                        tool_called = True
                        if first_token_ts is None:
                            first_token_ts = time.time()
                    if choice.get("finish_reason"):
                        finish_reason = choice["finish_reason"]
                    if chunk.get("usage"):
                        usage = chunk["usage"]
    except Exception as exc:
        return {"idx": idx, "model": model, "prompt": prompt, "error": str(exc)}

    end_ts = time.time()
    return {
        "idx": idx, "model": model, "prompt": prompt, "error": None,
        "send_ts": send_ts, "first_token_ts": first_token_ts, "end_ts": end_ts,
        "ttft_s": (first_token_ts - send_ts) if first_token_ts else None,
        "total_s": end_ts - send_ts,
        "text": "".join(text_parts), "tool_called": tool_called,
        "finish_reason": finish_reason, "usage": usage,
    }


def run_scenario(num_parallel, models, prompts, max_tokens, tools_by_model, litellm_url, headers, concurrency):
    label = models[0] if len(models) == 1 else "+".join(models)
    print(f"\n=== Scenario: NUM_PARALLEL={num_parallel}, models={label} ===", file=sys.stderr)
    for m in set(models):
        unload_model(m)

    stop_event = threading.Event()
    samples = []
    sampler = threading.Thread(target=load_sampler, args=(stop_event, samples), daemon=True)
    sampler.start()

    batch_start = time.time()
    barrier = threading.Barrier(concurrency)
    request_prompts = [prompts[i % len(prompts)] for i in range(concurrency)]
    request_models = [models[i % len(models)] for i in range(concurrency)]

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(run_single_request, litellm_url, headers, request_models[i], request_prompts[i],
                        max_tokens, tools_by_model.get(request_models[i]), barrier, i)
            for i in range(concurrency)
        ]
        results = [f.result() for f in futures]

    batch_end = time.time()
    stop_event.set()
    sampler.join(timeout=5)

    for m in set(models):
        unload_model(m)

    return {
        "num_parallel": num_parallel,
        "models": models,
        "batch_wall_s": batch_end - batch_start,
        "results": results,
        "load_samples": samples,
    }


def render_report(models, max_tokens, concurrency, scenarios) -> str:
    title = models[0] if len(models) == 1 else " + ".join(models) + " (distributed)"
    lines = [
        f"# Parallel-load benchmark — `{title}`",
        "",
        f"Generated: {datetime.now().isoformat(timespec='seconds')}",
        f"Concurrency: {concurrency} simultaneous requests per scenario · max_tokens={max_tokens}",
        "",
    ]
    multi = len(models) > 1
    for sc in scenarios:
        np_val = sc["num_parallel"]
        ok = [r for r in sc["results"] if not r.get("error")]
        errs = [r for r in sc["results"] if r.get("error")]
        lines += [
            f"## NUM_PARALLEL={np_val}",
            "",
            f"Batch wall time (all {concurrency} requests): **{sc['batch_wall_s']:.1f}s**",
            "",
        ]
        if sc["load_samples"]:
            loads = [s["load1"] for s in sc["load_samples"]]
            mems = [s["mem_available_mb"] for s in sc["load_samples"] if s["mem_available_mb"] is not None]
            lines.append(
                f"Host load1 during batch: avg {sum(loads)/len(loads):.1f}, peak {max(loads):.1f} · "
                f"mem available: min {min(mems) if mems else 'n/a'}MB, "
                f"max {max(mems) if mems else 'n/a'}MB"
            )
            lines.append("")

        model_col = "| Model " if multi else ""
        model_sep = "|---" if multi else ""
        lines.append(f"| # {model_col}| TTFT (s) | Total (s) | Gen tokens | Tool called | Finish reason |")
        lines.append(f"|---{model_sep}|---|---|---|---|---|")
        for r in sorted(ok, key=lambda x: x["idx"]):
            gen_tok = r["usage"].get("completion_tokens", "n/a") if r.get("usage") else "n/a"
            model_cell = f"| `{r['model']}` " if multi else ""
            lines.append(
                f"| {r['idx']} {model_cell}| {r['ttft_s']:.2f} | {r['total_s']:.2f} | {gen_tok} | "
                f"{r['tool_called']} | {r['finish_reason']} |"
            )
        for r in errs:
            model_cell = f"| `{r['model']}` " if multi else ""
            lines.append(f"| {r['idx']} {model_cell}| ERROR | ERROR | - | - | {r['error']} |")
        lines.append("")

        if ok:
            ttfts = [r["ttft_s"] for r in ok if r["ttft_s"] is not None]
            totals = [r["total_s"] for r in ok]
            if ttfts:
                lines.append(f"Avg TTFT: {sum(ttfts)/len(ttfts):.2f}s · Avg total: {sum(totals)/len(totals):.2f}s · "
                              f"Max total: {max(totals):.2f}s")
                lines.append("")
            if multi:
                for m in models:
                    m_totals = [r["total_s"] for r in ok if r["model"] == m]
                    if m_totals:
                        lines.append(f"  - `{m}`: {len(m_totals)} request(s), avg total {sum(m_totals)/len(m_totals):.2f}s")
                lines.append("")

    lines.append("## Full transcripts")
    lines.append("")
    for sc in scenarios:
        lines.append(f"### NUM_PARALLEL={sc['num_parallel']}")
        for r in sorted(sc["results"], key=lambda x: x["idx"]):
            model_note = f" (`{r['model']}`)" if multi else ""
            lines.append(f"\n**Request {r['idx']}**{model_note} — prompt: _{r['prompt']}_\n")
            if r.get("error"):
                lines.append(f"ERROR: {r['error']}\n")
            else:
                lines.append(f"```\n{r['text']}\n```\n")

    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default="phi4:14b-q8_0")
    ap.add_argument("--models", default="",
                     help="Comma list of models to distribute requests round-robin across "
                          "(overrides --model; use for a multi-model concurrency test)")
    ap.add_argument("--num-parallel-values", default="1,3")
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--max-tokens", type=int, default=400)
    ap.add_argument("--prompts-file")
    ap.add_argument("--prompt-template", default="Describe {topic}, brief, high level and common uses.")
    ap.add_argument("--prompt-topics", default="")
    ap.add_argument("--with-tools", action="store_true")
    ap.add_argument("--results-dir", default=os.path.join(PROJECT_ROOT, "bench-results"))
    ap.add_argument("--litellm-url", default=os.environ.get("LITELLM_URL", "http://localhost:9000"))
    args = ap.parse_args()

    if args.prompts_file:
        with open(args.prompts_file) as f:
            prompts = [l.strip() for l in f if l.strip()]
    elif args.prompt_topics:
        topics = [t.strip() for t in args.prompt_topics.split(",")]
        prompts = [args.prompt_template.format(topic=t) for t in topics]
    else:
        prompts = DEFAULT_PROMPTS

    models = [m.strip() for m in args.models.split(",") if m.strip()] or [args.model]

    master_key = _read_secret("litellm_master_key")
    if not master_key:
        print("ERROR: litellm_master_key not available", file=sys.stderr)
        sys.exit(1)
    headers = {"Authorization": f"Bearer {master_key}", "Content-Type": "application/json"}

    tools_by_model = {m: None for m in models}
    if args.with_tools:
        info = httpx.get(f"{args.litellm_url}/model/info", headers=headers, timeout=15.0).json()
        tags_by_model = {e.get("model_name"): e.get("model_info", {}).get("tags", []) for e in info.get("data", [])}
        for m in models:
            if "tools" in tags_by_model.get(m, []):
                tools_by_model[m] = STUB_TOOL
            else:
                print(f"NOTE: '{m}' not tagged 'tools' in LiteLLM — skipping --with-tools for it.", file=sys.stderr)

    requested_values = [int(v) for v in args.num_parallel_values.split(",")]
    original_env = _live_ollama_env()
    original_num_parallel = int(original_env.get("OLLAMA_NUM_PARALLEL", "1"))
    original_max_loaded = int(original_env.get("OLLAMA_MAX_LOADED_MODELS", "2"))
    # If this scenario run needs to switch settings, pin MAX_LOADED_MODELS to at
    # least as many as the distinct models actually being exercised, not a flat
    # 1 -- a single-model scenario still gets the tightest safe pin, a
    # multi-model distributed one needs all of them resident simultaneously.
    scenario_max_loaded = max(len(set(models)), 1)

    scenarios = []
    changed_env = False
    try:
        for np_val in requested_values:
            live = _live_ollama_env()
            if np_val != int(live.get("OLLAMA_NUM_PARALLEL", "1")) or scenario_max_loaded > int(live.get("OLLAMA_MAX_LOADED_MODELS", "2")):
                print(f"Switching OLLAMA_NUM_PARALLEL -> {np_val} "
                      f"(pinning MAX_LOADED_MODELS={scenario_max_loaded} for this scenario) ...", file=sys.stderr)
                set_ollama_env(num_parallel=np_val, max_loaded_models=scenario_max_loaded)
                changed_env = True
            scenarios.append(
                run_scenario(np_val, models, prompts, args.max_tokens, tools_by_model,
                             args.litellm_url, headers, args.concurrency)
            )
    finally:
        if changed_env:
            print(f"Restoring OLLAMA_NUM_PARALLEL={original_num_parallel}, "
                  f"OLLAMA_MAX_LOADED_MODELS={original_max_loaded} ...", file=sys.stderr)
            set_ollama_env(num_parallel=original_num_parallel, max_loaded_models=original_max_loaded)

    report = render_report(models, args.max_tokens, args.concurrency, scenarios)
    os.makedirs(args.results_dir, exist_ok=True)
    safe_model = "_".join(m.replace("/", "_").replace(":", "_") for m in models)
    out_path = os.path.join(args.results_dir, f"{datetime.now():%Y%m%d-%H%M%S}_{safe_model}_parallel-load.md")
    with open(out_path, "w") as f:
        f.write(report)

    print(report)
    print(f"\nWritten: {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
