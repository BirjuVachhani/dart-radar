#!/usr/bin/env python3
"""Build the Sparkle appcast feed for one release.

    scripts/make-appcast.py --dmg <file> --version 1.2.0 --build 11 \
        --key secrets/sparkle_ed25519_private_key \
        --sign-update build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
        --download-url https://artifacts.birju.dev/dartradar/DartRadar.dmg \
        --feed-url https://artifacts.birju.dev/dartradar/appcast.xml \
        --output artifacts/appcast.xml

Signs the DMG with the Ed25519 key whose public half is `SUPublicEDKey` in
DartRadar/Info.plist, turns the CHANGELOG.md section for the version into
the item's release notes, and writes the feed.

The existing feed is fetched from --feed-url first and the new item is merged
into it, so older releases keep their notes and a re-run of the same version
replaces its own item instead of appending a duplicate. A feed that cannot be
fetched (first ever release, bucket unreachable) is not an error: the result is
then a single-item feed, which Sparkle reads perfectly well. Pass --no-merge to
force that.

Exits non-zero when the DMG or the signing key is missing, or when signing
fails. A feed advertising an unsigned or wrongly signed build is worse than no
feed at all, because every client rejects it and the release looks broken
rather than absent.
"""

from __future__ import annotations

import argparse
import html
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import xml.sax
from io import BytesIO
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

REPO_ROOT = Path(__file__).resolve().parent.parent

#: How many past releases the feed keeps. Sparkle only ever needs the newest
#: applicable item, so this is purely about how far back "what changed" reaches
#: for someone who skipped a few versions.
MAX_ITEMS = 12


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------------
# Release notes
# --------------------------------------------------------------------------


