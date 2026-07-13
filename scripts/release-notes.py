#!/usr/bin/env python3
"""Pull one version's section out of CHANGELOG.md, as Markdown and as HTML.

The Markdown becomes the GitHub Release body; the HTML is embedded directly in the appcast's
<description>, which is what Sparkle shows in the "a new version is available" dialog.

Embedded rather than a <sparkle:releaseNotesLink>: a link would make Tscribe fetch a second
host (github.com) inside its own web view. The whole privacy claim is that the appcast host
is the ONLY thing Tscribe ever talks to, so the notes travel in the feed itself.

The converter handles exactly the subset of Markdown this CHANGELOG actually uses — headings,
bullets (with continuation lines), bold, inline code, links. It is not a general Markdown
implementation and doesn't pretend to be.

Usage: release-notes.py --version 2.1.0 [--changelog CHANGELOG.md]
                        [--out-md release-notes.md] [--out-html release-notes.html]
"""
import argparse
import html
import re
import sys


def extract_section(changelog: str, version: str) -> str:
    """The lines under `## [<version>]` up to the next `## ` heading."""
    lines = changelog.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^##\s*\[?{re.escape(version)}\]?\b", line):
            start = i + 1
            break
    if start is None:
        return ""
    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    return "\n".join(lines[start:end]).strip()


def inline(text: str) -> str:
    """Escape, then re-introduce the inline markup we allow."""
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def to_html(md: str) -> str:
    out, in_list, para = [], False, []

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    def close_para():
        # The CHANGELOG hard-wraps prose, so consecutive plain lines are ONE paragraph.
        # Emitting a <p> per line would render as ragged one-line stanzas in Sparkle's dialog.
        if para:
            out.append(f"<p>{' '.join(para)}</p>")
            para.clear()

    for raw in md.splitlines():
        line = raw.rstrip()
        if not line.strip():
            close_para()
            close_list()
            continue
        if heading := re.match(r"^(#{3,6})\s+(.*)$", line):
            close_para()
            close_list()
            out.append(f"<h4>{inline(heading.group(2))}</h4>")
        elif bullet := re.match(r"^[-*]\s+(.*)$", line):
            close_para()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(bullet.group(1))}</li>")
        elif in_list and line.startswith(" "):
            # A wrapped bullet: fold it back into the item it belongs to.
            out[-1] = out[-1][: -len("</li>")] + " " + inline(line.strip()) + "</li>"
        else:
            close_list()
            para.append(inline(line.strip()))
    close_para()
    close_list()
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--changelog", default="CHANGELOG.md")
    ap.add_argument("--out-md", default="release-notes.md")
    ap.add_argument("--out-html", default="release-notes.html")
    args = ap.parse_args()

    with open(args.changelog, encoding="utf-8") as f:
        section = extract_section(f.read(), args.version)

    if not section:
        # Not fatal: a release can legitimately precede its CHANGELOG entry, and refusing to
        # ship over it would be worse than shipping a generic note. But say so loudly, because
        # it is nearly always an oversight.
        print(f"WARNING: no '## [{args.version}]' section in {args.changelog}", file=sys.stderr)
        section = f"See the full changelog for what changed in {args.version}."

    with open(args.out_md, "w", encoding="utf-8") as f:
        f.write(section + "\n")
    with open(args.out_html, "w", encoding="utf-8") as f:
        f.write(to_html(section) + "\n")

    print(f"Release notes for {args.version}: {len(section)} chars of Markdown -> {args.out_html}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
