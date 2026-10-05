#!/usr/bin/env python3
"""Checks that every relative link in the project's Markdown documents resolves.

A link to a file must name a file that exists; a link to a heading (`file.md#heading` or `#heading`) must name a heading
that the target document has, by the rule GitHub uses to turn a heading into an anchor. Links to other sites are not
followed: whether they are up is not a property of this repository.

Usage: Scripts/check-markdown-links.py [FILE...]
Without arguments, every Markdown file of the repository outside build and dependency directories is checked.

Exit status: 0 when every link resolves, 1 when one does not.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXCLUDED_DIRECTORIES = {".build", ".git", ".artifacts", "node_modules"}
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "tel:")
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LINK = re.compile(r"(?<!!)\[(?:[^\]\\]|\\.)*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
INLINE_CODE = re.compile(r"`[^`]*`")


def markdown_files() -> list[Path]:
    return sorted(
        path
        for path in ROOT.rglob("*.md")
        if not EXCLUDED_DIRECTORIES.intersection(path.relative_to(ROOT).parts)
    )


def anchor_of(heading: str) -> str:
    """The anchor GitHub gives a heading: lowercase, punctuation removed, spaces turned into hyphens."""
    text = re.sub(r"`([^`]*)`", r"\1", heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
    return text.replace(" ", "-")


def lines_outside_fences(text: str):
    fenced = False
    for number, line in enumerate(text.splitlines(), start=1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield number, line


def anchors_of(path: Path, cache: dict[Path, set[str]]) -> set[str]:
    if path not in cache:
        seen: dict[str, int] = {}
        anchors: set[str] = set()
        for _, line in lines_outside_fences(path.read_text(encoding="utf-8")):
            match = HEADING.match(line)
            if not match:
                continue
            anchor = anchor_of(match.group(2))
            count = seen.get(anchor, 0)
            seen[anchor] = count + 1
            anchors.add(anchor if count == 0 else f"{anchor}-{count}")
        cache[path] = anchors
    return cache[path]


def check(path: Path, cache: dict[Path, set[str]]) -> list[str]:
    problems = []
    for number, line in lines_outside_fences(path.read_text(encoding="utf-8")):
        for target in LINK.findall(INLINE_CODE.sub("", line)):
            if target.startswith(EXTERNAL_PREFIXES):
                continue
            location, _, fragment = target.partition("#")
            destination = path if not location else (path.parent / location).resolve()
            where = f"{path.relative_to(ROOT)}:{number}"
            if not destination.exists():
                problems.append(f"{where}: {target} does not exist")
            elif fragment and destination.suffix == ".md" and fragment not in anchors_of(destination, cache):
                problems.append(f"{where}: {target} names a heading that {destination.relative_to(ROOT)} does not have")
    return problems


def main() -> int:
    files = [Path(argument).resolve() for argument in sys.argv[1:]] or markdown_files()
    cache: dict[Path, set[str]] = {}
    problems = [problem for path in files for problem in check(path, cache)]
    for problem in problems:
        print(problem)
    print(f"Checked {len(files)} documents: {'every link resolves' if not problems else f'{len(problems)} broken'}.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
