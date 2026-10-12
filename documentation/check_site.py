# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Check local links and assets in the exact static output uploaded to Pages."""

from html.parser import HTMLParser
from pathlib import Path
import sys
import tomllib
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, source: str) -> None:
        super().__init__()
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.feed(source)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if identity := values.get("id"):
            self.ids.add(identity)
        for name in ("href", "src", "poster"):
            if value := values.get(name):
                self.links.append(value)
        if sources := values.get("srcset"):
            self.links.extend(item.strip().split()[0] for item in sources.split(",") if item.strip())


def check(site: Path, base: str) -> list[str]:
    site = site.resolve()
    pages = {path.resolve(): Page(path.read_text()) for path in site.rglob("*.html")}
    errors: list[str] = []
    if site / "index.html" not in pages:
        errors.append("Missing homepage")
    for source, page in pages.items():
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            path = unquote(url.path)
            if path.startswith("/"):
                if not path.startswith(base):
                    errors.append(f"{source.relative_to(site)}: outside Pages base path: {link}")
                    continue
                target = site / path.removeprefix(base)
            else:
                target = source.parent / path if path else source
            target = target.resolve()
            if not target.is_relative_to(site):
                errors.append(f"{source.relative_to(site)}: escapes site: {link}")
                continue
            if target.is_dir():
                target /= "index.html"
            if not target.is_file():
                errors.append(f"{source.relative_to(site)}: missing target: {link}")
            elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
                errors.append(f"{source.relative_to(site)}: missing anchor: {link}")
    return errors


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    config = tomllib.loads((root / "zensical.toml").read_text())["project"]
    errors = check(root / config["site_dir"], urlsplit(config["site_url"]).path)
    if errors:
        sys.exit("\n".join(errors))
    print("Generated documentation links, anchors and assets passed.")
