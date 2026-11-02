"""Writes appcast.xml (the update feed installed copies of Knob read) and the release notes.

Called by scripts/release/release.sh with this version's section of CHANGELOG.md: "### " lines
are group headings (New features, Fixes) and "- " lines the items under them.
"""
import argparse
import email.utils
import html
import re
from xml.sax.saxutils import escape, quoteattr


def changes(path):
    """[(heading, [items])] in the order written; items before any heading go under None."""
    groups = []
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if line.startswith("### "):
            groups.append((line[4:].strip(), []))
        elif line.startswith("- ") and line[2:].strip():
            if not groups:
                groups.append((None, []))
            groups[-1][1].append(line[2:].strip())
    groups = [(heading, items) for heading, items in groups if items]
    return groups or [(None, ["Small improvements and fixes."])]


def main():
    parser = argparse.ArgumentParser()
    for name in ("version", "build", "url", "signature", "installation-type", "changes", "appcast", "notes"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    groups = changes(args.changes)

    with open(args.notes, "w", encoding="utf-8") as notes:
        for heading, items in groups:
            if heading:
                notes.write(f"### {heading}\n\n")
            notes.write("".join(f"- {line}\n" for line in items) + "\n")
        notes.write("New to Knob? Download Knob.dmg below and open Knob-Install.pkg inside it."
                    " Already installed? Knob updates itself.\n")

    # sign_update prints: sparkle:edSignature="..." length="..."
    attributes = dict(re.findall(r'(sparkle:edSignature|length)="([^"]*)"', args.signature))
    enclosure = {"url": args.url, "type": "application/octet-stream", **attributes}
    if args.installation_type:
        enclosure["sparkle:installationType"] = args.installation_type
    enclosure_xml = " ".join(f"{key}={quoteattr(value)}" for key, value in enclosure.items())
    description = "".join((f"<h3>{html.escape(heading)}</h3>" if heading else "")
                          + "<ul>" + "".join(f"<li>{html.escape(line)}</li>" for line in items) + "</ul>"
                          for heading, items in groups)

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
