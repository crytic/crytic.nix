#!/usr/bin/env python3
"""
Update tool pins in flake.nix to latest released tagged commits.

Default behavior:
- Resolve latest stable GitHub release tag for each configured tool.
- Resolve tag -> commit SHA.
- Update commitHash and version defaults in mk* blocks.
- Update nearby "latest ... from ..." comments to /releases URLs.

Usage:
  python scripts/update_tool_pins.py --check
  python scripts/update_tool_pins.py --apply
  python scripts/update_tool_pins.py --apply --tool mkMedusa --tool mkMewt
  python scripts/update_tool_pins.py --apply --verify
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


@dataclass
class ToolUpdate:
    tool: str
    repo: str
    tag: str
    commit: str
    version: Optional[str]
    old_commit: Optional[str]
    old_version: Optional[str]
    changed: bool
    reason: str = ""


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def gh_get_json(url: str) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "crytic-tool-pin-updater",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def normalize_version_from_tag(tag: str) -> str:
    # v1.2.3 -> 1.2.3, v.1.2.3 -> 1.2.3, 1.2.3 -> 1.2.3
    t = tag.strip()
    if t.startswith("v"):
        t = t[1:]
    if t.startswith("."):
        t = t[1:]
    return t


def parse_semver(tag: str) -> Optional[Tuple[int, int, int, str]]:
    t = normalize_version_from_tag(tag)
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(.*)$", t)
    if not m:
        return None
    major, minor, patch, rest = m.groups()
    return (int(major), int(minor), int(patch), rest)


def is_prerelease(tag: str) -> bool:
    parsed = parse_semver(tag)
    if not parsed:
        return True
    return parsed[3] != ""


def choose_latest_tag(tags: List[str], allow_prerelease: bool) -> Optional[str]:
    semver_tags: List[Tuple[Tuple[int, int, int, int, str], str]] = []
    for tag in tags:
        parsed = parse_semver(tag)
        if not parsed:
            continue
        if not allow_prerelease and is_prerelease(tag):
            continue
        major, minor, patch, rest = parsed
        stable_marker = 1 if rest == "" else 0
        semver_tags.append(((major, minor, patch, stable_marker, rest), tag))

    if not semver_tags:
        return None
    semver_tags.sort(key=lambda x: x[0])
    return semver_tags[-1][1]


def git_ls_remote_tags(repo_url: str) -> Dict[str, str]:
    out = subprocess.check_output(["git", "ls-remote", "--tags", repo_url], text=True)
    direct: Dict[str, str] = {}
    peeled: Dict[str, str] = {}

    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        sha, ref = line.split("\t", 1)
        if not ref.startswith("refs/tags/"):
            continue
        name = ref[len("refs/tags/") :]
        if name.endswith("^{}"):
            peeled[name[:-3]] = sha
        else:
            direct[name] = sha

    resolved: Dict[str, str] = {}
    for tag, sha in direct.items():
        resolved[tag] = peeled.get(tag, sha)
    return resolved


def resolve_latest_release(repo: str, allow_prerelease: bool, fallback_to_tags: bool) -> Tuple[str, str]:
    # First choice: GitHub latest release endpoint.
    try:
        rel = gh_get_json(f"https://api.github.com/repos/{repo}/releases/latest")
        tag = rel["tag_name"]
        commit_map = git_ls_remote_tags(f"https://github.com/{repo}.git")
        commit = commit_map.get(tag)
        if commit:
            if not allow_prerelease and is_prerelease(tag):
                raise RuntimeError(f"latest release tag is prerelease and prereleases disabled: {tag}")
            return tag, commit
    except (urllib.error.HTTPError, urllib.error.URLError, KeyError, RuntimeError):
        if not fallback_to_tags:
            raise

    # Fallback: find max semver tag via ls-remote.
    commit_map = git_ls_remote_tags(f"https://github.com/{repo}.git")
    tag = choose_latest_tag(list(commit_map.keys()), allow_prerelease)
    if not tag:
        raise RuntimeError(f"No suitable semver tag found for {repo}")
    return tag, commit_map[tag]


def find_mk_block_ranges(text: str) -> Dict[str, Tuple[int, int]]:
    # Finds mkX = { ... }: blocks by line scanning.
    lines = text.splitlines(keepends=True)
    ranges: Dict[str, Tuple[int, int]] = {}

    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)(mk[A-Za-z0-9_-]+)\s*=\s*\{\s*$", lines[i])
        if not m:
            i += 1
            continue
        name = m.group(2)
        start = i
        j = i + 1
        while j < len(lines):
            if re.match(r"^\s*\}:\s*", lines[j]):
                end = j
                ranges[name] = (start, end)
                break
            j += 1
        i = j + 1

    return ranges


def update_block(block: str, release_url: str, commit: str, version: Optional[str], update_version: bool) -> Tuple[str, Optional[str], Optional[str], bool]:
    old_commit = None
    old_version = None

    m_commit = re.search(r'commitHash\s*\?\s*"([^"]+)"', block)
    if m_commit:
        old_commit = m_commit.group(1)

    m_version = re.search(r'version\s*\?\s*"([^"]+)"', block)
    if m_version:
        old_version = m_version.group(1)

    new_block = block

    # Comments first.
    new_block = re.sub(
        r'^(\s*#\s*)latest\s+commit\s+from\s+\S+\s*$',
        rf'\1latest release tag from {release_url}',
        new_block,
        flags=re.MULTILINE,
    )
    new_block = re.sub(
        r'^(\s*#\s*)latest\s+version\s+from\s+\S+\s*$',
        rf'\1latest version from {release_url}',
        new_block,
        flags=re.MULTILINE,
    )

    # commitHash update (required for pin update jobs).
    new_block = re.sub(
        r'(commitHash\s*\?\s*")([^"]+)(")',
        rf'\g<1>{commit}\g<3>',
        new_block,
        count=1,
    )

    # version update where requested and present.
    if update_version and version is not None:
        new_block = re.sub(
            r'(version\s*\?\s*")([^"]+)(")',
            rf'\g<1>{version}\g<3>',
            new_block,
            count=1,
        )

    changed = new_block != block
    return new_block, old_commit, old_version, changed


def run_cmd(cmd: List[str]) -> int:
    print("+", " ".join(cmd))
    p = subprocess.run(cmd)
    return p.returncode


def main() -> int:
    ap = argparse.ArgumentParser(description="Update flake tool pins to latest release tags")
    ap.add_argument("--flake", default="flake.nix", help="Path to flake.nix")
    ap.add_argument("--config", default="scripts/tool-pins.json", help="Path to tool pin config")
    ap.add_argument("--tool", action="append", default=[], help="Only update selected mk* tool(s)")
    ap.add_argument("--check", action="store_true", help="Dry-run; show what would change")
    ap.add_argument("--apply", action="store_true", help="Write changes to flake file")
    ap.add_argument("--verify", action="store_true", help="Run basic verification commands after apply")
    ap.add_argument(
        "--verify-cmd",
        action="append",
        default=[],
        help="Additional shell command(s) to run after apply (e.g. 'nix build .#medusa --no-link')",
    )
    args = ap.parse_args()

    if args.check and args.apply:
        print("error: choose only one of --check or --apply", file=sys.stderr)
        return 2
    if not args.check and not args.apply:
        args.check = True

    flake_path = Path(args.flake)
    cfg_path = Path(args.config)

    if not flake_path.exists():
        print(f"error: flake file not found: {flake_path}", file=sys.stderr)
        return 2
    if not cfg_path.exists():
        print(f"error: config file not found: {cfg_path}", file=sys.stderr)
        return 2

    config = load_config(cfg_path)
    defaults = config.get("defaults", {})
    tools_cfg = config.get("tools", {})

    flake_text = flake_path.read_text(encoding="utf-8")
    ranges = find_mk_block_ranges(flake_text)

    selected = set(args.tool) if args.tool else set(tools_cfg.keys())

    updated_text = flake_text
    updates: List[ToolUpdate] = []
    failures: List[Tuple[str, str]] = []

    # To keep indices stable, apply replacements from bottom to top.
    targets: List[Tuple[str, int, int, dict]] = []
    for tool_name, tcfg in tools_cfg.items():
        if tool_name not in selected:
            continue
        if tool_name not in ranges:
            failures.append((tool_name, "mk block not found in flake.nix"))
            continue
        start_line, end_line = ranges[tool_name]

        # Convert line ranges to character slices.
        lines = updated_text.splitlines(keepends=True)
        start_char = sum(len(x) for x in lines[:start_line])
        end_char = sum(len(x) for x in lines[: end_line + 1])
        targets.append((tool_name, start_char, end_char, tcfg))

    targets.sort(key=lambda x: x[1], reverse=True)

    for tool_name, start_char, end_char, tcfg in targets:
        repo = tcfg["repo"]
        allow_prerelease = bool(tcfg.get("allow_prerelease", defaults.get("allow_prerelease", False)))
        update_version = bool(tcfg.get("update_version", defaults.get("update_version", True)))
        fallback_to_tags = bool(tcfg.get("fallback_to_tags", defaults.get("fallback_to_tags", True)))

        try:
            tag, commit = resolve_latest_release(repo, allow_prerelease, fallback_to_tags)
        except Exception as e:
            failures.append((tool_name, f"failed to resolve latest release: {e}"))
            continue

        version = normalize_version_from_tag(tag) if update_version else None
        release_url = f"https://github.com/{repo}/releases"

        block = updated_text[start_char:end_char]
        new_block, old_commit, old_version, changed = update_block(
            block=block,
            release_url=release_url,
            commit=commit,
            version=version,
            update_version=update_version,
        )

        if changed:
            updated_text = updated_text[:start_char] + new_block + updated_text[end_char:]

        updates.append(
            ToolUpdate(
                tool=tool_name,
                repo=repo,
                tag=tag,
                commit=commit,
                version=version,
                old_commit=old_commit,
                old_version=old_version,
                changed=changed,
            )
        )

    print("\nPlanned updates:")
    for u in sorted(updates, key=lambda x: x.tool):
        changed_flag = "CHANGED" if u.changed else "no-op"
        print(f"- {u.tool} ({u.repo}) [{changed_flag}]")
        print(f"  tag:    {u.tag}")
        if u.old_commit:
            print(f"  commit: {u.old_commit} -> {u.commit}")
        else:
            print(f"  commit: (not found in block) -> {u.commit}")
        if u.version is not None:
            if u.old_version:
                print(f"  version:{u.old_version} -> {u.version}")
            else:
                print(f"  version:(not found in block) -> {u.version}")

    if failures:
        print("\nFailures:")
        for tool, err in failures:
            print(f"- {tool}: {err}")

    any_changes = updated_text != flake_text

    if args.check:
        print("\nMode: check (dry-run)")
        if any_changes:
            print("Result: changes would be applied.")
            return 1 if failures else 0
        print("Result: no changes.")
        return 1 if failures else 0

    if args.apply:
        if any_changes:
            flake_path.write_text(updated_text, encoding="utf-8")
            print(f"\nWrote updates to {flake_path}")
        else:
            print("\nNo file changes needed.")

        if args.verify:
            # Sane default verification.
            rc = run_cmd(["nix", "flake", "show", "--no-write-lock-file"])
            if rc != 0:
                print("verification failed: nix flake show", file=sys.stderr)
                return rc

        for cmd in args.verify_cmd:
            rc = subprocess.run(cmd, shell=True).returncode
            if rc != 0:
                print(f"verification command failed: {cmd}", file=sys.stderr)
                return rc

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
