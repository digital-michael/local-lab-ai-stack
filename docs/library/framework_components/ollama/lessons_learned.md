# ollama — Lessons Learned
**Last Updated:** 2026-10-01

## Purpose
Empirical findings from operating ollama as the local CPU inference engine in the ai-stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Every Model Silently Ran at Ollama's 4096-Token Default Context, Regardless of Native Capacity](#1-every-model-silently-ran-at-ollamas-4096-token-default-context-regardless-of-native-capacity)
2. [`/api/ps`'s "digest" Field Is the Manifest's Digest, Not the Weights-Blob Digest a Runner Process Actually Uses](#2-apips-digest-field-is-the-manifests-digest-not-the-weights-blob-digest-a-runner-process-actually-uses)

---

# 1 Every Model Silently Ran at Ollama's 4096-Token Default Context, Regardless of Native Capacity

**Version:** Ollama 0.35.0, LiteLLM 1.x
**Discovered:** 2026-10-01, checking recently-added models' context size on a hunch

## What Happened

Suspected several recently-pulled models (`granite4.2:30b`, `qwen3.8:27b`, `llama3.3:latest`) were defaulting to a 4k context window. Loaded `granite4.2:30b` via a plain, direct Ollama API call — deliberately bypassing LiteLLM entirely, to rule it out as the cause — and `GET /api/ps` reported:

```json
{"name": "granite4.2:30b", ..., "context_length": 4096}
```

despite that same model's own `/api/show` advertising a native `131072`. Checked every Ollama model in the stack the same way; all seven showed the identical 4096 ceiling regardless of native capacity, which ranged from 16384 up to 262144.

## Root Cause

Nothing anywhere set `num_ctx`:
- `OLLAMA_CONTEXT_LENGTH` was not set on the container (confirmed via `podman exec ollama env`).
- None of the models' own Modelfiles had a `PARAMETER num_ctx` baked in (checked `/api/show`'s `parameters` field for each — present for other parameters like `temperature`/`stop`, absent for `num_ctx` on every one).
- LiteLLM's registered `litellm_params` hardcoded `max_tokens: 4096` for every model (`configure.sh`'s generator) — but `max_tokens` maps to Ollama's `num_predict` (max *output* tokens), a completely separate setting from the context window. Confirmed directly in LiteLLM's installed `litellm/llms/ollama/chat/transformation.py`: `num_ctx` is its own distinct `Optional[int]` parameter, defaulting to `None` unless explicitly passed.

With every one of those three potential sources absent, every request fell through to Ollama's own built-in server default (4096 in this version).

## Fix

`scripts/pull-models.sh` now computes and sets `num_ctx` automatically, per model, at registration time — from the same `/api/show` call already made for mode tagging, so it costs no extra HTTP round trip. A simple size-scaled heuristic from the model's own parameter count, deliberately not "max out to native": context window costs real RAM (KV cache) and CPU prompt-processing time, both of which scale with it directly, and these are all CPU-backed models where that's a real per-request latency cost, not just a one-time memory allocation.

```
<5B params   -> 32768
5B-50B       -> 16384
>50B         -> 8192
```

always capped at whatever the model's own `/api/show` reports as its native maximum. `configure.sh` passes through an explicit `num_ctx` on a model's `config.json` entry when one is set, which always wins over the heuristic — see `scripts/README.md`'s `pull-models.sh` entry and `output/CENTAURI-playbook.md` §13 L-39 for the full implementation.

Verified the fix actually takes effect through LiteLLM, not just in the stored config: sent a real `/chat/completions` request through LiteLLM for a model with no prior loaded state, and confirmed `/api/ps` afterward showed the new computed context size, not 4096.

## Rule

> Ollama's `num_ctx` is the only thing that controls context window size — never assume a LiteLLM-level `max_tokens` setting (or any other output-length knob) is doing that job too, even though both sound like they're about "how much the model can handle." Check behavior directly against `/api/ps` on a freshly loaded model when in doubt; a model's own advertised native capability (`/api/show`) says nothing about what it's actually configured to use at runtime.

---

# 2 `/api/ps`'s "digest" Field Is the Manifest's Digest, Not the Weights-Blob Digest a Runner Process Actually Uses

**Version:** Ollama (version at time of discovery not recorded; confirmed still true as of 0.35.0)
**Discovered:** building `scripts/loads.sh`'s per-model CPU attribution

## What Happened

Needed to attribute a loaded Ollama model's CPU% to its specific runner subprocess (visible via host `ps`, since podman doesn't hide container PIDs from the host's own `/proc` on Linux). The obvious approach — match `/api/ps`'s own `"digest"` field against the blob path a runner process was invoked with (`ollama runner --model /path/to/sha256-<digest>`) — never matched. Example confirmed directly against this stack's own manifests: `/api/ps` reported digest `ca06e9e4...9074`, but the actual running process was invoked with `--model .../sha256-30e51a7c...2ffb` — two different hashes entirely.

## Root Cause

The digest `/api/ps` (and `/api/tags`) reports is the digest of the model's **manifest** — the small JSON descriptor listing all of a model's layers (weights, license, template, system prompt, etc.) — not the digest of the weights blob itself, which is just one layer among several inside that manifest and has its own, different digest.

## Fix

Read the real weights-blob digest out of the manifest file Ollama itself writes to disk, at `$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/<namespace>/<model>/<tag>`, by finding the layer whose `mediaType` is `application/vnd.ollama.image.model` and taking its `digest` field. *That* digest matches the blob filename a runner subprocess was actually invoked with.

```python
def resolve_weights_digest(models_dir, name):
    repo, _, tag = name.partition(":")
    tag = tag or "latest"
    namespace, _, model = repo.rpartition("/")
    namespace = namespace or "library"
    manifest_path = f"{models_dir}/manifests/registry.ollama.ai/{namespace}/{model}/{tag}"
    manifest = json.load(open(manifest_path))
    for layer in manifest["layers"]:
        if layer["mediaType"] == "application/vnd.ollama.image.model":
            return layer["digest"].rsplit(":", 1)[-1].lower()
```

This logic now lives in both `scripts/loads.sh` (where it was first worked out) and `scripts/model-inventory.sh`'s `-cpu` flag (ported directly from `loads.sh`, cross-checked against its live output to confirm the port was correct — see `output/CENTAURI-playbook.md` §13 L-38).

## Rule

> Never assume an API's own "digest" field refers to the specific artifact you're trying to match against — a manifest-style resource (anything describing multiple layers/components) usually has its own digest distinct from any individual layer's. When digest-matching against a live process's command-line arguments, verify once against a real, running example before trusting the match logic at scale.
