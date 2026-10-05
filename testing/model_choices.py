# testing/model_choices.py
#
# Loader for testing/models.json -- the one place the test suite's model
# choices live. Every layer imports this instead of reading node files,
# configs/models.json or hard-coded names. (testing/ is not a package, so
# pytest puts it on sys.path and `import model_choices` works from any layer.)

import json
import os

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(_THIS_DIR)
CHOICES_FILE = os.path.join(_THIS_DIR, "models.json")
ROUTES_FILE = os.path.join(PROJECT_ROOT, "configs", "models.json")


def load() -> dict:
    """The parsed testing/models.json, without its _comment keys."""
    with open(CHOICES_FILE) as f:
        data = json.load(f)
    return {k: v for k, v in data.items() if not k.startswith("_")}


def default_chat() -> str:
    """Model for general chat/reasoning tests; TEST_MODEL overrides."""
    return os.environ.get("TEST_MODEL") or load()["default_chat"]


def tool_calling() -> str:
    """Model for tool-calling tests; TEST_TOOL_MODEL overrides, null falls back to default_chat."""
    return os.environ.get("TEST_TOOL_MODEL") or load().get("tool_calling") or default_chat()


def worker_models(alias: str) -> list[str]:
    """Models a worker serves, first one used for routing; [] if not declared."""
    return list(load().get("workers", {}).get(alias, []))


def route_ids() -> set[str]:
    """LiteLLM route ids configured for the stack (configs/models.json)."""
    with open(ROUTES_FILE) as f:
        return {m["id"] for m in json.load(f).get("default_models", [])}
