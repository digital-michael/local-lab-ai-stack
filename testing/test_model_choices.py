# testing/test_model_choices.py
#
# Offline drift guard for testing/models.json (no services needed): every model
# the suite is told to use must still be a configured LiteLLM route, and every
# worker named must still be an active worker node. Fails loudly when models
# change elsewhere instead of letting tests skip or collapse silently.
#
# Run: pytest testing/test_model_choices.py -v

import glob
import json
import os

import model_choices

NODES_DIR = os.path.join(model_choices.PROJECT_ROOT, "configs", "nodes")


def _active_workers() -> dict[str, dict]:
    nodes = {}
    for nf in glob.glob(os.path.join(NODES_DIR, "*.json")):
        with open(nf) as f:
            n = json.load(f)
        if n.get("status") == "active" and n.get("profile") != "controller":
            nodes[n["alias"]] = n
    return nodes


def test_default_chat_is_a_configured_route():
    model = model_choices.load()["default_chat"]
    assert model in model_choices.route_ids(), (
        f"testing/models.json default_chat '{model}' is not a route in configs/models.json "
        f"({sorted(model_choices.route_ids())}) -- update testing/models.json"
    )


def test_tool_calling_is_a_configured_route_when_set():
    model = model_choices.load().get("tool_calling")
    if model is None:
        return  # falls back to default_chat, checked above
    assert model in model_choices.route_ids(), (
        f"testing/models.json tool_calling '{model}' is not a route in configs/models.json"
    )


def test_workers_are_active_worker_nodes_with_models():
    active = _active_workers()
    for alias, models in model_choices.load().get("workers", {}).items():
        assert alias in active, (
            f"testing/models.json names worker '{alias}', which is not an active worker in configs/nodes/ "
            f"(active: {sorted(active)})"
        )
        assert isinstance(models, list) and models and all(isinstance(m, str) and m for m in models), (
            f"testing/models.json workers['{alias}'] must be a non-empty list of model names"
        )


def test_env_overrides_win(monkeypatch):
    monkeypatch.setenv("TEST_MODEL", "override-chat")
    monkeypatch.setenv("TEST_TOOL_MODEL", "override-tools")
    assert model_choices.default_chat() == "override-chat"
    assert model_choices.tool_calling() == "override-tools"
    monkeypatch.delenv("TEST_TOOL_MODEL")
    if model_choices.load().get("tool_calling") is None:
        assert model_choices.tool_calling() == "override-chat"
