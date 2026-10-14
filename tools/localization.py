"""Validate mod translations and expose the same catalogue to the Lua UI checks."""

from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import re
from typing import cast
from zipfile import ZipFile


Catalog = dict[str, dict[str, str]]
LOCALIZED_STRING = re.compile(r'_\("([^"\n]+)"\)')
PLACEHOLDER = re.compile(r"\{([a-zA-Z_][a-zA-Z_0-9]*)\}")
METADATA_FIELDS = ("name", "summary", "description")


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def load_object(path: Path) -> dict[str, object]:
    value: object = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected an object")
    return cast(dict[str, object], value)


def string_map(value: object, location: str) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValueError(f"{location}: expected an object")
    result: dict[str, str] = {}
    for key, text in value.items():
        if not isinstance(key, str) or not isinstance(text, str) or not text.strip():
            raise ValueError(f"{location}: invalid string {key!r}")
        if any(ord(char) < 32 and char != "\n" for char in text):
            raise ValueError(f"{location}:{key}: unexpected control character")
        result[key] = text
    return result


def placeholders(text: str) -> Counter[str]:
    literal = PLACEHOLDER.sub("", text)
    if "{" in literal or "}" in literal:
        raise ValueError(f"Invalid placeholder: {text}")
    return Counter(PLACEHOLDER.findall(text))


def check_localization(mod_root: Path, game_root: Path) -> Catalog:
    with ZipFile(game_root / "base/content/locale.zip") as archive:
        locales = {
            Path(name).name.removesuffix(".lang.lua")
            for name in archive.namelist() if name.endswith(".lang.lua")
        }
    raw = load_object(mod_root / "strings.json")
    if missing := locales - set(raw):
        raise ValueError(f"Missing game languages in the catalogue: {missing}")
    catalog = {locale: string_map(value, f"strings.json:{locale}") for locale, value in raw.items()}
    english = catalog["en"]
    references = {
        key for path in (mod_root / "content").rglob("*.tl")
        for key in LOCALIZED_STRING.findall(path.read_text(encoding="utf-8"))
    }
    if not references or references != set(english):
        raise ValueError(f"Referenced UI keys differ from English catalogue: {references ^ set(english)}")
    for locale, entries in catalog.items():
        if set(entries) != references:
            raise ValueError(f"{locale}: missing or extra UI keys: {set(entries) ^ references}")
        for key, text in entries.items():
            if not key.startswith("APASZ_NOTER_"):
                raise ValueError(f"{locale}: unscoped key {key}")
            if placeholders(text) != placeholders(english[key]):
                raise ValueError(f"{locale}:{key}: placeholder mismatch")

    metadata = load_object(mod_root / "_metadata/modinfo.json")
    localized = metadata.get("localization")
    if not isinstance(localized, dict) or set(localized) != set(catalog) - {"en"}:
        raise ValueError("Metadata translations must cover every non-English catalogue language")
    descriptions: dict[str, object] = {
        "en": {field: metadata[field] for field in METADATA_FIELDS}, **localized,
    }
    for locale, value in descriptions.items():
        entry = string_map(value, f"modinfo.json:{locale}")
        if set(entry) != set(METADATA_FIELDS):
            raise ValueError(f"modinfo.json:{locale}: expected name, summary and description")
        for field, limit in (("name", 32), ("summary", 100)):
            if len(entry[field]) > limit or "\n" in entry[field]:
                raise ValueError(f"modinfo.json:{locale}:{field}: exceeds the game's limits")
    print(f"Localisation: {len(catalog)} languages, {len(english)} UI strings each; metadata OK", flush=True)
    return catalog


def lua_catalog(catalog: Catalog) -> str:
    """Serialize validated strings using UTF-8 and Lua-compatible JSON string escapes."""

    def quote(text: str) -> str:
        return json.dumps(text, ensure_ascii=False)

    lines = ["return {"]
    for locale, entries in catalog.items():
        lines.append(f"[{quote(locale)}] = {{")
        lines.extend(f"[{quote(key)}] = {quote(text)}," for key, text in entries.items())
        lines.append("},")
    lines.append("}")
    return "\n".join(lines) + "\n"
