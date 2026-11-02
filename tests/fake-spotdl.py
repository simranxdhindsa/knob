#!/usr/bin/env python3
"""A stand in for spotDL, for KnobShift's Spotify checks (--knobshift-spotify-check uat).

It answers the two commands KnobShift runs, the way spotDL 4.6 does, without any network:
  save QUERY --save-file FILE      writes FAKE_COUNT songs as a spotDL save file
  download FILE --output TEMPLATE  "downloads" each song in FILE by copying FAKE_AUDIO,
                                   writing it in two halves like FFmpeg converting in place,
                                   and prints spotDL's own messages

Behaviour is set through the environment:
  FAKE_COUNT       songs in a list (default 12)
  FAKE_DELAY       seconds per song (default 0.05)
  FAKE_MISSING     list positions that are "not found", comma separated
  FAKE_HANG        after this many songs, go silent for ten minutes
  FAKE_CHILD       1 leaves a child process holding the output open after exiting
  FAKE_LIST_DELAY  seconds before a save finishes
"""
import json
import os
import subprocess
import sys
import time


def arg(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


def songs(count, query):
    tag = "".join(ch for ch in query if ch.isalnum())[-4:].rjust(4, "x")
    titles = ["Jee Karuga (feat. Sargi Maan)", "ਖੀਰ ਤੇ ਵੈਰ", "Daaru Sasti [Remix]", "Why So", "No Luck", "Shaukeen"]
    result = []
    for index in range(count):
        title = titles[index % len(titles)] + ("" if index < len(titles) else f" {index}")
        artists = ["Karan Aujla", "Ikky"] if index % 3 == 0 else ["Shubh"]
        result.append({
            "name": title, "artists": artists, "artist": artists[0], "album_name": "Fake Album",
            "duration": 180 + index, "song_id": f"{tag}{index:018d}",
            "url": f"https://open.spotify.com/track/{index}", "list_name": "Fake Road Trip",
            "list_position": index + 1, "list_length": count, "isrc": f"FAKE{index}",
        })
    return result


def save():
    time.sleep(float(os.environ.get("FAKE_LIST_DELAY", "0")))
    data = songs(int(os.environ.get("FAKE_COUNT", "12")), sys.argv[2])
    with open(arg("--save-file"), "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    print(f"Saved {len(data)} songs to {arg('--save-file')}", flush=True)


def download():
    with open(sys.argv[2], encoding="utf-8") as handle:
        data = json.load(handle)
    template = arg("--output")
    audio = os.environ["FAKE_AUDIO"]
    extension = os.path.splitext(audio)[1].lstrip(".")
    delay = float(os.environ.get("FAKE_DELAY", "0.05"))
    missing = {int(x) for x in os.environ.get("FAKE_MISSING", "").split(",") if x}
    hang = int(os.environ.get("FAKE_HANG", "-1"))
    if os.environ.get("FAKE_CHILD") == "1":
        subprocess.Popen(["/bin/sleep", "30"])
    with open(audio, "rb") as handle:
        payload = handle.read()
    for done, song in enumerate(data):
        if done == hang:
            time.sleep(600)
        display = f"{song['artist']} - {song['name']}"
        if song["list_position"] in missing:
            print(f"LookupError: No results found for song: {display}", flush=True)
            continue
        width = len(str(song["list_length"]))
        name = (template.replace("{list-position}", str(song["list_position"]).zfill(width))
                .replace("{title}", song["name"].replace("/", ""))
                .replace("{artists}", ", ".join(song["artists"]))
                .replace("{track-id}", song["song_id"])
                .replace("{output-ext}", extension))
        os.makedirs(os.path.dirname(name), exist_ok=True)
        if os.path.exists(name):
            print(f"Skipping {display} (file already exists) (duplicate)", flush=True)
            continue
        # Written in place in two halves, like FFmpeg converting into the playlist folder.
        with open(name, "wb") as handle:
            handle.write(payload[: len(payload) // 2])
            handle.flush()
            time.sleep(delay)
            handle.write(payload[len(payload) // 2:])
        # spotDL's display drops text in square brackets.
        shown = display.replace("[Remix]", "").strip()
        print(f'Downloaded "{shown}": https://music.youtube.com/watch?v={song["song_id"]}', flush=True)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "save":
        save()
    elif command == "download":
        download()
    else:
        print(f"fake spotdl: unknown command {command}", file=sys.stderr)
        sys.exit(2)
