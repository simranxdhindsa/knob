"""Builds docs/images/knobmix.svg (python3 scripts/make-knobmix-svg.py docs/images/knobmix.svg):
a 38 second looping KnobShift set of three songs mixing into the next, each with its own
transition (Tape slowdown, Echo out, and KnobMix Now into an Underwater fade). Everything is
generated from one timeline, so waveform bars, voice lines, decks, meters, the effect curve and
the captions always line up."""
import math
import random
import sys

W, H = 1280, 780
LOOP = 38.0
PX = 104.0                # pixels per second of song
VX, VW = 300, 900         # waveform window
PLAY = 600                # playhead x
OFFSET = 1.0              # song time under the playhead when the loop starts
LANES = {"a": (126, 300), "b": (316, 490)}
ACC, ACC2, CREAM, TEXT, SUB, SEA = "#FF8A3D", "#FF6B1F", "#F3E3CF", "#EDEEF0", "#9A9EA5", "#8EC5E8"

# The three mixes in song time: mix opens, the old verse ends, handoff.
MIXES = [
    dict(open=3.0, voice=7.2, hand=11.8, style="tape", name="Tape slowdown",
         why=["Tempos are close, so the beats lock.", "The old voice alone slows like tape."],
         sync="BEATS LOCKED  98 TO 100 BPM", locked=True),
    dict(open=15.6, voice=20.6, hand=24.6, style="echo", name="Echo out",
         why=["Tempos are far apart, so each song", "keeps its speed. The verse echoes out."],
         sync="OWN SPEEDS  92 AND 124 BPM", locked=False),
    dict(open=29.4, voice=33.4, hand=37.4, style="water", name="Underwater fade",
         why=["KnobMix Now waited for the next", "phrase, then the old song sinks away."],
         sync="BEATS LOCKED  124 TO 120 BPM", locked=True, now=26.4),
]
SONGS = [  # lane, first sound, voice from, voice to, last sound
    dict(lane="a", start=-4.0, vfrom=-4.0, vto=MIXES[0]["voice"], end=MIXES[0]["hand"], name="Midnight Drive"),
    dict(lane="b", start=MIXES[0]["open"], vfrom=MIXES[0]["hand"], vto=MIXES[1]["voice"], end=MIXES[1]["hand"], name="Neon Lights"),
    dict(lane="a", start=MIXES[1]["open"], vfrom=MIXES[1]["hand"], vto=MIXES[2]["voice"], end=MIXES[2]["hand"], name="Golden Hour"),
    dict(lane="b", start=MIXES[2]["open"], vfrom=MIXES[2]["hand"], vto=60.0, end=60.0, name="Afterglow"),
]
for index, mix in enumerate(MIXES):
    mix["out"], mix["inc"] = SONGS[index], SONGS[index + 1]


def scene(song_t): return song_t - OFFSET
def pct(t): return f"{max(0.0, min(100.0, t / LOOP * 100)):.2f}%"
def cx(song_t): return song_t * PX


def mix_of(song, as_outgoing):
    for mix in MIXES:
        if (mix["out"] if as_outgoing else mix["inc"]) is song:
            return mix
    return None


def level(song, t):
    """How loud a song is at song time t (0...1)."""
    if t < song["start"] or t > song["end"]:
        return 0.0
    incoming, outgoing = mix_of(song, False), mix_of(song, True)
    if incoming and t < incoming["hand"]:
        p = (t - incoming["open"]) / (incoming["hand"] - incoming["open"])
        return math.sin(max(0, p) * math.pi / 2)
    if outgoing and t > outgoing["open"]:
        p = (t - outgoing["open"]) / (outgoing["hand"] - outgoing["open"])
        return math.cos(min(1, p) * math.pi / 2)
    return 1.0


def speed(song, t):
    """Playback speed of a song's deck: tape slowdown winds the old record down."""
    if t < song["start"] or t > song["end"]:
        return 0.0
    incoming, outgoing = mix_of(song, False), mix_of(song, True)
    if incoming and t < incoming["open"] + 1.2:
        return max(0.0, (t - incoming["open"]) / 1.2)
    if outgoing and outgoing["style"] == "tape" and t > outgoing["voice"] - 1.0:
        p = min(1, (t - (outgoing["voice"] - 1.0)) / (outgoing["hand"] - outgoing["voice"] + 1.0))
        return 1 - 0.6 * p
    return 1.0


