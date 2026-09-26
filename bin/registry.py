"""Reads services.yaml (committed registry) layered with services.local.yaml
(gitignored, personal overrides) — same idea as .env / .env.local.

Not a general YAML parser: both files keep a flat shape on purpose

    <service>:
      <field>: <value>
      keys:
        <VAR>: <peer>

so this stays a few regexes instead of a PyYAML dependency. This module is
the one place that knows the format; bin/svc-field, bin/svc-secret and
bin/gen-traefik all go through it.
"""
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent  # Laba/Traefik
BASE_FILE = ROOT / "services.yaml"
LOCAL_FILE = ROOT / "services.local.yaml"
SERVICES_DIR = ROOT.parent / "Services"  # every service repo: Laba/Services/<service>

# Top-level sections that are not services.
NON_SERVICE_SECTIONS = {"groups"}


def _read(path: pathlib.Path) -> str:
    return path.read_text() if path.exists() else ""


def _block(text: str, name: str) -> str | None:
    m = re.search(rf"^{re.escape(name)}:[ \t]*\n((?:[ \t]+.*\n?|[ \t]*#.*\n?|\n)*)", text, re.MULTILINE)
    return m.group(1) if m else None


def _clean(value: str) -> str:
    value = value.strip()
    if "#" in value:
        value = value.split("#", 1)[0].strip()
    if value in ("null", "~"):
        return ""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def _field(block: str, field: str) -> str | None:
    """None: the field is absent; "": present but empty/null."""
    m = re.search(rf"^[ \t]+{re.escape(field)}:[ \t]*(.*)$", block, re.MULTILINE)
    return _clean(m.group(1)) if m else None


def _names(text: str) -> list[str]:
    return [m.group(1) for m in re.finditer(r"^([A-Za-z0-9_-]+):[ \t]*(?:#.*)?$", text, re.MULTILINE)]


def services() -> list[str]:
    """Every service in services.yaml."""
    return [s for s in _names(_read(BASE_FILE)) if s not in NON_SERVICE_SECTIONS]


def local_services() -> list[str]:
    """Services listed in services.local.yaml: the default SERVICES."""
    return [s for s in _names(_read(LOCAL_FILE)) if s not in NON_SERVICE_SECTIONS]


def exists(service: str) -> bool:
    return _block(_read(BASE_FILE), service) is not None


def field(service: str, name: str) -> str:
    """The value from services.local.yaml if set there (even to empty), else from services.yaml."""
    local = _block(_read(LOCAL_FILE), service)
    if local is not None:
        value = _field(local, name)
        if value is not None:
            return value
    return _field(_block(_read(BASE_FILE), service) or "", name) or ""


def local_host(service: str) -> str:
    """Host for a browser (<service>.localhost unless overridden); <name>.local is its server-to-server twin."""
    return field(service, "local_host") or f"{service}.localhost"


def internal_host(service: str) -> str:
    return local_host(service).removesuffix(".localhost") + ".local"


def keys(service: str) -> dict[str, str]:
    """The service's `keys:` map: env var it declares -> the peer whose api_key it holds."""
    block = _block(_read(BASE_FILE), service) or ""
    m = re.search(r"^([ \t]+)keys:[ \t]*\n((?:\1[ \t]+.*\n?|\n)*)", block, re.MULTILINE)
    if not m:
        return {}
    return {
        k.group(1): _clean(k.group(2))
        for k in re.finditer(r"^[ \t]+([A-Za-z0-9_.-]+):[ \t]*(.*)$", m.group(2), re.MULTILINE)
    }


def group(name: str) -> list[str]:
    """Members of a `groups:` entry, [] if `name` is not a group."""
    local = _block(_read(LOCAL_FILE), "groups")
    value = _field(local, name) if local is not None else None
    if value is None:
        value = _field(_block(_read(BASE_FILE), "groups") or "", name) or ""
    return value.split()


def expand(tokens: list[str]) -> list[str]:
    """Tokens with groups (and `all`) expanded into services, de-duplicated, in order."""
    result: list[str] = []
    for token in tokens:
        names = services() if token == "all" else (group(token) or [token])
        for name in names:
            if name not in result:
                result.append(name)
    return result


def check() -> list[str]:
    """Problems: unknown group members, duplicate db_port / host."""
    problems: list[str] = []
    all_services = services()
    for name in sorted({s for s in all_services if all_services.count(s) > 1}):
        problems.append(f"service {name} is defined more than once")
    all_services = list(dict.fromkeys(all_services))
    for m in re.finditer(r"^[ \t]+([A-Za-z0-9_-]+):[ \t]*(.*)$", _block(_read(BASE_FILE), "groups") or "", re.MULTILINE):
        for member in _clean(m.group(2)).split():
            if member not in all_services:
                problems.append(f"group {m.group(1)}: unknown service {member}")
    for label, value_of in (("db_port", lambda s: field(s, "db_port")), ("host", local_host)):
        seen: dict[str, str] = {}
        for s in all_services:
            value = value_of(s)
            if not value:
                continue
            if value in seen:
                problems.append(f"duplicate {label} {value}: {seen[value]} and {s}")
            seen[value] = s
    return problems
