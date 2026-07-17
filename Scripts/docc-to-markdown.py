#!/usr/bin/env python3
"""Generate a Markdown mirror of a DocC archive, plus an llms.txt index.

DocC renders as a JavaScript single-page app, so fetching a documentation URL
returns an empty shell rather than the page's content. Anything that reads the
site without executing JavaScript — an AI agent, curl, a plain HTTP client —
sees nothing useful.

The page content does exist in the archive as JSON under data/documentation/.
This script renders that JSON to Markdown and writes each page beside its HTML
counterpart with a .md suffix, so the agent-readable form of

    /CrescendoKit/documentation/crescendo/crescendoplayer

is

    /CrescendoKit/documentation/crescendo/crescendoplayer.md

An llms.txt index of every page is written to the archive root.

Usage: docc-to-markdown.py <archive-dir> --base-path /CrescendoKit [--version v1.1.1]
"""

import argparse
import glob
import json
import os
import sys

# Every block and inline type DocC emits that we render. Anything not listed
# falls back to recursing into its content, so unknown types degrade to their
# text rather than vanishing.
INLINE_WRAPPERS = ("strong", "emphasis", "strikethrough")


class Renderer:
    def __init__(self, base_path):
        self.base = base_path.rstrip("/")

    def md_url(self, url):
        """Map a DocC page URL to its Markdown twin."""
        return f"{self.base}{url}.md" if url else ""

    def inline(self, items, refs):
        out = []
        for i in items or []:
            t = i.get("type")
            if t == "text":
                out.append(i.get("text", ""))
            elif t == "codeVoice":
                out.append(f"`{i.get('code', '')}`")
            elif t == "strong":
                out.append(f"**{self.inline(i.get('inlineContent'), refs)}**")
            elif t == "emphasis":
                out.append(f"*{self.inline(i.get('inlineContent'), refs)}*")
            elif t == "strikethrough":
                out.append(f"~~{self.inline(i.get('inlineContent'), refs)}~~")
            elif t == "reference":
                out.append(self.reference(i, refs))
            elif t == "image":
                out.append(f"(image: {i.get('identifier', '')})")
            elif i.get("inlineContent"):
                out.append(self.inline(i["inlineContent"], refs))
        return "".join(out)

    def reference(self, node, refs):
        ident = node.get("identifier", "")
        ref = refs.get(ident) or {}
        title = ref.get("title") or ident.rsplit("/", 1)[-1]
        url = ref.get("url") or ""
        if not url:
            return f"`{title}`"
        # External links (kind "link") already carry an absolute URL; symbol
        # references carry a site-relative path that has a Markdown twin.
        if ref.get("type") == "link" or url.startswith(("http://", "https://")):
            return f"[{title}]({url})"
        return f"[{title}]({self.md_url(url)})"

    def blocks(self, nodes, refs):
        out = []
        for b in nodes or []:
            t = b.get("type")
            if t == "paragraph":
                out.append(self.inline(b.get("inlineContent"), refs))
            elif t == "heading":
                level = min(b.get("level", 2) + 1, 6)
                out.append(f"{'#' * level} {b.get('text', '')}")
            elif t == "codeListing":
                code = "\n".join(b.get("code") or [])
                out.append(f"```{b.get('syntax') or 'swift'}\n{code}\n```")
            elif t == "aside":
                out.append(self.aside(b, refs))
            elif t in ("unorderedList", "orderedList"):
                out.append(self.list_block(b, t, refs))
            elif t == "termList":
                for item in b.get("items") or []:
                    term = self.inline((item.get("term") or {}).get("inlineContent"), refs)
                    body = self.blocks((item.get("definition") or {}).get("content"), refs)
                    out.append(f"- **{term}** — {body}")
            elif b.get("content"):
                out.append(self.blocks(b["content"], refs))
        return "\n\n".join(x for x in out if x)

    def aside(self, node, refs):
        style = (node.get("style") or node.get("name") or "note").capitalize()
        inner = self.blocks(node.get("content"), refs)
        quoted = "\n".join(f"> {ln}" if ln else ">" for ln in inner.split("\n"))
        return f"> **{style}**\n{quoted}"

    def list_block(self, node, kind, refs):
        lines = []
        for n, item in enumerate(node.get("items") or [], 1):
            marker = "-" if kind == "unorderedList" else f"{n}."
            inner = self.blocks(item.get("content"), refs)
            first, *rest = inner.split("\n")
            lines.append(f"{marker} {first}")
            lines.extend(f"  {r}" for r in rest)
        return "\n".join(lines)

    def page(self, doc):
        """Render one page. Returns (url_path, title, abstract, markdown)."""
        refs = doc.get("references") or {}
        meta = doc.get("metadata") or {}
        title = meta.get("title", "Untitled")
        identifier = (doc.get("identifier") or {}).get("url", "")
        if "/documentation/" not in identifier:
            return None
        # doc://bundle/documentation/Crescendo/Foo -> /documentation/crescendo/foo
        path = "/documentation/" + identifier.split("/documentation/", 1)[1].lower()

        body = [f"# {title}"]
        kind = meta.get("roleHeading") or meta.get("symbolKind")
        if kind:
            body.append(f"*{kind}*")
        abstract = self.inline(doc.get("abstract"), refs)
        if abstract:
            body.append(abstract)
        if doc.get("deprecationSummary"):
            body.append(f"> **Deprecated**\n> {self.inline(doc['deprecationSummary'], refs)}")
        body.append(f"**Canonical page:** {self.base}{path}")

        for section in doc.get("primaryContentSections") or []:
            body.extend(self.primary_section(section, refs))
        for section in doc.get("topicSections") or []:
            body.extend(self.topic_section(section, refs))
        for section in doc.get("relationshipsSections") or []:
            body.extend(self.relationship_section(section, refs))
        for section in doc.get("seeAlsoSections") or []:
            body.extend(self.topic_section(section, refs, default="See Also"))

        return path, title, abstract, "\n\n".join(body) + "\n"

    def primary_section(self, section, refs):
        kind = section.get("kind")
        if kind == "declarations":
            out = []
            for d in section.get("declarations") or []:
                tokens = "".join(t.get("text", "") for t in d.get("tokens") or [])
                out.append("## Declaration")
                out.append(f"```swift\n{tokens}\n```")
                platforms = ", ".join(d.get("platforms") or [])
                if platforms:
                    out.append(f"Available on: {platforms}")
            return out
        if kind == "parameters":
            out = ["## Parameters"]
            for p in section.get("parameters") or []:
                desc = " ".join(self.blocks(p.get("content"), refs).split())
                out.append(f"- `{p.get('name', '')}` — {desc}")
            return out
        if kind == "content":
            body = self.blocks(section.get("content"), refs)
            return [body] if body else []
        return []

    def topic_section(self, section, refs, default="Topics"):
        out = [f"## {section.get('title') or default}"]
        for ident in section.get("identifiers") or []:
            ref = refs.get(ident) or {}
            title = ref.get("title") or ident.rsplit("/", 1)[-1]
            url = self.md_url(ref.get("url", ""))
            abstract = self.inline(ref.get("abstract"), refs)
            entry = f"- [{title}]({url})" if url else f"- {title}"
            out.append(entry + (f" — {abstract}" if abstract else ""))
        return out

    def relationship_section(self, section, refs):
        names = []
        for ident in section.get("identifiers") or []:
            ref = refs.get(ident) or {}
            title = ref.get("title") or ident.rsplit("/", 1)[-1]
            url = ref.get("url")
            names.append(f"[{title}]({self.md_url(url)})" if url else title)
        if not names:
            return []
        return [f"## {section.get('title') or 'Relationships'}", ", ".join(names)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archive", help="path to the .doccarchive directory")
    ap.add_argument("--base-path", required=True, help="site base path, e.g. /CrescendoKit")
    ap.add_argument("--version", default="", help="release tag, recorded in llms.txt")
    args = ap.parse_args()

    renderer = Renderer(args.base_path)
    pattern = os.path.join(args.archive, "data/documentation/**/*.json")
    pages = []

    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except (OSError, json.JSONDecodeError) as e:
            print(f"warning: skipping {path}: {e}", file=sys.stderr)
            continue
        rendered = renderer.page(doc) if doc.get("identifier") else None
        if not rendered:
            continue
        url_path, title, abstract, markdown = rendered
        out_file = os.path.join(args.archive, url_path.lstrip("/") + ".md")
        os.makedirs(os.path.dirname(out_file), exist_ok=True)
        with open(out_file, "w") as fh:
            fh.write(markdown)
        pages.append((url_path, title, abstract))

    if not pages:
        print("error: no documentation pages found in archive", file=sys.stderr)
        return 1

    pages.sort()
    base = renderer.base
    with open(os.path.join(args.archive, "llms.txt"), "w") as fh:
        fh.write("# Crescendo\n\n")
        fh.write("> API documentation for the Crescendo audio engine, distributed as CrescendoKit.\n\n")
        if args.version:
            fh.write(f"Version: {args.version}\n\n")
        fh.write(
            "Documentation renders as a JavaScript app, so every page also has a "
            "Markdown version at the same URL with a `.md` suffix.\n\n## Docs\n\n"
        )
        for url_path, title, abstract in pages:
            line = f"- [{title}]({base}{url_path}.md)"
            fh.write(line + (f": {abstract}" if abstract else "") + "\n")

    print(f"generated {len(pages)} markdown pages and llms.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
