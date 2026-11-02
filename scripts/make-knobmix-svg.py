"""Builds docs/images/knobmix.svg (python3 scripts/make-knobmix-svg.py docs/images/knobmix.svg): a 14 second looping KnobMix, drawn so every waveform bar,
voice line and caption lines up with the same timeline."""
import math, random, sys

W, H = 1280, 760
LOOP = 14.0
PX = 110.0                 # pixels per second of song
VX, VW = 300, 900          # waveform window
PLAY = 600                 # playhead x
OFFSET = 1.0               # song time under the playhead at the start of the loop
OPEN, VOICE_END, HANDOFF = 3.8, 5.2, 9.0   # song times
DRAW = 12.6                # seconds the mix curves take to draw
LANES = {"a": (120, 300), "b": (320, 500)}
ACC, ACC2, CREAM, TEXT, SUB = "#FF8A3D", "#FF6B1F", "#F3E3CF", "#EDEEF0", "#9A9EA5"

def t_scene(song_t): return song_t - OFFSET
def pct(t): return f"{max(0, min(100, t / LOOP * 100)):.2f}%"
def cx(song_t): return song_t * PX     # content x; group is shifted so the playhead sits right

out = []
o = out.append
rnd = random.Random(7)

o(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">
  <title id="t">How a KnobMix works</title>
  <desc id="d">Two decks play the songs. KnobShift listens for the voice, the drums and the breaks. The old singer finishes the last line while the new song's beats slide in underneath with its voice held back, the beats lock together, the old song slows and fades, and the new verse lands just as the old song leaves.</desc>
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3B3E43"/><stop offset="1" stop-color="#151619"/></linearGradient>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2C2E33"/><stop offset="1" stop-color="#1D1F22"/></linearGradient>
    <linearGradient id="screen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#16171A"/><stop offset="1" stop-color="#0C0D0F"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.14"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0.03"/></linearGradient>
    <linearGradient id="barA" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFB27A"/><stop offset="0.5" stop-color="{ACC}"/><stop offset="1" stop-color="{ACC2}" stop-opacity="0.55"/></linearGradient>
    <linearGradient id="barB" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="{CREAM}"/><stop offset="1" stop-color="{CREAM}" stop-opacity="0.45"/></linearGradient>
    <linearGradient id="edge" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="0.09" stop-color="#fff"/>
      <stop offset="0.91" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <mask id="fade" maskUnits="userSpaceOnUse" x="{VX}" y="0" width="{VW}" height="{H}"><rect x="{VX}" y="0" width="{VW}" height="{H}" fill="url(#edge)"/></mask>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{ACC}" stop-opacity="0.30"/><stop offset="1" stop-color="{ACC}" stop-opacity="0"/></radialGradient>
    <radialGradient id="vinyl" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#2A2C30"/><stop offset="0.7" stop-color="#101113"/><stop offset="1" stop-color="#050506"/></radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0.3" stop-color="#fff" stop-opacity="0"/><stop offset="0.5" stop-color="#fff" stop-opacity="0.16"/><stop offset="0.7" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="11"/><feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.05 0"/></filter>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.45"/></filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3.5" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
    <filter id="bloom" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="7"/></filter>
    <clipPath id="frame"><rect width="{W}" height="{H}" rx="28"/></clipPath>
    <clipPath id="viewA"><rect x="{VX}" y="{LANES['a'][0]+8}" width="{VW}" height="{LANES['a'][1]-LANES['a'][0]-16}"/></clipPath>
    <clipPath id="viewB"><rect x="{VX}" y="{LANES['b'][0]+8}" width="{VW}" height="{LANES['b'][1]-LANES['b'][0]-16}"/></clipPath>
    <clipPath id="drawn"><rect x="{VX}" y="540" width="0" height="120">
      <animate attributeName="width" values="0;{VW};{VW}" keyTimes="0;{DRAW/LOOP:.4f};1" dur="{LOOP}s" repeatCount="indefinite"/>
    </rect></clipPath>
  </defs>''')

# Motion, all on one 14 second clock.
scroll0 = PLAY - VX - OFFSET * PX
scroll1 = PLAY - VX - (OFFSET + LOOP) * PX
def curve_keys(name, fn, samples=24, start=0.0, end=LOOP):
    keys = []
    for i in range(samples + 1):
        t = start + (end - start) * i / samples
        keys.append(f"{pct(t)} {{ {fn(t)} }}")
    return f"@keyframes {name} {{ " + " ".join(keys) + " }"

def volA(t):
    s0, s1 = t_scene(OPEN), t_scene(HANDOFF)
    if t <= s0: v = 1
    elif t >= s1: v = 0
    else: v = math.cos((t - s0) / (s1 - s0) * math.pi / 2)
    return f"transform: scaleY({v:.3f})"
def volB(t):
    s0, s1 = t_scene(OPEN), t_scene(HANDOFF)
    if t <= s0: v = 0
    elif t >= s1: v = 1
    else: v = math.sin((t - s0) / (s1 - s0) * math.pi / 2)
    return f"transform: scaleY({v:.3f})"

o(f'''  <style>
    .scroll {{ animation: scroll {LOOP}s linear infinite; }}
    @keyframes scroll {{ from {{ transform: translateX({scroll0:.1f}px); }} to {{ transform: translateX({scroll1:.1f}px); }} }}
    .scene {{ animation: scene {LOOP}s ease-in-out infinite; }}
    @keyframes scene {{ 0% {{ opacity: 0; }} 4% {{ opacity: 1; }} 93% {{ opacity: 1; }} 100% {{ opacity: 0; }} }}
    .spin {{ transform-box: fill-box; transform-origin: center; }}
    .spinA {{ animation: spinA {LOOP}s infinite; }}
    @keyframes spinA {{
      0% {{ transform: rotate(0deg); animation-timing-function: linear; }}
      {pct(t_scene(VOICE_END))} {{ transform: rotate({240 * t_scene(VOICE_END):.0f}deg); animation-timing-function: cubic-bezier(0.2, 0.6, 0.35, 1); }}
      {pct(t_scene(HANDOFF))} {{ transform: rotate({240 * t_scene(VOICE_END) + 300:.0f}deg); }}
      100% {{ transform: rotate({240 * t_scene(VOICE_END) + 300:.0f}deg); }}
    }}
    .spinB {{ animation: spinB {LOOP}s infinite; }}
    @keyframes spinB {{
      0% {{ transform: rotate(0deg); }}
      {pct(t_scene(OPEN))} {{ transform: rotate(0deg); animation-timing-function: cubic-bezier(0.55, 0, 0.75, 0.4); }}
      {pct(t_scene(HANDOFF))} {{ transform: rotate(520deg); animation-timing-function: linear; }}
      100% {{ transform: rotate({520 + 240 * (LOOP - t_scene(HANDOFF)):.0f}deg); }}
    }}
    .vol {{ transform-box: fill-box; transform-origin: bottom; }}
    .volA {{ animation: volA {LOOP}s linear infinite; }}
    .volB {{ animation: volB {LOOP}s linear infinite; }}
    {curve_keys("volA", volA)}
    {curve_keys("volB", volB)}
    .rimA {{ animation: rimA {LOOP}s ease-in-out infinite; }}
    @keyframes rimA {{ 0%, {pct(t_scene(OPEN))} {{ stroke-opacity: 0.85; }} {pct(t_scene(HANDOFF))}, 100% {{ stroke-opacity: 0.08; }} }}
    .rimB {{ animation: rimB {LOOP}s ease-in-out infinite; }}
    @keyframes rimB {{ 0%, {pct(t_scene(OPEN))} {{ stroke-opacity: 0.08; }} {pct(t_scene(HANDOFF))}, 100% {{ stroke-opacity: 0.85; }} }}
    .dimA {{ animation: dimA {LOOP}s ease-in-out infinite; }}
    @keyframes dimA {{ 0%, {pct(t_scene(OPEN))} {{ opacity: 1; }} {pct(t_scene(HANDOFF))}, 100% {{ opacity: 0.35; }} }}
    .dimB {{ animation: dimB {LOOP}s ease-in-out infinite; }}
    @keyframes dimB {{ 0%, {pct(t_scene(OPEN) - 0.2)} {{ opacity: 0.35; }} {pct(t_scene(OPEN) + 0.6)}, 100% {{ opacity: 1; }} }}
    .beat {{ transform-box: fill-box; transform-origin: center; animation: beat 0.5s cubic-bezier(0.2, 0.7, 0.3, 1) infinite; }}
    @keyframes beat {{ 0% {{ transform: scale(1.5); opacity: 1; }} 70% {{ transform: scale(0.85); opacity: 0.35; }} 100% {{ transform: scale(0.85); opacity: 0.35; }} }}
    .ring {{ transform-box: fill-box; transform-origin: center; animation: ring 0.5s ease-out infinite; }}
    @keyframes ring {{ 0% {{ transform: scale(0.6); opacity: 0.8; }} 100% {{ transform: scale(2.6); opacity: 0; }} }}
''')

def window(name, start, end, fade=0.35):
    """Visible from scene time start to end, easing in and out."""
    return (f".{name} {{ animation: {name} {LOOP}s ease-in-out infinite; }} "
            f"@keyframes {name} {{ 0%, {pct(start - fade)} {{ opacity: 0; transform: translateY(6px); }} "
            f"{pct(start)}, {pct(end)} {{ opacity: 1; transform: translateY(0); }} "
            f"{pct(end + fade)}, 100% {{ opacity: 0; transform: translateY(-4px); }} }}")

steps = [
    ("listen", 0.2, t_scene(OPEN)),
    ("last", t_scene(OPEN), t_scene(VOICE_END) + 0.4),
    ("slide", t_scene(VOICE_END) + 0.4, t_scene(HANDOFF)),
    ("lands", t_scene(HANDOFF), 12.8),
]
for name, a, b in steps:
    o(f"    .n_{name} {{ animation: n_{name} {LOOP}s ease-in-out infinite; }} "
      f"@keyframes n_{name} {{ 0%, {pct(a - 0.3)} {{ fill-opacity: 0.12; }} {pct(a)}, {pct(b)} {{ fill-opacity: 1; }} {pct(b + 0.3)}, 100% {{ fill-opacity: 0.12; }} }}")
o("    " + window("tape", t_scene(VOICE_END), t_scene(HANDOFF)))
o("    " + window("hold", t_scene(OPEN), t_scene(HANDOFF) - 0.1))
o("    " + window("lock", t_scene(OPEN) + 0.3, 12.8))
o("    " + window("ledB", t_scene(OPEN), 13.4, 0.25))
o("  </style>")

o(f'''
  <g clip-path="url(#frame)" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
    <rect width="{W}" height="{H}" fill="url(#plate)"/>
    <rect width="{W}" height="{H}" filter="url(#grain)"/>
    <ellipse cx="{PLAY}" cy="310" rx="520" ry="230" fill="url(#glow)"/>
    <rect width="{W}" height="1.5" fill="#FFFFFF" fill-opacity="0.12"/>

    <text x="56" y="62" fill="{ACC}" font-size="15" font-weight="700" letter-spacing="3">KNOBMIX</text>
    <text x="56" y="98" fill="{TEXT}" font-size="28" font-weight="700">The old singer finishes the line. The new verse lands on the beat.</text>
''')

# Lane cards.
o('    <g filter="url(#drop)">')
for key, (y0, y1) in LANES.items():
    o(f'      <rect x="56" y="{y0}" width="1168" height="{y1-y0}" rx="22" fill="url(#card)"/>')
o('      <rect x="56" y="526" width="1168" height="208" rx="22" fill="url(#card)"/>')
o('    </g>')
for key, (y0, y1) in LANES.items():
    o(f'    <rect x="56.5" y="{y0+.5}" width="1167" height="{y1-y0-1}" rx="22" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>')
    o(f'    <rect class="rim{key.upper()}" x="56.5" y="{y0+.5}" width="1167" height="{y1-y0-1}" rx="22" fill="none" stroke="{ACC2}" stroke-width="1.5"/>')
    o(f'    <rect x="{VX}" y="{y0+8}" width="{VW}" height="{y1-y0-16}" rx="14" fill="url(#screen)" stroke="#FFFFFF" stroke-opacity="0.06"/>')
o('    <rect x="56.5" y="526.5" width="1167" height="207" rx="22" fill="url(#rim)" stroke="#FFFFFF" stroke-opacity="0.07"/>')

o('    <g class="scene">')

# Decks.
for key, (y0, y1) in LANES.items():
    mid = (y0 + y1) / 2
    label, title = ("DECK 1", "Now playing") if key == "a" else ("DECK 2", "Up next")
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
    o(f'      <text x="212" y="{mid-12}" fill="{ACC if key == "a" else SUB}" font-size="12" font-weight="700" letter-spacing="2">{label}</text>')
    o(f'      <text x="212" y="{mid+12}" fill="{TEXT}" font-size="17" font-weight="700">{title.split()[0]}</text>')
    o(f'      <text x="212" y="{mid+32}" fill="{TEXT}" font-size="17" font-weight="700">{title.split()[1]}</text>')
    o('    </g>')
    # Volume meter beside the window.
    o(f'    <rect x="279" y="{y0+22}" width="6" height="{y1-y0-44}" rx="3" fill="#0C0D0F" stroke="#FFFFFF" stroke-opacity="0.06"/>')
    o(f'    <rect class="vol vol{key.upper()}" x="279" y="{y0+22}" width="6" height="{y1-y0-44}" rx="3" fill="{ACC if key == "a" else CREAM}" filter="url(#soft)"/>')

# Waveforms, voice and markers, scrolling past the playhead.
def bars(key, y0, y1):
    mid = (y0 + y1) / 2
    maxh = (y1 - y0) - 44
    parts = []
    t = -2.0
    while t < 21.0:
        beat_phase = (t % 0.5) / 0.5
        kick = 0.55 + 0.45 * math.exp(-beat_phase * 5)
        n = 0.75 + 0.25 * rnd.random()
        if key == "a":
            if t < OPEN: env = 1.0
            elif t < HANDOFF: env = 0.9 * math.cos((t - OPEN) / (HANDOFF - OPEN) * math.pi / 2) + 0.04
            else: env = 0
        else:
            if t < OPEN: env = 0
            elif t < HANDOFF: env = 0.2 + 0.6 * math.sin((t - OPEN) / (HANDOFF - OPEN) * math.pi / 2)
            else: env = 1.0
        h = maxh * env * kick * n
        if h > 2:
            parts.append(f'<rect x="{cx(t):.1f}" y="{mid - h/2:.1f}" width="5" height="{h:.1f}" rx="2.5"/>')
        t += 0.1
    return f'<g fill="url(#bar{key.upper()})" fill-opacity="0.85">' + "".join(parts) + "</g>"

def voice(y0, y1, start, end, seed, amp=30):
    mid = (y0 + y1) / 2
    r = random.Random(seed)
    pts = []
    t = start
    while t <= end + 1e-6:
        syll = 0.45 + 0.55 * abs(math.sin(t * 5.3 + r.random() * 0.4))
        fade = min(1, (t - start) / 0.4, (end - t) / 0.4) if end - start > 0.8 else 1
        y = mid + amp * fade * syll * math.sin(t * 9.0)
        pts.append((cx(t), y))
        t += 0.05
    d = f"M{pts[0][0]:.1f},{pts[0][1]:.1f} " + " ".join(f"L{x:.1f},{y:.1f}" for x, y in pts[1:])
    return d

for key, (y0, y1) in LANES.items():
    mid = (y0 + y1) / 2
    o(f'    <g clip-path="url(#view{key.upper()})"><g mask="url(#fade)"><g transform="translate({VX} 0)"><g class="scroll">')
    # beat grid
    ticks = []
    t = -2.0
    while t < 21:
        big = abs((t / 2) - round(t / 2)) < 1e-6
        ticks.append(f'<rect x="{cx(t):.1f}" y="{y1-22 if big else y1-17}" width="1.5" height="{12 if big else 7}" fill="#FFFFFF" fill-opacity="{0.22 if big else 0.1}"/>')
        t += 0.5
    o("      " + "".join(ticks))
    o("      " + bars(key, y0, y1))
    for at, name in ((OPEN, "MIX OPENS"), (HANDOFF, "HANDOFF")):
        o(f'      <line x1="{cx(at):.1f}" y1="{y0+14}" x2="{cx(at):.1f}" y2="{y1-14}" stroke="#FFFFFF" stroke-opacity="0.28" stroke-dasharray="4 6"/>')
        if key == "a":
            o(f'      <text x="{cx(at)+8:.1f}" y="{y0+30}" fill="{SUB}" font-size="11" font-weight="700" letter-spacing="1.6">{name}</text>')
    if key == "a":
        o(f'      <path d="{voice(y0, y1, -2.0, OPEN, 3)}" fill="none" stroke="#FFFFFF" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" filter="url(#soft)" opacity="0.92"/>')
        o(f'      <path d="{voice(y0, y1, OPEN, VOICE_END, 4, 34)}" fill="none" stroke="#FFE3C7" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round" filter="url(#soft)"/>')
        o(f'      <rect x="{cx(OPEN)+8:.1f}" y="{y1-52}" width="92" height="22" rx="11" fill="{ACC}" fill-opacity="0.18" stroke="{ACC}" stroke-opacity="0.6"/>')
        o(f'      <text x="{cx(OPEN)+54:.1f}" y="{y1-37}" text-anchor="middle" fill="{ACC}" font-size="11" font-weight="700" letter-spacing="1.4">LAST LINE</text>')
    else:
        o(f'      <path d="{voice(y0, y1, HANDOFF, 21.0, 9)}" fill="none" stroke="#FFFFFF" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" filter="url(#soft)" opacity="0.92"/>')
        o(f'      <rect x="{cx(HANDOFF)+8:.1f}" y="{y0+18}" width="96" height="22" rx="11" fill="{ACC}" fill-opacity="0.18" stroke="{ACC}" stroke-opacity="0.6"/>')
        o(f'      <text x="{cx(HANDOFF)+56:.1f}" y="{y0+33}" text-anchor="middle" fill="{ACC}" font-size="11" font-weight="700" letter-spacing="1.4">NEW VERSE</text>')
        o(f'      <text x="{cx(OPEN)+10:.1f}" y="{y1-30}" fill="{SUB}" font-size="11" font-weight="700" letter-spacing="1.4">BEATS ONLY, VOICE HELD BACK</text>')
    o('    </g></g></g></g>')

# Playhead and beat lights.
o(f'''    <line x1="{PLAY}" y1="112" x2="{PLAY}" y2="508" stroke="{ACC}" stroke-width="7" stroke-opacity="0.25" filter="url(#bloom)"/>
    <line x1="{PLAY}" y1="112" x2="{PLAY}" y2="508" stroke="{ACC}" stroke-width="2"/>
    <path d="M{PLAY-7},106 h14 l-7,9 z" fill="{ACC}"/>
    <g>
      <circle class="ring" cx="{PLAY}" cy="{LANES['a'][0]+16}" r="5" fill="none" stroke="{ACC}"/>
      <circle class="beat" cx="{PLAY}" cy="{LANES['a'][0]+16}" r="4.5" fill="{ACC}"/>
    </g>
    <g class="ledB">
      <circle class="ring" cx="{PLAY}" cy="{LANES['b'][0]+16}" r="5" fill="none" stroke="{CREAM}"/>
      <circle class="beat" cx="{PLAY}" cy="{LANES['b'][0]+16}" r="4.5" fill="{CREAM}"/>
    </g>
    <g class="lock">
      <rect x="{PLAY-68}" y="299" width="136" height="22" rx="11" fill="#0C0D0F" stroke="{ACC}" stroke-opacity="0.7"/>
      <text x="{PLAY}" y="314" text-anchor="middle" fill="{ACC}" font-size="11" font-weight="700" letter-spacing="1.6">BEATS LOCKED</text>
    </g>
    <g class="tape">
      <rect x="1060" y="{LANES['a'][0]+14}" width="146" height="24" rx="12" fill="#0C0D0F" fill-opacity="0.85" stroke="#FFFFFF" stroke-opacity="0.15"/>
      <text x="1133" y="{LANES['a'][0]+30}" text-anchor="middle" fill="{TEXT}" font-size="11" font-weight="700" letter-spacing="1.4">TAPE SLOWDOWN</text>
    </g>
    <g class="hold">
      <rect x="1036" y="{LANES['b'][1]-38}" width="170" height="24" rx="12" fill="#0C0D0F" fill-opacity="0.85" stroke="#FFFFFF" stroke-opacity="0.15"/>
      <text x="1121" y="{LANES['b'][1]-22}" text-anchor="middle" fill="{TEXT}" font-size="11" font-weight="700" letter-spacing="1.4">AI SPLITS THE VOICE</text>
    </g>''')

# The mix: crossfade curves drawn in time, and the four steps.
def curve(fn):
    pts = []
    # Drawn over the same 12.6 seconds as the reveal and the cursor below.
    for i in range(141):
        t = DRAW * i / 140
        x = VX + VW * t / DRAW
        pts.append((x, 640 - 92 * fn(t)))
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
def a_level(t):
    s0, s1 = t_scene(OPEN), t_scene(HANDOFF)
    return 1 if t <= s0 else 0 if t >= s1 else math.cos((t - s0) / (s1 - s0) * math.pi / 2)
def b_level(t):
    s0, s1 = t_scene(OPEN), t_scene(HANDOFF)
    return 0 if t <= s0 else 1 if t >= s1 else math.sin((t - s0) / (s1 - s0) * math.pi / 2)
o(f'''    <text x="80" y="566" fill="{SUB}" font-size="12" font-weight="700" letter-spacing="2">THE MIX</text>
    <line x1="80" y1="596" x2="104" y2="596" stroke="{ACC}" stroke-width="3" stroke-linecap="round"/>
    <text x="114" y="601" fill="{TEXT}" font-size="15">Now playing</text>
    <line x1="80" y1="624" x2="104" y2="624" stroke="{CREAM}" stroke-width="3" stroke-linecap="round"/>
    <text x="114" y="629" fill="{TEXT}" font-size="15">Up next</text>
    <line x1="{VX}" y1="640.5" x2="{VX+VW}" y2="640.5" stroke="#FFFFFF" stroke-opacity="0.1"/>
    <line x1="{VX}" y1="548.5" x2="{VX+VW}" y2="548.5" stroke="#FFFFFF" stroke-opacity="0.05"/>
    <g clip-path="url(#drawn)" fill="none" stroke-linecap="round" stroke-linejoin="round">
      <path d="{curve(a_level)}" stroke="{ACC}" stroke-width="3" filter="url(#soft)"/>
      <path d="{curve(b_level)}" stroke="{CREAM}" stroke-width="3" filter="url(#soft)"/>
    </g>
    <g>
      <line x1="{VX}" y1="548" x2="{VX}" y2="642" stroke="#FFFFFF" stroke-opacity="0.35">
        <animateTransform attributeName="transform" type="translate" values="0 0;{VW} 0;{VW} 0" keyTimes="0;{DRAW/LOOP:.4f};1" dur="{LOOP}s" repeatCount="indefinite"/>
      </line>
    </g>''')

labels = [
    ("listen", "1", "Listens first", "Voice, drums and breaks"),
    ("last", "2", "Last line", "The old singer finishes"),
    ("slide", "3", "Beats slide in", "New voice waits its turn"),
    ("lands", "4", "Verse lands", "Just as the old song leaves"),
]
for i, (name, num, head, sub) in enumerate(labels):
    x = 80 + i * 286
    o(f'''    <g>
      <rect class="n_{name}" x="{x}" y="664" width="270" height="54" rx="14" fill="{ACC}"/>
      <rect x="{x}.5" y="664.5" width="269" height="53" rx="14" fill="none" stroke="#FFFFFF" stroke-opacity="0.08"/>
      <circle cx="{x+27}" cy="691" r="13" fill="#0C0D0F" fill-opacity="0.55"/>
      <text x="{x+27}" y="696" text-anchor="middle" fill="{TEXT}" font-size="14" font-weight="700">{num}</text>
      <text x="{x+50}" y="687" fill="{TEXT}" font-size="15" font-weight="700">{head}</text>
      <text x="{x+50}" y="706" fill="{TEXT}" fill-opacity="0.75" font-size="12.5">{sub}</text>
    </g>''')

o('    </g>')  # scene
o('  </g>\n</svg>')
open(sys.argv[1], "w").write("\n".join(out))