def effect(mix, t):
    """The transition's effect amount (0...1): rises until the verse ends, falls to the handoff,
    and breathes gently on every beat."""
    o, v, h = mix["open"], mix["voice"], mix["hand"]
    if t <= o or t >= h:
        return 0.0
    base = math.sin((t - o) / (v - o) * math.pi / 2) if t < v else math.cos((t - v) / (h - v) * math.pi / 2)
    # A soft, rounded pulse on each beat, not a sharp dip.
    pulse = 0.5 - 0.5 * math.cos(2 * math.pi * (t % 0.5) / 0.5)
    return base * (1 - 0.045 * pulse)


out = []
o = out.append
rnd = random.Random(7)

o(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">
  <title id="t">KnobShift mixing three songs, each with its own transition</title>
  <desc id="d">Two decks play a set of four songs. Each mix is planned for its pair of songs. In the first, the tempos are close, so the beats lock and the old voice slows down like tape. In the second, the tempos are far apart, so each song keeps its speed and the verse echoes out on the beat. In the third, KnobMix Now waits for the next phrase, then the old song sinks under an underwater filter. Every effect rises until the old verse ends and falls away by the handoff, pumping on the beat, while the new song's beats come in under the old voice and its own voice lands through a short reverb.</desc>
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3B3E43"/><stop offset="1" stop-color="#151619"/></linearGradient>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2C2E33"/><stop offset="1" stop-color="#1D1F22"/></linearGradient>
    <linearGradient id="screen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#16171A"/><stop offset="1" stop-color="#0C0D0F"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0.03"/></linearGradient>
    <linearGradient id="barA" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFB27A"/><stop offset="0.5" stop-color="{ACC}"/><stop offset="1" stop-color="{ACC2}" stop-opacity="0.55"/></linearGradient>
    <linearGradient id="barB" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="{CREAM}"/><stop offset="1" stop-color="{CREAM}" stop-opacity="0.45"/></linearGradient>
    <linearGradient id="barT" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E0874A"/><stop offset="0.5" stop-color="#B9562A"/><stop offset="1" stop-color="#7A3418" stop-opacity="0.6"/></linearGradient>
    <linearGradient id="barW" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#CFE9FA"/><stop offset="0.5" stop-color="{SEA}"/><stop offset="1" stop-color="#3D6C8C" stop-opacity="0.5"/></linearGradient>
    <linearGradient id="fx" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{ACC}" stop-opacity="0.45"/><stop offset="1" stop-color="{ACC}" stop-opacity="0"/></linearGradient>
    <linearGradient id="edge" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="0.08" stop-color="#fff"/>
      <stop offset="0.92" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <mask id="fade" maskUnits="userSpaceOnUse" x="{VX}" y="0" width="{VW}" height="{H}"><rect x="{VX}" y="0" width="{VW}" height="{H}" fill="url(#edge)"/></mask>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{ACC}" stop-opacity="0.30"/><stop offset="1" stop-color="{ACC}" stop-opacity="0"/></radialGradient>
    <radialGradient id="vinyl" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#2A2C30"/><stop offset="0.7" stop-color="#101113"/><stop offset="1" stop-color="#050506"/></radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0.3" stop-color="#fff" stop-opacity="0"/><stop offset="0.5" stop-color="#fff" stop-opacity="0.16"/><stop offset="0.7" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="11"/><feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.05 0"/></filter>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.45"/></filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3.5" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    <filter id="bloom" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="7"/></filter>
    <filter id="murk" x="-10%" y="-30%" width="120%" height="160%"><feGaussianBlur stdDeviation="2.2"/></filter>
    <clipPath id="frame"><rect width="{W}" height="{H}" rx="28"/></clipPath>''')
for key, (y0, y1) in LANES.items():
    o(f'    <clipPath id="view{key.upper()}"><rect x="{VX}" y="{y0+8}" width="{VW}" height="{y1-y0-16}"/></clipPath>')

GX, GW, GY0, GY1 = 470, 430, 560, 672   # effect graph
for index, mix in enumerate(MIXES):
    a, b = scene(mix["open"]) / LOOP, scene(mix["hand"]) / LOOP
    o(f'''    <clipPath id="draw{index}"><rect x="{GX}" y="{GY0-14}" width="0" height="{GY1-GY0+20}">
      <animate attributeName="width" values="0;0;{GW};{GW}" keyTimes="0;{a:.4f};{b:.4f};1" dur="{LOOP}s" repeatCount="indefinite"/>
    </rect></clipPath>''')
o('  </defs>')


def sampled(name, fn, step=0.4):
    keys = []
    t = 0.0
    while t <= LOOP + 1e-6:
        keys.append(f"{pct(t)} {{ {fn(t)} }}")
        t += step
    return f"@keyframes {name} {{ " + " ".join(keys) + " }"


def lane_level(lane, t):
    return max(level(s, t) for s in SONGS if s["lane"] == lane)


def rotation(lane):
    """Deck angle over the loop, from its playback speed (240 degrees a second at full speed)."""
    keys, angle, t, step = [], 0.0, 0.0, 0.2
    while t <= LOOP + 1e-6:
        keys.append(f"{pct(t)} {{ transform: rotate({angle:.1f}deg); }}")
        song_t = t + OFFSET
        angle += 240 * step * max(speed(s, song_t) for s in SONGS if s["lane"] == lane)
        t += step
    return " ".join(keys)


def window(name, start, end, fade=0.35, rise=6):
    """Shown from start to end (scene seconds), easing in and out. A window that lasts to the
    end of the loop stays shown; the whole scene fades out there anyway."""
    show = f"opacity: 1; transform: translateY(0);"
    if start <= 0:
        head = f"0%, {pct(end)} {{ {show} }} "
    else:
        head = f"0%, {pct(start - fade)} {{ opacity: 0; transform: translateY({rise}px); }} {pct(start)}, {pct(min(end, LOOP))} {{ {show} }} "
    tail = "" if end + fade >= LOOP else f"{pct(end + fade)}, 100% {{ opacity: 0; transform: translateY(-4px); }} "
    if not tail:
        head = head.replace(f"{pct(min(end, LOOP))} {{", "100% {")
    return f".{name} {{ animation: {name} {LOOP}s ease-in-out infinite; }} @keyframes {name} {{ {head}{tail}}}"


scroll0 = PLAY - VX - OFFSET * PX
scroll1 = PLAY - VX - (OFFSET + LOOP) * PX
css = [f'''  <style>
    .scroll {{ animation: scroll {LOOP}s linear infinite; }}
    @keyframes scroll {{ from {{ transform: translateX({scroll0:.1f}px); }} to {{ transform: translateX({scroll1:.1f}px); }} }}
    .scene {{ animation: scene {LOOP}s ease-in-out infinite; }}
    @keyframes scene {{ 0% {{ opacity: 0; }} 2.5% {{ opacity: 1; }} 96% {{ opacity: 1; }} 100% {{ opacity: 0; }} }}
    .spin {{ transform-box: fill-box; transform-origin: center; animation-duration: {LOOP}s; animation-iteration-count: infinite; animation-timing-function: linear; }}
    .spinA {{ animation-name: spinA; }} @keyframes spinA {{ {rotation("a")} }}
    .spinB {{ animation-name: spinB; }} @keyframes spinB {{ {rotation("b")} }}
    .vol {{ transform-box: fill-box; transform-origin: bottom; animation-duration: {LOOP}s; animation-iteration-count: infinite; animation-timing-function: linear; }}
    .volA {{ animation-name: volA; }} .volB {{ animation-name: volB; }}
    .rimA {{ animation: rimA {LOOP}s linear infinite; }} .rimB {{ animation: rimB {LOOP}s linear infinite; }}
    .dimA {{ animation: dimA {LOOP}s linear infinite; }} .dimB {{ animation: dimB {LOOP}s linear infinite; }}
    .beat {{ transform-box: fill-box; transform-origin: center; animation: beat 0.5s cubic-bezier(0.2, 0.7, 0.3, 1) infinite; }}
    @keyframes beat {{ 0% {{ transform: scale(1.5); opacity: 1; }} 70%, 100% {{ transform: scale(0.85); opacity: 0.35; }} }}
    .ring {{ transform-box: fill-box; transform-origin: center; animation: ring 0.5s ease-out infinite; }}
    @keyframes ring {{ 0% {{ transform: scale(0.6); opacity: 0.8; }} 100% {{ transform: scale(2.6); opacity: 0; }} }}
    .press {{ transform-box: fill-box; transform-origin: center; animation: press {LOOP}s ease-in-out infinite; }}
''']
for lane in ("a", "b"):
    L = lane.upper()
    css.append("    " + sampled(f"vol{L}", lambda t, lane=lane: f"transform: scaleY({lane_level(lane, t + OFFSET):.3f})"))
    css.append("    " + sampled(f"rim{L}", lambda t, lane=lane: f"stroke-opacity: {0.06 + 0.8 * lane_level(lane, t + OFFSET):.3f}", 0.5))
    css.append("    " + sampled(f"dim{L}", lambda t, lane=lane: f"opacity: {0.4 + 0.6 * min(1, lane_level(lane, t + OFFSET) * 1.6):.3f}", 0.5))

# Windows: deck names, transition cards, chips, KnobMix Now.
for index, mix in enumerate(MIXES):
    start = 0.0 if index == 0 else scene(MIXES[index - 1]["hand"]) + 1.2
    end = scene(mix["hand"]) + 1.2 if index < len(MIXES) - 1 else LOOP
    css.append("    " + window(f"card{index}", start, end - 0.4, 0.4))
    swap = scene((mix["voice"] + mix["hand"]) / 2)
    css.append("    " + window(f"swap{index}", swap - 0.2, swap + 1.4, 0.25, 0))
    css.append("    " + window(f"split{index}", scene(mix["open"]), scene(mix["hand"]), 0.3, 0))
    badge = f"lock{index}" if mix["locked"] else f"own{index}"
    css.append("    " + window(badge, scene(mix["open"]) + 0.3, scene(mix["hand"]) + 0.6))
for index, song in enumerate(SONGS):
    shown_from = 0.0 if index < 2 else scene(SONGS[index - 2]["end"]) + 0.65
    shown_to = scene(song["end"]) - 0.4 if index + 2 < len(SONGS) else LOOP
    css.append("    " + window(f"song{index}", shown_from, shown_to, 0.3, 4))
now = MIXES[2]["now"]
css.append(f"    @keyframes press {{ 0%, {pct(scene(now) - 0.6)} {{ transform: scale(1); }} {pct(scene(now))} {{ transform: scale(0.92); }} "
           f"{pct(scene(now) + 0.25)}, 100% {{ transform: scale(1); }} }}")
css.append("    " + window("nowglow", scene(now), scene(MIXES[2]["open"]) + 0.3, 0.2, 0))
css.append("    " + window("nowwait", scene(now) + 0.2, scene(MIXES[2]["open"]), 0.3, 4))
css.append("  </style>")
o("\n".join(css))

o(f'''
  <g clip-path="url(#frame)" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
    <rect width="{W}" height="{H}" fill="url(#plate)"/>
    <rect width="{W}" height="{H}" filter="url(#grain)"/>
    <ellipse cx="{PLAY}" cy="310" rx="520" ry="230" fill="url(#glow)"/>
    <rect width="{W}" height="1.5" fill="#FFFFFF" fill-opacity="0.12"/>
    <text x="56" y="62" fill="{ACC}" font-size="15" font-weight="700" letter-spacing="3">KNOBMIX</text>
    <text x="56" y="98" fill="{TEXT}" font-size="28" font-weight="700">Every pair of songs gets its own mix.</text>''')

o('    <g filter="url(#drop)">')
for y0, y1 in LANES.values():
    o(f'      <rect x="56" y="{y0}" width="1168" height="{y1-y0}" rx="22" fill="url(#card)"/>')
o('      <rect x="56" y="512" width="1168" height="236" rx="22" fill="url(#card)"/>')
o('    </g>')
for key, (y0, y1) in LANES.items():
    o(f'    <rect x="56.5" y="{y0+.5}" width="1167" height="{y1-y0-1}" rx="22" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>')
    o(f'    <rect class="rim{key.upper()}" x="56.5" y="{y0+.5}" width="1167" height="{y1-y0-1}" rx="22" fill="none" stroke="{ACC2}" stroke-width="1.5"/>')
    o(f'    <rect x="{VX}" y="{y0+8}" width="{VW}" height="{y1-y0-16}" rx="14" fill="url(#screen)" stroke="#FFFFFF" stroke-opacity="0.06"/>')
o('    <rect x="56.5" y="512.5" width="1167" height="235" rx="22" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>')

o('    <g class="scene">')

# KnobMix Now button in the header.
o(f'''    <g class="press">
      <rect x="1030" y="42" width="194" height="38" rx="19" fill="#0C0D0F" fill-opacity="0.5" stroke="{ACC}" stroke-opacity="0.75"/>
      <text x="1127" y="66" text-anchor="middle" fill="{ACC}" font-size="12.5" font-weight="700" letter-spacing="1.8">KNOBMIX NOW</text>
    </g>
    <g class="nowglow"><rect x="1030" y="42" width="194" height="38" rx="19" fill="{ACC}" fill-opacity="0.22" filter="url(#bloom)"/>
      <rect x="1030" y="42" width="194" height="38" rx="19" fill="none" stroke="{ACC}" stroke-width="2"/></g>
    <g class="nowwait"><text x="1012" y="66" text-anchor="end" fill="{SUB}" font-size="14">Waiting for the next phrase</text></g>''')

# Decks.
for key, (y0, y1) in LANES.items():
    mid = (y0 + y1) / 2
    centre = ACC if key == "a" else CREAM
    o(f'    <g class="dim{key.upper()}">')
    o(f'      <circle cx="136" cy="{mid}" r="62" fill="#000" fill-opacity="0.35" filter="url(#bloom)"/>')
    o(f'      <g class="spin spin{key.upper()}">')
    o(f'        <circle cx="136" cy="{mid}" r="58" fill="url(#vinyl)" stroke="#FFFFFF" stroke-opacity="0.08"/>')
    for r in range(24, 56, 4):
        o(f'        <circle cx="136" cy="{mid}" r="{r}" fill="none" stroke="#FFFFFF" stroke-opacity="{0.035 + (r % 8) * 0.004:.3f}"/>')
    o(f'        <circle cx="136" cy="{mid}" r="20" fill="{centre}"/>')
    o(f'        <rect x="133" y="{mid-17}" width="6" height="9" rx="3" fill="#000" fill-opacity="0.35"/>')
    o(f'        <circle cx="136" cy="{mid}" r="3" fill="#0C0D0F"/>')
    o('      </g>')
    o(f'      <circle cx="136" cy="{mid}" r="58" fill="url(#sheen)"/>')
    o(f'      <text x="210" y="{mid-14}" fill="{ACC if key == "a" else CREAM}" font-size="12" font-weight="700" letter-spacing="2">DECK {1 if key == "a" else 2}</text>')
    o('    </g>')
    for index, song in enumerate(SONGS):
        if song["lane"] != key:
            continue
        words = song["name"].split()
        o(f'    <g class="song{index}"><text x="210" y="{mid+9}" fill="{TEXT}" font-size="14" font-weight="700">{words[0]}</text>'
          f'<text x="210" y="{mid+28}" fill="{TEXT}" font-size="14" font-weight="700">{" ".join(words[1:])}</text></g>')
    o(f'    <rect x="279" y="{y0+22}" width="6" height="{y1-y0-44}" rx="3" fill="#0C0D0F" stroke="#FFFFFF" stroke-opacity="0.06"/>')
    o(f'    <rect class="vol vol{key.upper()}" x="279" y="{y0+22}" width="6" height="{y1-y0-44}" rx="3" fill="{ACC if key == "a" else CREAM}" filter="url(#soft)"/>')


def voice_path(song, mid, t0, t1, seed, amp=28):
    """The singing voice as a line; its wiggle slows when the deck slows."""
    r = random.Random(seed)
    pts, phase, t = [], t0 * 9.0, t0
    while t <= t1 + 1e-6:
        syll = 0.45 + 0.55 * abs(math.sin(phase * 0.59 + r.random() * 0.4))
        edge = min(1, (t - t0) / 0.4, (t1 - t) / 0.4) if t1 - t0 > 0.8 else 1
        pts.append((cx(t), mid + amp * edge * syll * math.sin(phase)))
        phase += 9.0 * 0.05 * max(speed(song, t), 0.35)
        t += 0.05
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def song_layers(song, y0, y1, seed):
    mid = (y0 + y1) / 2
    maxh = (y1 - y0) - 46
    fill = "A" if song["lane"] == "a" else "B"
    outgoing, incoming = mix_of(song, True), mix_of(song, False)
    style = outgoing["style"] if outgoing else None
    plain, styled = [], []
    t, phase = song["start"], 0.0
    while t < min(song["end"], 52):
        kick = 0.55 + 0.45 * math.exp(-((phase % 0.5) / 0.5) * 5)
        h = maxh * level(song, t) * kick * (0.75 + 0.25 * rnd.random())
        if incoming and t < incoming["hand"]:
            h *= 0.75   # beats only while the old voice sings
        in_fx = outgoing is not None and t > outgoing["open"]
        if in_fx and style == "water":
            h *= 1 - 0.45 * (t - outgoing["open"]) / (outgoing["hand"] - outgoing["open"])
        width = 5 + (2.5 * (1 - speed(song, t)) if style == "tape" and in_fx else 0)
        if h > 2:
            bar = f'<rect x="{cx(t):.1f}" y="{mid - h/2:.1f}" width="{width:.1f}" height="{h:.1f}" rx="{width/2:.1f}"/>'
            (styled if in_fx else plain).append(bar)
        phase += 0.1 * max(speed(song, t), 0.3)
        t += 0.1
    parts = [f'<g fill="url(#bar{fill})" fill-opacity="0.85">' + "".join(plain) + "</g>"]
    if styled:
        look = {"tape": 'fill="url(#barT)"', "echo": f'fill="url(#bar{fill})"', "water": 'fill="url(#barW)" filter="url(#murk)"'}[style]
        parts.append(f'<g {look} fill-opacity="0.85">' + "".join(styled) + "</g>")
    # The voice: the verse, its last line brighter, and a new verse arriving through reverb.
    vfrom, vto = song["vfrom"], min(song["vto"], 52)
    last_from = outgoing["open"] if outgoing else vto
    stroke = 'fill="none" stroke-linecap="round" stroke-linejoin="round"'
    if last_from > vfrom:
        parts.append(f'<path d="{voice_path(song, mid, vfrom, min(last_from, vto), seed)}" {stroke} stroke="#FFFFFF" stroke-width="2.6" filter="url(#soft)" opacity="0.92"/>')
    if incoming:
        parts.append(f'<path d="{voice_path(song, mid, vfrom, vfrom + 1.6, seed)}" {stroke} stroke="#FFFFFF" stroke-width="12" opacity="0.28" filter="url(#bloom)"/>')
    if outgoing:
        last = voice_path(song, mid, last_from, vto, seed + 1, 32)
        if style == "water":
            parts.append(f'<path d="{last}" {stroke} stroke="#D6EEFB" stroke-width="3.2" filter="url(#murk)" opacity="0.85"/>')
        else:
            parts.append(f'<path d="{last}" {stroke} stroke="#FFE3C7" stroke-width="3.4" filter="url(#soft)"/>')
        if style == "echo":
            tail = voice_path(song, mid, vto - 0.9, vto, seed + 2, 30)
            for tap in range(1, 5):
                parts.append(f'<path d="{tail}" transform="translate({tap * 0.5 * PX:.1f} 0)" {stroke} stroke="{ACC}" stroke-width="2.6" opacity="{0.62 * 0.6 ** tap:.2f}" filter="url(#soft)"/>')
    return parts


def pill(x, y, text, color=ACC):
    width = len(text) * 7.6 + 24
    return (f'<rect x="{x:.1f}" y="{y}" width="{width:.0f}" height="22" rx="11" fill="{color}" fill-opacity="0.16" stroke="{color}" stroke-opacity="0.6"/>'
            f'<text x="{x + width / 2:.1f}" y="{y + 15}" text-anchor="middle" fill="{color}" font-size="11" font-weight="700" letter-spacing="1.4">{text}</text>')


for key, (y0, y1) in LANES.items():
    o(f'    <g clip-path="url(#view{key.upper()})"><g mask="url(#fade)"><g transform="translate({VX} 0)"><g class="scroll">')
    ticks, t = [], -4.0
    while t < 52:
        big = abs((t / 2) - round(t / 2)) < 1e-6
        ticks.append(f'<rect x="{cx(t):.1f}" y="{y1-22 if big else y1-17}" width="1.5" height="{12 if big else 7}" fill="#FFFFFF" fill-opacity="{0.22 if big else 0.1}"/>')
        t += 0.5
    o("      " + "".join(ticks))
    for index, song in enumerate(SONGS):
        if song["lane"] == key:
            for part in song_layers(song, y0, y1, index * 10 + 3):
                o("      " + part)
    for mix in MIXES:
        for at, name in ((mix["open"], "MIX OPENS"), (mix["hand"], "HANDOFF")):
            o(f'      <line x1="{cx(at):.1f}" y1="{y0+14}" x2="{cx(at):.1f}" y2="{y1-14}" stroke="#FFFFFF" stroke-opacity="0.26" stroke-dasharray="4 6"/>')
            if key == mix["out"]["lane"]:
                o(f'      <text x="{cx(at)+8:.1f}" y="{y0+30}" fill="{SUB}" font-size="11" font-weight="700" letter-spacing="1.6">{name}</text>')
        if key == mix["out"]["lane"]:
            o("      " + pill(cx(mix["open"]) + 8, y1 - 50, "LAST LINE"))
            o("      " + pill(cx(mix["voice"]) + 8, y0 + 40, mix["name"].upper(), SEA if mix["style"] == "water" else ACC))
        else:
            o(f'      <text x="{cx(mix["open"]) + 10:.1f}" y="{y1 - 30}" fill="{SUB}" font-size="11" font-weight="700" letter-spacing="1.4">BEATS FIRST, VOICE HELD BACK</text>')
            o("      " + pill(cx(mix["hand"]) + 8, y0 + 16, "NEW VERSE"))
        if "now" in mix and key == mix["out"]["lane"]:
            o(f'      <line x1="{cx(mix["now"]):.1f}" y1="{y0+14}" x2="{cx(mix["now"]):.1f}" y2="{y1-14}" stroke="{ACC}" stroke-opacity="0.6" stroke-dasharray="2 5"/>')
            o(f'      <text x="{cx(mix["now"])+8:.1f}" y="{y1-30}" fill="{ACC}" font-size="11" font-weight="700" letter-spacing="1.4">PRESSED</text>')
    o('    </g></g></g></g>')

# Playhead, beat lights and the lock or own speed badge.
o(f'''    <line x1="{PLAY}" y1="118" x2="{PLAY}" y2="498" stroke="{ACC}" stroke-width="7" stroke-opacity="0.25" filter="url(#bloom)"/>
    <line x1="{PLAY}" y1="118" x2="{PLAY}" y2="498" stroke="{ACC}" stroke-width="2"/>
    <path d="M{PLAY-7},112 h14 l-7,9 z" fill="{ACC}"/>
    <circle class="ring" cx="{PLAY}" cy="{LANES['a'][0]+16}" r="5" fill="none" stroke="{ACC}"/>
    <circle class="beat" cx="{PLAY}" cy="{LANES['a'][0]+16}" r="4.5" fill="{ACC}"/>
    <circle class="ring" cx="{PLAY}" cy="{LANES['b'][0]+16}" r="5" fill="none" stroke="{CREAM}"/>
    <circle class="beat" cx="{PLAY}" cy="{LANES['b'][0]+16}" r="4.5" fill="{CREAM}"/>''')
for index, mix in enumerate(MIXES):
    cls, text = (f"lock{index}", "BEATS LOCKED") if mix["locked"] else (f"own{index}", "OWN SPEEDS")
    o(f'    <g class="{cls}"><rect x="{PLAY-68}" y="297" width="136" height="22" rx="11" fill="#0C0D0F" stroke="{ACC}" stroke-opacity="0.7"/>'
      f'<text x="{PLAY}" y="312" text-anchor="middle" fill="{ACC}" font-size="11" font-weight="700" letter-spacing="1.6">{text}</text></g>')

# The transition panel: name and reason, the effect curve, and what else is happening.
o(f'''    <text x="80" y="548" fill="{SUB}" font-size="12" font-weight="700" letter-spacing="2">TRANSITION</text>
    <text x="{GX}" y="548" fill="{SUB}" font-size="12" font-weight="700" letter-spacing="2">EFFECT, PEAKING AS THE VERSE ENDS</text>
    <line x1="{GX}" y1="{GY1+.5}" x2="{GX+GW}" y2="{GY1+.5}" stroke="#FFFFFF" stroke-opacity="0.12"/>
    <line x1="{GX}" y1="{GY0+.5}" x2="{GX+GW}" y2="{GY0+.5}" stroke="#FFFFFF" stroke-opacity="0.05"/>
    <text x="{GX-10}" y="{GY0+4}" text-anchor="end" fill="{SUB}" font-size="11">100</text>
    <text x="{GX-10}" y="{GY1+4}" text-anchor="end" fill="{SUB}" font-size="11">0</text>
    <text x="940" y="548" fill="{SUB}" font-size="12" font-weight="700" letter-spacing="2">ALSO IN THIS MIX</text>''')
for index, mix in enumerate(MIXES):
    o(f'    <g class="card{index}">')
    o(f'      <text x="80" y="590" fill="{TEXT}" font-size="30" font-weight="800">{mix["name"]}</text>')
    o(f'      <text x="80" y="618" fill="{SUB}" font-size="14">{mix["why"][0]}</text>')
    o(f'      <text x="80" y="638" fill="{SUB}" font-size="14">{mix["why"][1]}</text>')
    o(f'      <text x="80" y="676" fill="{ACC}" font-size="12" font-weight="700" letter-spacing="1.6">MIX {index + 1} OF 3</text>')
    pts, span = [], mix["hand"] - mix["open"]
    for i in range(241):
        t = mix["open"] + span * i / 240
        pts.append((GX + GW * i / 240, GY1 - (GY1 - GY0) * effect(mix, t)))
    line = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    area = line + f" L{GX + GW},{GY1} L{GX},{GY1} Z"
    peak = GX + GW * (mix["voice"] - mix["open"]) / span
    colour = SEA if mix["style"] == "water" else ACC
    o(f'      <line x1="{peak:.1f}" y1="{GY0-6}" x2="{peak:.1f}" y2="{GY1}" stroke="#FFFFFF" stroke-opacity="0.25" stroke-dasharray="3 5"/>')
    rise, fall = mix["voice"] - mix["open"], mix["hand"] - mix["voice"]
    o(f'      <text x="{GX + 4}" y="{GY1 + 22}" fill="{SUB}" font-size="12">{rise:.1f}s up</text>')
    o(f'      <text x="{GX + GW}" y="{GY1 + 22}" text-anchor="end" fill="{SUB}" font-size="12">{fall:.1f}s down</text>')
    o(f'      <text x="{peak:.1f}" y="{GY1 + 22}" text-anchor="middle" fill="{TEXT}" font-size="12" font-weight="600">verse ends</text>')
    o(f'      <g clip-path="url(#draw{index})"><path d="{area}" fill="url(#fx)" opacity="{0.8 if colour == ACC else 0.5}"/>'
      f'<path d="{line}" fill="none" stroke="{colour}" stroke-width="2.6" stroke-linejoin="round" filter="url(#soft)"/></g>')
    o(f'      <rect x="940" y="566" width="260" height="30" rx="15" fill="#0C0D0F" fill-opacity="0.6" stroke="#FFFFFF" stroke-opacity="0.1"/>')
    o(f'      <text x="1070" y="586" text-anchor="middle" fill="{TEXT}" font-size="11.5" font-weight="700" letter-spacing="1.2">{mix["sync"]}</text>')
    o('    </g>')
    for row, (cls, text) in enumerate(((f"split{index}", "VOICES SPLIT BY ON DEVICE AI"), (f"swap{index}", "BASS SWAP ON THE BAR"))):
        y = 606 + row * 40
        o(f'    <g class="card{index}"><rect x="940" y="{y}" width="260" height="30" rx="15" fill="#0C0D0F" fill-opacity="0.6" stroke="#FFFFFF" stroke-opacity="0.1"/>'
          f'<text x="1070" y="{y + 20}" text-anchor="middle" fill="{SUB}" font-size="11.5" font-weight="700" letter-spacing="1.2">{text}</text></g>')
        o(f'    <g class="{cls}"><rect x="940" y="{y}" width="260" height="30" rx="15" fill="{ACC}" fill-opacity="0.2" stroke="{ACC}" stroke-opacity="0.8"/>'
          f'<text x="1070" y="{y + 20}" text-anchor="middle" fill="{ACC}" font-size="11.5" font-weight="700" letter-spacing="1.2">{text}</text></g>')

o('    </g>')
o('  </g>\n</svg>')
open(sys.argv[1], "w").write("\n".join(out))