def changelog_section(version: str, changelog: Path) -> str:
    """The CHANGELOG.md body for `version`, or "" when it has no section.

    Delegates to scripts/changelog-section.sh rather than re-parsing the file,
    so the notes in the appcast are byte-for-byte the ones `make release` puts
    on the GitHub release.
    """
    script = REPO_ROOT / "scripts" / "changelog-section.sh"
    if not script.exists():
        return ""
    result = subprocess.run(
        [str(script), version, str(changelog)],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def changelog_date(version: str, changelog: Path) -> datetime | None:
    """The date on the version's `## 1.2.0 - 2026-09-05` heading, if it has one.

    Used as the item's pubDate so re-running this script does not keep moving a
    published release's date around.
    """
    if not changelog.exists():
        return None
    pattern = re.compile(
        r"^##\s+" + re.escape(version) + r"\s*[-–—]\s*(\d{4})-(\d{2})-(\d{2})"
    )
    for line in changelog.read_text().splitlines():
        match = pattern.match(line)
        if match:
            year, month, day = (int(part) for part in match.groups())
            return datetime(year, month, day, tzinfo=timezone.utc)
    return None


_INLINE = (
    # Ordered: the link pattern has to run before the code one, or a URL
    # containing backticks would be mangled. Bold before italics for the same
    # reason ** would otherwise be read as two * markers.
    (re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)"), r'<a href="\2">\1</a>'),
    (re.compile(r"`([^`]+)`"), r"<code>\1</code>"),
    (re.compile(r"\*\*([^*]+)\*\*"), r"<strong>\1</strong>"),
)


def _inline(text: str) -> str:
    """Escape one line of Markdown and expand the inline spans Sparkle shows."""
    out = html.escape(text, quote=False)
    for pattern, replacement in _INLINE:
        out = pattern.sub(replacement, out)
    return out


def markdown_to_html(markdown: str) -> str:
    """A deliberately small Markdown subset -> HTML, for Sparkle's notes pane.

    Covers exactly what CHANGELOG.md uses: `###` subheadings, `-`/`*` bullet
    lists whose items wrap across lines, paragraphs, and inline code, bold and
    links. Anything else passes through as escaped text rather than being
    dropped, so an unusual entry is still readable.
    """
    lines = markdown.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    bullets: list[str] = []  # accumulated <li> bodies for the open list
    paragraph: list[str] = []  # accumulated lines of the open paragraph

    def flush_list() -> None:
        if not bullets:
            return
        out.append("<ul>")
        out.extend(f"<li>{_inline(item)}</li>" for item in bullets)
        out.append("</ul>")
        bullets.clear()

    def flush_paragraph() -> None:
        if not paragraph:
            return
        out.append(f"<p>{_inline(' '.join(paragraph))}</p>")
        paragraph.clear()

    for line in lines:
        stripped = line.strip()

        if not stripped:
            flush_paragraph()
            flush_list()
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush_paragraph()
            flush_list()
            # Shift down two levels: a `###` subheading inside one release's
            # notes is not a document heading, and Sparkle's pane is small.
            level = min(len(heading.group(1)) + 2, 6)
            out.append(f"<h{level}>{_inline(heading.group(2))}</h{level}>")
            continue

        bullet = re.match(r"^[-*]\s+(.*)$", stripped)
        if bullet:
            flush_paragraph()
            bullets.append(bullet.group(1))
            continue

        # An indented line under a bullet continues it; CHANGELOG.md hard-wraps
        # its entries, so most bullets arrive in several pieces.
        if bullets and line.startswith((" ", "\t")):
            bullets[-1] = f"{bullets[-1]} {stripped}"
            continue

        flush_list()
        paragraph.append(stripped)

    flush_paragraph()
    flush_list()
    return "\n".join(out)


# --------------------------------------------------------------------------
# Signing
# --------------------------------------------------------------------------


def sign(dmg: Path, key: Path, sign_update: Path) -> tuple[str, int]:
    """Return (edSignature, length) for `dmg`, signed with `key`.

    `sign_update` comes from the Sparkle CocoaPod
    (build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update), which SPM
    has run for the macOS app.
    """
    if not sign_update.exists():
        fail(
            f"no sign_update at {sign_update}\n"
            "       It ships with the Sparkle pod. Run:\n"
            "           make build-app"
        )
    if not key.exists():
        fail(
            f"no Sparkle signing key at {key}\n"
            "       Every release has to be signed with the key whose public half is\n"
            "       SUPublicEDKey in DartRadar/Info.plist, or no installed copy\n"
            "       will accept the update. See config.mk.example."
        )

    result = subprocess.run(
        [str(sign_update), "--ed-key-file", str(key), str(dmg)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"sign_update failed:\n{result.stderr.strip()}")

    match = re.search(
        r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', result.stdout
    )
    if not match:
        fail(f"could not read a signature out of sign_update's output:\n{result.stdout}")
    return match.group(1), int(match.group(2))


# --------------------------------------------------------------------------
# Feed
# --------------------------------------------------------------------------


class _SafeTreeHandler(xml.sax.handler.ContentHandler):
    """Build an ElementTree while rejecting every DTD at parser level."""

    def __init__(self) -> None:
        super().__init__()
        self.builder = ET.TreeBuilder()

    @staticmethod
    def _name(name: tuple[str | None, str]) -> str:
        uri, local = name
        return f"{{{uri}}}{local}" if uri else local

    def startElementNS(self, name, qname, attrs):  # noqa: N802
        attributes = {self._name(key): value for key, value in attrs.items()}
        self.builder.start(self._name(name), attributes)

    def endElementNS(self, name, qname):  # noqa: N802
        self.builder.end(self._name(name))

    def characters(self, content: str) -> None:
        self.builder.data(content)

    def processingInstruction(self, target, data):  # noqa: N802
        raise xml.sax.SAXException("processing instructions are not allowed")

    # LexicalHandler callbacks. startDTD is the security boundary; the others
    # are required by Python's SAX adapter when this handler is installed.
    def startDTD(self, name, public_id, system_id):  # noqa: N802
        raise xml.sax.SAXException("DTDs are not allowed")

    def endDTD(self):  # noqa: N802
        pass

    def startEntity(self, name):  # noqa: N802
        raise xml.sax.SAXException("entities are not allowed")

    def endEntity(self, name):  # noqa: N802
        pass

    def startCDATA(self):  # noqa: N802
        pass

    def endCDATA(self):  # noqa: N802
        pass

    def comment(self, text: str) -> None:
        pass


def parse_safe_xml(body: bytes) -> ET.Element:
    """Parse externally fetched XML with DTD/entity/network access disabled."""
    parser = xml.sax.make_parser()
    parser.setFeature(xml.sax.handler.feature_namespaces, True)
    parser.setFeature(xml.sax.handler.feature_external_ges, False)
    try:
        parser.setFeature(xml.sax.handler.feature_external_pes, False)
    except xml.sax.SAXNotSupportedException:
        # Expat does not support external parameter entities. DTD rejection
        # below makes this irrelevant, but leave the secure intent explicit.
        pass
    handler = _SafeTreeHandler()
    parser.setContentHandler(handler)
    parser.setProperty(xml.sax.handler.property_lexical_handler, handler)
    parser.parse(BytesIO(body))
    return handler.builder.close()


def fetch_feed(url: str, timeout: float) -> ET.Element | None:
    """The <channel> of the currently published feed, or None if unavailable."""
    # A User-Agent is set because urllib's default ("Python-urllib/3.x") is
    # refused outright by the CDN in front of artifacts.birju.dev. That 403 is
    # caught below and reported as "no existing feed", which is indistinguishable
    # from a genuine first release, so without this the merge silently never
    # happens and every feed is written fresh.
    request = urllib.request.Request(url, headers={"User-Agent": "make-appcast.py"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            # A valid appcast is tiny. Bound the read so a compromised origin
            # cannot exhaust the release runner's memory before XML parsing.
            body = response.read(2 * 1024 * 1024 + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        print(f"  no existing feed to merge into ({error}); writing a fresh one.")
        return None
    if len(body) > 2 * 1024 * 1024:
        fail("published feed is larger than 2 MiB; refusing to parse it")
    try:
        channel = parse_safe_xml(body).find("channel")
    except (ET.ParseError, xml.sax.SAXException) as error:
        fail(f"published feed is not safe or parseable ({error})")
    if channel is None:
        print("  published feed has no <channel>; writing a fresh one.")
    return channel


def item_version(item: ET.Element) -> str | None:
    """An item's `sparkle:version` (the build number Sparkle compares)."""
    element = item.find(f"{{{SPARKLE_NS}}}version")
    if element is not None and element.text:
        return element.text.strip()
    # Pre-2.x feeds put it on the enclosure instead.
    enclosure = item.find("enclosure")
    if enclosure is not None:
        return enclosure.get(f"{{{SPARKLE_NS}}}version")
    return None


def item_short_version(item: ET.Element) -> str | None:
    """An item's marketing version (`sparkle:shortVersionString`)."""
    element = item.find(f"{{{SPARKLE_NS}}}shortVersionString")
    if element is not None and element.text:
        return element.text.strip()
    enclosure = item.find("enclosure")
    if enclosure is not None:
        return enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString")
    return None


def sort_key(item: ET.Element) -> tuple[int, float]:
    """Newest first: by build number, then by pubDate for ties."""
    version = item_version(item) or "0"
    numeric = int(version) if version.isdigit() else 0
    date = item.findtext("pubDate") or ""
    try:
        stamp = parsedate_to_datetime(date).timestamp()
    except (TypeError, ValueError):
        stamp = 0.0
    return (numeric, stamp)


def build_item(args: argparse.Namespace, signature: str, length: int) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{args.app_name} {args.version}"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(args.build)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    if args.minimum_system_version:
        ET.SubElement(
            item, f"{{{SPARKLE_NS}}}minimumSystemVersion"
        ).text = args.minimum_system_version

    published = changelog_date(args.version, args.changelog) or datetime.now(
        timezone.utc
    )
    ET.SubElement(item, "pubDate").text = format_datetime(published)

    notes = markdown_to_html(changelog_section(args.version, args.changelog))
    if notes:
        description = ET.SubElement(item, "description")
        # Kept as text and serialized inside CDATA below: Sparkle renders the
        # description as HTML, so the tags have to survive as markup.
        description.text = notes
    else:
        print(
            f"  WARNING: CHANGELOG.md has no '## {args.version}' section; "
            "the update will show no release notes."
        )

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.download_url)
    enclosure.set("length", str(length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", signature)
    return item


def serialize(channel_items: list[ET.Element], args: argparse.Namespace) -> str:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = f"{args.app_name} Updates"
    ET.SubElement(channel, "link").text = args.feed_url
    ET.SubElement(channel, "description").text = (
        f"Most recent {args.app_name} releases."
    )
    ET.SubElement(channel, "language").text = "en"
    for item in channel_items:
        channel.append(item)

    ET.indent(rss, space="    ")
    xml = ET.tostring(rss, encoding="unicode")

    # ElementTree escapes the release-notes markup on the way out, which would
    # leave Sparkle showing literal tags. Put each <description> back as CDATA.
    def uncdata(match: re.Match[str]) -> str:
        body = html.unescape(match.group(1))
        return f"<description><![CDATA[{body}]]></description>"

    xml = re.sub(
        r"<description>((?:(?!</description>).)*?&lt;.*?)</description>",
        uncdata,
        xml,
        flags=re.DOTALL,
    )
    return f'<?xml version="1.0" encoding="utf-8"?>\n{xml}\n'


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the Sparkle appcast feed for one release."
    )
    parser.add_argument("--dmg", required=True, type=Path, help="the built DMG")
    parser.add_argument("--version", required=True, help="marketing version, e.g. 1.2.0")
    parser.add_argument(
        "--build",
        required=True,
        help="build number (CFBundleVersion); this is what Sparkle compares",
    )
    parser.add_argument("--download-url", required=True, help="public URL of the DMG")
    parser.add_argument("--feed-url", required=True, help="public URL of appcast.xml")
    parser.add_argument("--output", required=True, type=Path, help="feed to write")
    parser.add_argument(
        "--key",
        type=Path,
        default=Path("secrets/sparkle_ed25519_private_key"),
        help="Ed25519 private key file (default: %(default)s)",
    )
    parser.add_argument(
        "--sign-update",
        type=Path,
        default=Path("build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"),
        help="Sparkle's sign_update tool (default: %(default)s)",
    )
    parser.add_argument(
        "--changelog",
        type=Path,
        default=Path("CHANGELOG.md"),
        help="release notes source (default: %(default)s)",
    )
    parser.add_argument("--app-name", default="Dart Radar")
    parser.add_argument(
        "--minimum-system-version",
        default="12.0",
        help="LSMinimumSystemVersion of the build (default: %(default)s)",
    )
    parser.add_argument(
        "--no-merge",
        action="store_true",
        help="write a single-item feed instead of merging into the published one",
    )
    parser.add_argument(
        "--fetch-timeout",
        type=float,
        default=15.0,
        help="seconds to wait for the published feed (default: %(default)s)",
    )
    args = parser.parse_args()

    if not args.dmg.is_file():
        fail(f"no DMG at {args.dmg}. Run 'make dmg' first.")
    if not str(args.build).isdigit():
        fail(
            f"build number '{args.build}' is not a plain integer.\n"
            "       Sparkle compares CFBundleVersion numerically, so it has to be one."
        )

    # Fetch and validate the published feed BEFORE spending work on release
    # notes or signing. A reused/non-monotonic build number is a release error,
    # not a signing error, and should fail without producing a plausible-looking
    # new signature that someone may copy elsewhere.
    channel = None
    published: list[ET.Element] = []
    same_build: list[ET.Element] = []
    kept: list[ET.Element] = []
    if not args.no_merge:
        print(f"Merging into {args.feed_url} ...")
        channel = fetch_feed(args.feed_url, args.fetch_timeout)
        if channel is not None:
            published = channel.findall("item")
            same_build = [
                item for item in published if item_version(item) == str(args.build)
            ]
            conflicting = [
                item
                for item in same_build
                if item_short_version(item) not in (None, args.version)
            ]
            if conflicting:
                old_version = item_short_version(conflicting[0]) or "unknown"
                fail(
                    f"build {args.build} is already published as {old_version}, "
                    f"not {args.version}.\n"
                    "       Sparkle compares build numbers, so reusing '+N' would make "
                    "the new release invisible to everyone on that build. Bump the "
                    "build number in project.yml."
                )
            highest = max((sort_key(item)[0] for item in published), default=0)
            if int(args.build) < highest:
                fail(
                    f"build {args.build} is not the highest in the feed "
                    f"(that is {highest}).\n"
                    "       Sparkle compares build numbers, so this release would not "
                    "be offered. Bump CURRENT_PROJECT_VERSION in project.yml."
                )
            kept = [
                item for item in published if item_version(item) != str(args.build)
            ]

    print(f"Signing {args.dmg.name} with {args.key} ...")
    signature, length = sign(args.dmg, args.key, args.sign_update)
    print(f"  edSignature ok, length {length} bytes")

    items = [build_item(args, signature, length)]
    if same_build:
        print(
            f"  replacing {len(same_build)} existing item(s) for "
            f"{args.version} build {args.build}"
        )
    items.extend(kept)

    items.sort(key=sort_key, reverse=True)
    items = items[:MAX_ITEMS]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialize(items, args))
    newest = items[0].findtext("title") if items else args.version
    print(f"Wrote {args.output} ({len(items)} item(s), newest offered: {newest}).")


if __name__ == "__main__":
    main()
