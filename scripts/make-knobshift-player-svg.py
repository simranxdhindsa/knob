"""Builds docs/images/knobshift-player.svg (python3 scripts/make-knobshift-player-svg.py
docs/images/knobshift-player.svg): the KnobShift player as it looks at work, on a 16 second
loop. A song plays, a Spotify playlist downloads, songs in the queue are prepared one by one,
then KnobMix Now is pressed, waits for the phrase, and mixes into the next song."""
import math
import sys

W, H = 1280, 720
LOOP = 16.0
PRESS, MIX, HAND = 6.4, 8.0, 11.0
ACC, ACC2, CREAM, TEXT, SUB, DIM = "#FF8A3D", "#FF6B1F", "#F3E3CF", "#EDEEF0", "#9A9EA5", "#6B6F76"


def pct(t): return f"{max(0.0, min(100.0, t / LOOP * 100)):.2f}%"


def window(name, start, end, fade=0.3):
    """Shown from start to end (seconds), easing in and out; windows touching the loop's ends
    stay shown there."""
    show, hide = "opacity: 1;", "opacity: 0;"
    keys = []
    if start <= 0:
        keys.append(f"0% {{ {show} }}")
    else:
        keys.append(f"0%, {pct(start - fade)} {{ {hide} }} {pct(start)} {{ {show} }}")
    if end >= LOOP:
        keys.append(f"100% {{ {show} }}")
    else:
        keys.append(f"{pct(end)} {{ {show} }} {pct(end + fade)}, 100% {{ {hide} }}")
    return f".{name} {{ animation: {name} {LOOP}s ease-in-out infinite; }} @keyframes {name} {{ {' '.join(keys)} }}"


def clock(seconds):
    seconds = max(0, int(round(seconds)))
    return f"{seconds // 60}:{seconds % 60:02d}"


css, body = [], []
c, b = css.append, body.append

# Songs: the one playing, and the one it mixes into (which starts at its verse, 0:18).
A = dict(name="Midnight Drive", artist="Aria Vale", length=204, at=181)
B = dict(name="Neon Lights", artist="The Night Shift", length=231, at=18)


def position(t):
    if t < HAND:
        return A, A["at"] + t
    return B, B["at"] + (t - HAND)


