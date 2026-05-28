#!/usr/bin/env python3
"""Check local Markdown links and anchors.

External URLs are intentionally ignored so PR checks do not depend on network
availability or third-party auth. This catches broken repo-local docs links.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.parse
from pathlib import Path


LINK_RE = re.compile(r"!?\[[^\]]*]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
AUTOLINK_RE = re.compile(r"<((?:https?|mailto):[^>]+)>")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*#*$")


def is_external(link: str) -> bool:
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", link))


def github_slug(title: str) -> str:
    title = re.sub(r"<[^>]+>", "", title).strip().lower()
    title = re.sub(r"[`*_~]", "", title)
    title = title.replace("—", "--")
    title = re.sub(r"[^a-z0-9\s-]", "", title)
    return re.sub(r"\s+", "-", title.strip())


def markdown_anchors(path: Path) -> set[str]:
    seen: dict[str, int] = {}
    anchors: set[str] = set()
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return anchors

    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if not match:
            continue
        slug = github_slug(match.group(2))
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        if count:
            slug = f"{slug}-{count}"
        anchors.add(slug)
    return anchors


def iter_markdown_files(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            files.extend(
                sorted(
                    p
                    for p in path.rglob("*.md")
                    if ".ipynb_checkpoints" not in p.parts
                )
            )
        elif path.suffix == ".md":
            files.append(path)
    return sorted(dict.fromkeys(files))


def extract_links(text: str) -> list[str]:
    links = [match.group(1) for match in LINK_RE.finditer(text)]
    links.extend(match.group(1) for match in AUTOLINK_RE.finditer(text))
    return links


def check_file(path: Path, repo_root: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    base_dir = path.parent

    for link in extract_links(text):
        if is_external(link):
            continue

        link_path, _, fragment = link.partition("#")
        if link_path:
            decoded_path = urllib.parse.unquote(link_path)
            target = (base_dir / decoded_path).resolve()
        else:
            target = path.resolve()

        try:
            target.relative_to(repo_root)
        except ValueError:
            errors.append(f"{path}: link escapes repo: {link}")
            continue

        if not target.exists():
            errors.append(f"{path}: missing target: {link}")
            continue

        if fragment and target.suffix == ".md":
            anchors = markdown_anchors(target)
            if fragment not in anchors:
                errors.append(f"{path}: missing anchor #{fragment}: {link}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        default=["README.md", "docs", "wsl2", "dgx"],
        help="Markdown files or directories to check",
    )
    args = parser.parse_args()

    repo_root = Path(os.getcwd()).resolve()
    files = iter_markdown_files(args.paths)
    errors: list[str] = []

    for path in files:
        errors.extend(check_file(path, repo_root))

    if errors:
        for error in errors:
            print(f"::error::{error}")
        print(f"Found {len(errors)} broken local Markdown link(s).")
        return 1

    print(f"Checked {len(files)} Markdown file(s); local links OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
