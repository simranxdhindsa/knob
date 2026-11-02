"""Writes appcast.xml (the update feed installed copies of Knob read) and the release notes.

Called by scripts/release/release.sh. Change lines are either a version's section of
CHANGELOG.md or commit subjects with their emoji and type prefix (FEATURE:, BUG:, ...) removed;
CHORE, REFACTOR and DOCS commits are left out of what users read.
"""
import argparse
import email.utils
import html
import re
from xml.sax.saxutils import escape, quoteattr

HIDDEN = {"CHORE", "REFACTOR", "DOCS"}


def changes(path):
    lines = []
    for raw in open(path, encoding="utf-8"):
        # Subjects may start with an emoji: "🐛 BUG: ...".
        match = re.match(r"\s*(?:[^\sA-Za-z0-9]+\s+)?([A-Z]+):\s*(.+)", raw)
        kind, text = (match.group(1), match.group(2)) if match else ("", raw.strip())
        if text and kind not in HIDDEN and text not in lines:
            lines.append(text[0].upper() + text[1:])
    return lines or ["Small improvements and fixes."]


def main():
    parser = argparse.ArgumentParser()
    for name in ("version", "build", "url", "signature", "installation-type", "changes", "appcast", "notes"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    items = changes(args.changes)

    with open(args.notes, "w", encoding="utf-8") as notes:
        notes.write("".join(f"- {line}\n" for line in items))
        notes.write("\nNew to Knob? Download Knob.dmg below and open Knob-Install.pkg inside it."
                    " Already installed? Knob updates itself.\n")

    # sign_update prints: sparkle:edSignature="..." length="..."
    attributes = dict(re.findall(r'(sparkle:edSignature|length)="([^"]*)"', args.signature))
    enclosure = {"url": args.url, "type": "application/octet-stream", **attributes}
    if args.installation_type:
        enclosure["sparkle:installationType"] = args.installation_type
    enclosure_xml = " ".join(f"{key}={quoteattr(value)}" for key, value in enclosure.items())
    description = "<ul>" + "".join(f"<li>{html.escape(line)}</li>" for line in items) + "</ul>"

    with open(args.appcast, "w", encoding="utf-8") as feed:
        feed.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Knob</title>
    <item>
      <title>Knob {escape(args.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{description}]]></description>
      <enclosure {enclosure_xml}/>
    </item>
  </channel>
</rss>
""")


if __name__ == "__main__":
    main()