b(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">
  <title id="t">The KnobShift player at work</title>
  <desc id="d">A song plays with its progress moving. In the queue, a Spotify playlist downloads song by song and new songs are prepared one by one, each ring filling until the song is ready with its tempo. KnobMix Now is pressed, waits for the next phrase, and the player mixes into the next song, which starts at its verse.</desc>
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3B3E43"/><stop offset="1" stop-color="#151619"/></linearGradient>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1F2124"/><stop offset="1" stop-color="#121315"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0.02"/></linearGradient>
    <linearGradient id="artA" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF9A4D"/><stop offset="0.55" stop-color="#E2456B"/><stop offset="1" stop-color="#3B1D5C"/></linearGradient>
    <linearGradient id="artB" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#0F3B4F"/><stop offset="0.5" stop-color="#2E8C9A"/><stop offset="1" stop-color="#F3E3CF"/></linearGradient>
    <linearGradient id="artC" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#F6C453"/><stop offset="1" stop-color="#C2571F"/></linearGradient>
    <linearGradient id="artD" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6E5BD9"/><stop offset="1" stop-color="#1B1640"/></linearGradient>
    <linearGradient id="artE" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#2C6E49"/><stop offset="1" stop-color="#C9E4A6"/></linearGradient>
    <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="11"/><feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.05 0"/></filter>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.5"/></filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    <filter id="bloom" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="14"/></filter>
    <clipPath id="frame"><rect width="{W}" height="{H}" rx="28"/></clipPath>
    <clipPath id="cover"><rect x="210" y="150" width="260" height="260" rx="30"/></clipPath>
  </defs>''')

c(f'''  <style>
    .scene {{ animation: scene {LOOP}s ease-in-out infinite; }}
    @keyframes scene {{ 0% {{ opacity: 0; }} 3% {{ opacity: 1; }} 96% {{ opacity: 1; }} 100% {{ opacity: 0; }} }}
    .eq {{ transform-box: fill-box; transform-origin: bottom; animation: eq 0.9s ease-in-out infinite alternate; }}
    @keyframes eq {{ from {{ transform: scaleY(0.25); }} to {{ transform: scaleY(1); }} }}
    .spin {{ transform-box: fill-box; transform-origin: center; animation: spin 1.1s linear infinite; }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
    .breathe {{ transform-box: fill-box; transform-origin: center; animation: breathe 2.4s ease-in-out infinite; }}
    @keyframes breathe {{ 0%, 100% {{ transform: scale(1); }} 50% {{ transform: scale(1.04); }} }}
    .drift {{ transform-box: fill-box; transform-origin: center; animation: drift 9s ease-in-out infinite alternate; }}
    @keyframes drift {{ from {{ transform: translate(-10px, 6px) scale(1); }} to {{ transform: translate(12px, -8px) scale(1.12); }} }}
    .press {{ transform-box: fill-box; transform-origin: center; animation: press {LOOP}s ease-in-out infinite; }}
    @keyframes press {{ 0%, {pct(PRESS - 0.25)} {{ transform: scale(1); }} {pct(PRESS)} {{ transform: scale(0.93); }} {pct(PRESS + 0.3)}, 100% {{ transform: scale(1); }} }}
    .lit {{ animation: lit {LOOP}s ease-in-out infinite; }}
    @keyframes lit {{ 0%, {pct(MIX - 0.4)} {{ opacity: 0; }} {pct(MIX + 0.3)}, {pct(HAND - 0.3)} {{ opacity: 1; }} {pct(HAND + 0.6)}, 100% {{ opacity: 0; }} }}''')
for name, start, end in (("songA", 0, HAND - 1.3), ("songB", HAND - 1.0, LOOP), ("waitNow", PRESS + 0.1, MIX),
                         ("chipMix", MIX, HAND), ("nextB", 0, MIX - 0.2), ("nextMix", MIX, HAND), ("nextC", HAND + 0.2, LOOP),
                         ("rowA", 0, HAND), ("rowB", HAND, LOOP)):
    c("    " + window(name, start, end))

# Cover art crossfade, slower than the text.
c(f"    .artB {{ animation: artB {LOOP}s ease-in-out infinite; }} @keyframes artB {{ 0%, {pct(MIX + 0.6)} {{ opacity: 0; }} {pct(HAND)}, 100% {{ opacity: 1; }} }}")

# Progress bar and time, from the song playing.
progress, knob = [], []
for i in range(0, 33):
    t = LOOP * i / 32
    song, at = position(t)
    progress.append(f"{pct(t)} {{ transform: scaleX({at / song['length']:.4f}); }}")
    knob.append(f"{pct(t)} {{ transform: translateX({460 * at / song['length']:.1f}px); }}")
c(f"    .progress {{ transform-box: fill-box; transform-origin: left; animation: progress {LOOP}s linear infinite; }} @keyframes progress {{ {' '.join(progress)} }}")
c(f"    .knob {{ animation: knob {LOOP}s linear infinite; }} @keyframes knob {{ {' '.join(knob)} }}")
for second in range(int(LOOP)):
    first, last = second == 0, second == int(LOOP) - 1
    c(f"    .tick{second} {{ animation: tick{second} {LOOP}s step-end infinite; }} "
      f"@keyframes tick{second} {{ 0% {{ opacity: {1 if first else 0}; }} {pct(second)} {{ opacity: 1; }} {pct(second + 1)} {{ opacity: {1 if last else 0}; }} }}")

# Background work in the queue: rings filling while a song is prepared.
PREP = {"golden": (0.6, 4.6), "after": (4.8, 9.6), "sardaari": (10.0, 14.6)}
RING = 2 * math.pi * 11
for name, (start, end) in PREP.items():
    c(f"    .ring_{name} {{ animation: ring_{name} {LOOP}s linear infinite; }} @keyframes ring_{name} {{ 0%, {pct(start)} {{ stroke-dashoffset: {RING:.1f}; }} "
      f"{pct(end)}, 100% {{ stroke-dashoffset: 0; }} }}")
    # Each state leaves before the next arrives, so their text never overlaps.
    if name != "sardaari":
        c("    " + window(f"waiting_{name}", 0, start - 0.35))
    c("    " + window(f"prep_{name}", start, end))
    c("    " + window(f"ready_{name}", end + 0.65, LOOP))
    for step, share in enumerate((0, 25, 50, 75)):
        a = start + (end - start) * share / 100
        z = start + (end - start) * (share + 25) / 100
        c("    " + window(f"pct_{name}{step}", a, z - 0.05, 0.05))
c("    " + window("dl_sardaari", 0, 7.0))
c("    " + window("wait_sardaari", 7.65, PREP["sardaari"][0] - 0.35))

# Spotify download: the count goes up, the bar grows, the current song changes.
DL = [(0.0, 3, "Kya Baat Aa"), (2.4, 4, "Bodyguard"), (4.8, 5, "Lalkaara"), (7.2, 6, "Ghaint"),
      (9.6, 7, "Majhail"), (12.0, 8, "Khayaal"), (14.4, 9, "Jee Karuga")]
for index, (start, _, _) in enumerate(DL):
    end = DL[index + 1][0] if index + 1 < len(DL) else LOOP
    c("    " + window(f"dl{index}", start, end - 0.15, 0.15))
keys = [f"{pct(start)} {{ transform: scaleX({count / 12:.3f}); }}" for start, count, _ in DL] + [f"100% {{ transform: scaleX({DL[-1][1] / 12:.3f}); }}"]
c(f"    .dlbar {{ transform-box: fill-box; transform-origin: left; animation: dlbar {LOOP}s cubic-bezier(0.3, 0.7, 0.3, 1) infinite; }} @keyframes dlbar {{ {' '.join(keys)} }}")
c("  </style>")

b("\n".join(css))
b(f'''
  <g clip-path="url(#frame)" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
    <rect width="{W}" height="{H}" fill="url(#plate)"/>
    <rect width="{W}" height="{H}" filter="url(#grain)"/>
    <rect width="{W}" height="1.5" fill="#FFFFFF" fill-opacity="0.12"/>
    <circle cx="66" cy="62" r="24" fill="{ACC}"/>
    <path d="M55,57 h20 l-5,-5 M77,67 h-20 l5,5" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>
    <text x="104" y="58" fill="{TEXT}" font-size="22" font-weight="800" letter-spacing="3">KNOBSHIFT</text>
    <text x="104" y="82" fill="{SUB}" font-size="15">Seamless mixes for the music on your Mac</text>
    <rect x="1170" y="44" width="70" height="36" rx="18" fill="#2A2C30" stroke="#FFFFFF" stroke-opacity="0.08"/>
    <rect x="1202" y="48" width="34" height="28" rx="14" fill="#EDEEF0"/>
    <g filter="url(#drop)">
      <rect x="40" y="114" width="640" height="576" rx="26" fill="url(#card)"/>
      <rect x="704" y="114" width="536" height="150" rx="24" fill="url(#card)"/>
      <rect x="704" y="282" width="536" height="408" rx="24" fill="url(#card)"/>
    </g>
    <rect x="40.5" y="114.5" width="639" height="575" rx="26" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>
    <rect x="704.5" y="114.5" width="535" height="149" rx="24" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>
    <rect x="704.5" y="282.5" width="535" height="407" rx="24" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>
    <g class="scene">''')

# Cover art: two pieces of art crossfading, a soft drift, and the KnobMix glow.
b(f'''      <g class="lit"><rect x="200" y="140" width="280" height="280" rx="38" fill="{ACC}" opacity="0.55" filter="url(#bloom)"/></g>
      <g clip-path="url(#cover)">
        <rect x="210" y="150" width="260" height="260" fill="url(#artA)"/>
        <circle class="drift" cx="300" cy="250" r="86" fill="#FFFFFF" fill-opacity="0.16"/>
        <circle cx="400" cy="340" r="54" fill="#1B0E2B" fill-opacity="0.35"/>
        <g class="artB">
          <rect x="210" y="150" width="260" height="260" fill="url(#artB)"/>
          <circle class="drift" cx="380" cy="230" r="70" fill="#FFFFFF" fill-opacity="0.18"/>
          <path d="M210,360 C280,320 360,400 470,340 V410 H210 Z" fill="#082530" fill-opacity="0.5"/>
        </g>
      </g>
      <rect x="210.5" y="150.5" width="259" height="259" rx="30" fill="none" stroke="#FFFFFF" stroke-opacity="0.12"/>
      <g class="lit"><rect x="210" y="150" width="260" height="260" rx="30" fill="none" stroke="{ACC}" stroke-width="2.5"/></g>''')

# Title, artist, live level meter and the KNOBMIX chip.
for cls, song in (("songA", A), ("songB", B)):
    b(f'''      <g class="{cls}">
        <text x="340" y="462" text-anchor="middle" fill="{TEXT}" font-size="30" font-weight="800">{song["name"]}</text>
        <text x="340" y="490" text-anchor="middle" fill="{SUB}" font-size="17">{song["artist"]}</text>
      </g>''')
b(f'      <g fill="{ACC}">')
for i, (x, delay) in enumerate(((290, 0), (300, 0.35), (310, 0.15), (320, 0.55), (330, 0.25))):
    b(f'        <rect class="eq" x="{x}" y="504" width="5" height="16" rx="2.5" style="animation-delay: -{delay}s; animation-duration: {0.7 + i * 0.13:.2f}s"/>')
b('      </g>')
b(f'''      <g class="chipMix"><rect x="348" y="504" width="80" height="18" rx="9" fill="{ACC}"/>
        <text x="388" y="517" text-anchor="middle" fill="#fff" font-size="10" font-weight="800" letter-spacing="1.2">KNOBMIX</text></g>''')

# Progress bar with ticking time.
b(f'''      <rect x="110" y="540" width="460" height="6" rx="3" fill="#FFFFFF" fill-opacity="0.12"/>
      <rect class="progress" x="110" y="540" width="460" height="6" rx="3" fill="{ACC}"/>
      <g class="knob"><circle cx="110" cy="543" r="9" fill="#F2F2F2" filter="url(#soft)"/></g>''')
for second in range(int(LOOP)):
    song, at = position(second)
    b(f'      <g class="tick{second}"><text x="110" y="572" fill="{SUB}" font-size="13" font-weight="600">{clock(at)}</text>'
      f'<text x="570" y="572" text-anchor="end" fill="{SUB}" font-size="13" font-weight="600">{clock(song["length"] - at)} left</text></g>')

# Transport and KnobMix Now.
b(f'''      <path d="M262,606 l-16,10 l16,10 z M244,606 l-16,10 l16,10 z" fill="{TEXT}"/>
      <g class="breathe"><circle cx="340" cy="616" r="30" fill="{ACC}" filter="url(#soft)"/></g>
      <rect x="331" y="603" width="6" height="26" rx="2" fill="#fff"/><rect x="343" y="603" width="6" height="26" rx="2" fill="#fff"/>
      <path d="M418,606 l16,10 l-16,10 z M436,606 l16,10 l-16,10 z" fill="{TEXT}"/>
      <g class="waitNow"><rect x="270" y="650" width="140" height="30" rx="15" fill="{ACC}" fill-opacity="0.35" filter="url(#bloom)"/>
        <text x="424" y="670" fill="{SUB}" font-size="12">Waiting for the phrase</text></g>
      <g class="press"><rect x="270" y="650" width="140" height="30" rx="15" fill="#0C0D0F" fill-opacity="0.4" stroke="{ACC}" stroke-opacity="0.7"/>
        <text x="340" y="670" text-anchor="middle" fill="{ACC}" font-size="11" font-weight="800" letter-spacing="1.6">KNOBMIX NOW</text></g>''')

# Up next.
b(f'      <text x="730" y="148" fill="{DIM}" font-size="12" font-weight="700" letter-spacing="2">UP NEXT</text>')
for cls, art, name, line, colour in (("nextB", "artB", B["name"], B["artist"], SUB), ("nextMix", "artB", B["name"], "Mixing now", ACC),
                                      ("nextC", "artC", "Golden Hour", "Sol Ramirez", SUB)):
    b(f'''      <g class="{cls}"><rect x="730" y="164" width="76" height="76" rx="14" fill="url(#{art})"/>
        <text x="826" y="196" fill="{TEXT}" font-size="20" font-weight="700">{name}</text>
        <text x="826" y="222" fill="{colour}" font-size="15" font-weight="{600 if colour == ACC else 400}">{line}</text></g>''')

# Queue: a Spotify playlist downloading, then the songs.
b(f'''      <text x="730" y="318" fill="{DIM}" font-size="12" font-weight="700" letter-spacing="2">QUEUE  6</text>
      <path d="M1088,308 h6 l10,12 h6 M1088,320 h6 l10,-12 h6" fill="none" stroke="{SUB}" stroke-width="1.8" stroke-linecap="round"/>
      <text x="1214" y="318" text-anchor="end" fill="{ACC}" font-size="12" font-weight="800" letter-spacing="1.2">+ ADD MUSIC</text>
      <rect x="728" y="334" width="488" height="50" rx="12" fill="#FFFFFF" fill-opacity="0.05"/>
      <path d="M744,353 h12 M744,359 h12 M744,365 h8" stroke="{ACC}" stroke-width="2" stroke-linecap="round"/>
      <text x="770" y="355" fill="{TEXT}" font-size="14" font-weight="700">Punjabi Road Trip</text>
      <rect x="770" y="368" width="390" height="3" rx="1.5" fill="#FFFFFF" fill-opacity="0.1"/>
      <rect class="dlbar" x="770" y="368" width="390" height="3" rx="1.5" fill="{ACC}"/>
      <rect x="1186" y="352" width="10" height="10" rx="2" fill="{SUB}"/>''')
for index, (_, count, song) in enumerate(DL):
    b(f'      <g class="dl{index}"><text x="922" y="355" fill="{ACC}" font-size="12" font-weight="600">{count} of 12. Downloading {song}</text></g>')


def row(y, art, name, artist, length, tail):
    return (f'<rect x="740" y="{y}" width="40" height="40" rx="9" fill="url(#{art})"/>'
            f'<text x="796" y="{y + 17}" fill="{TEXT}" font-size="15" font-weight="600">{name}</text>'
            f'<text x="796" y="{y + 35}" fill="{SUB}" font-size="12.5">{artist}{tail}</text>'
            f'<text x="1176" y="{y + 25}" text-anchor="end" fill="{SUB}" font-size="12.5">{length}</text>'
            f'<path d="M1196,{y + 16} l8,8 M1204,{y + 16} l-8,8" stroke="{DIM}" stroke-width="1.8" stroke-linecap="round"/>')


ROWS = 396
b(f'      <g class="rowA"><rect x="728" y="{ROWS - 6}" width="488" height="52" rx="12" fill="{ACC}" fill-opacity="0.12"/></g>')
b(f'      <g class="rowB"><rect x="728" y="{ROWS + 52}" width="488" height="52" rx="12" fill="{ACC}" fill-opacity="0.12"/></g>')
b("      " + row(ROWS, "artA", A["name"], A["artist"], "3:24", "  ·  100 BPM"))
b("      " + row(ROWS + 58, "artB", B["name"], B["artist"], "3:51", "  ·  98 BPM"))


def pending(y, key, name, artist, art, length, bpm):
    out = [f'<g class="ready_{key}">' + row(y, art, name, artist, length, f"  ·  {bpm} BPM") + "</g>"]
    if key != "sardaari":
        out.append(f'<g class="waiting_{key}"><rect x="740" y="{y}" width="40" height="40" rx="9" fill="#FFFFFF" fill-opacity="0.06"/>'
                   f'<text x="796" y="{y + 17}" fill="{SUB}" font-size="15" font-weight="600">{name}</text>'
                   f'<text x="796" y="{y + 35}" fill="{DIM}" font-size="12.5">{artist}  ·  Waiting to prepare</text></g>')
    ring = (f'<circle cx="760" cy="{y + 20}" r="11" fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="3"/>'
            f'<circle class="ring_{key}" cx="760" cy="{y + 20}" r="11" fill="none" stroke="{ACC}" stroke-width="3" stroke-linecap="round" '
            f'stroke-dasharray="{RING:.1f}" transform="rotate(-90 760 {y + 20})"/>')
    labels = "".join(f'<g class="pct_{key}{step}"><text x="796" y="{y + 35}" fill="{DIM}" font-size="12.5">{artist}  ·  Preparing {share}%</text></g>'
                     for step, share in enumerate((0, 25, 50, 75)))
    out.append(f'<g class="prep_{key}"><rect x="740" y="{y}" width="40" height="40" rx="9" fill="#FFFFFF" fill-opacity="0.06"/>{ring}'
               f'<text x="796" y="{y + 17}" fill="{SUB}" font-size="15" font-weight="600">{name}</text>{labels}</g>')
    return "".join(out)


b("      " + pending(ROWS + 116, "golden", "Golden Hour", "Sol Ramirez", "artC", "3:37", 96))
b("      " + pending(ROWS + 174, "after", "Afterglow", "June Harbor", "artD", "4:02", 104))
b("      " + pending(ROWS + 232, "sardaari", "Sardaari", "Himmat Sandhu", "artE", "3:18", 92))
y = ROWS + 232
b(f'''      <g class="dl_sardaari"><rect x="740" y="{y}" width="40" height="40" rx="9" fill="#FFFFFF" fill-opacity="0.06"/>
        <g class="spin"><circle cx="760" cy="{y + 20}" r="11" fill="none" stroke="{ACC}" stroke-width="3" stroke-linecap="round" stroke-dasharray="22 60"/></g>
        <text x="796" y="{y + 17}" fill="{SUB}" font-size="15" font-weight="600">Sardaari</text>
        <text x="796" y="{y + 35}" fill="{ACC}" font-size="12.5">Himmat Sandhu  ·  Downloading from Spotify</text></g>
      <g class="wait_sardaari"><rect x="740" y="{y}" width="40" height="40" rx="9" fill="#FFFFFF" fill-opacity="0.06"/>
        <text x="796" y="{y + 17}" fill="{SUB}" font-size="15" font-weight="600">Sardaari</text>
        <text x="796" y="{y + 35}" fill="{DIM}" font-size="12.5">Himmat Sandhu  ·  Waiting to prepare</text></g>''')

b("    </g>")
b("  </g>\n</svg>")
open(sys.argv[1], "w").write("\n".join(body))
