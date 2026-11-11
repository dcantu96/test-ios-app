#!/usr/bin/env python3
"""Compose a demo MP4 from a raw iOS Simulator recording.

The demo UI test (UITests-Demo/) drives the app like a person and writes markers.json:
when each chapter starts (caption text), where each tap lands, which stretches to
fast-forward. This script draws the board (sky, phone, captions, tap ripples) with
Pillow, warps time with ffmpeg, and encodes a 1920x1080 H.264 MP4.

    python3 demo/compose.py --recording raw.mp4 --markers markers.json --out demo.mp4 \
        [--footer "PR #3 · branch · abc1234"] [--quality high|draft]

markers.json:
{
  "recordingStart": <epoch seconds when the recording's first frame was taken>,
  "events": [
    {"t": <epoch>, "kind": "chapter", "style": "title"|"step"|"end", "kicker": "...", "title": "...", "sub": "...", "chip": "..."},
    {"t": <epoch>, "kind": "tap", "x": 0..1, "y": 0..1, "w": 0..1, "h": 0..1, "pre": <epoch>},
                                       # the tapped element (centre and size, normalized); the touch lands in [pre, t]
    {"t": <epoch>, "kind": "type", "until": <epoch>, "x", "y", "w", "h"},  # one typeText call into that element
    {"t": <epoch>, "kind": "hold", "until": <epoch>},               # a deliberate pause: never trimmed
    {"t": <epoch>, "kind": "speed", "until": <epoch>, "factor": 4},  # fast-forward this stretch
    {"t": <epoch>, "kind": "cut", "until": <epoch>},                # drop this stretch (a quick dip hides the join)
    {"t": <epoch>, "kind": "end"}
  ],
  "synced": true                       # optional: recordingStart is exact, skip the automatic sync
}

What it fixes on its own (see "Demo videos" in CLAUDE.md for why):
- Sync. The recording's first frame can come many seconds after simctl says "Recording started" (an idle
  Simulator sends no frames), so `recordingStart` alone put captions and ripples 9-35 s off. The script
  finds the offset from the taps and typing: at the right offset each one changes the screen on its own
  element, and the screen is still just before it (XCUITest waits for the app to go quiet before acting;
  home-screen widgets and app launches don't). Checked on four real recordings.
- Dead air. XCUITest spends seconds finding each element and typing each word on a busy Simulator. Stretches
  where the screen doesn't change, outside "hold" (a deliberate pause), "speed" and "cut", are trimmed to
  a quarter second. Each chapter keeps enough time to read its caption.
"""
import argparse
import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
# FFMPEG: an ffmpeg with libx264. In CI it's the static build from the imageio-ffmpeg wheel (pip, seconds) rather than apt (half a minute).
FFMPEG = os.environ.get("FFMPEG") or shutil.which("ffmpeg") or "ffmpeg"
FONTS = os.path.join(HERE, "fonts")

W, H, FPS = 1920, 1080, 60
# Palette ("Dusk"): ground, main, ink, accent.
GROUND, MAIN, INK, ACCENT = (27, 19, 64), (139, 92, 246), (245, 243, 255), (251, 146, 60)

# The phone. The screen keeps the Simulator's aspect ratio (1206x2622).
SCREEN_W, SCREEN_H = 450, 978
BEZEL = 16
PHONE_X, PHONE_Y = 1258, (H - (SCREEN_H + 2 * BEZEL)) // 2
SCREEN_X, SCREEN_Y = PHONE_X + BEZEL, PHONE_Y + BEZEL
SCREEN_R = 62
TEXT_X, TEXT_W = 140, 1040


def mix(a, b, p):
    return tuple(round(a[i] * (1 - p) + b[i] * p) for i in range(3))


def font(name, size, weight):
    f = ImageFont.truetype(os.path.join(FONTS, name), size)
    try:
        axes = f.get_variation_axes()
        vals = [weight if ax["name"] == b"Weight" else (min(max(size / 2, ax["minimum"]), ax["maximum"]) if ax["name"] == b"Optical size" else ax["default"]) for ax in axes]
        f.set_variation_by_axes(vals)
    except OSError:
        pass
    return f


# ── the board ──────────────────────────────────────────────────────────────────

def draw_background(path):
    """Dusk sky with star trails turning about a pole above the frame, low hills, the phone body and its shadow."""
    S = 2  # draw at 2x, then downsample: smooth arcs and edges
    img = Image.new("RGB", (W * S, H * S))
    px = img.load()
    dusk = mix(GROUND, MAIN, 0.2)
    horizon = mix(dusk, ACCENT, 0.34)
    for y in range(H * S):
        p = y / (H * S)
        c = mix(GROUND, dusk, p / 0.58) if p < 0.58 else mix(dusk, horizon, (p - 0.58) / 0.42)
        for x in range(W * S):
            px[x, y] = c
    d = ImageDraw.Draw(img, "RGBA")
    rng = random.Random(11)
    pole = (300 * S, -700 * S)
    # Trails crossing the caption column read as strikethroughs on the text, so none may pass through it.
    keep_out = (TEXT_X - 60, 200, TEXT_X + TEXT_W + 60, 880)
    placed = 0
    for _ in range(600):
        if placed >= 46:
            break
        rad = (820 + rng.random() * 1500) * S
        a0 = math.pi * (0.12 + rng.random() * 0.8)
        length = 0.04 + rng.random() * 0.09
        width = max(2, int((1.4 + rng.random() * 2.2) * S))
        alpha = int(255 * (0.14 + rng.random() * 0.34))
        pts = [(pole[0] / S + rad / S * math.cos(a0 + length * i / 12), pole[1] / S + rad / S * math.sin(a0 + length * i / 12)) for i in range(13)]
        if any(keep_out[0] <= x <= keep_out[2] and keep_out[1] <= y <= keep_out[3] for x, y in pts):
            continue
        if not any(0 <= x <= W and 0 <= y <= H for x, y in pts):
            continue
        placed += 1
        box = [pole[0] - rad, pole[1] - rad, pole[0] + rad, pole[1] + rad]
        d.arc(box, math.degrees(a0), math.degrees(a0 + length), fill=INK + (alpha,), width=width)
        hx, hy = pole[0] + rad * math.cos(a0 + length), pole[1] + rad * math.sin(a0 + length)
        r = width * 0.9
        d.ellipse([hx - r, hy - r, hx + r, hy + r], fill=INK + (min(255, alpha + 70),))
    # glow and hills
    glow = Image.new("L", (W * S, H * S), 0)
    ImageDraw.Draw(glow).ellipse([180 * S, 840 * S, 2380 * S, 1180 * S], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(60 * S))
    img.paste(Image.new("RGB", img.size, ACCENT), (0, 0), glow)
    d = ImageDraw.Draw(img, "RGBA")
    d.polygon(hill(968, 18, 0.9, S), fill=mix(GROUND, MAIN, 0.2))
    d.polygon(hill(1012, 12, 1.7, S), fill=mix(GROUND, INK, 0.18))
    img = img.resize((W, H), Image.LANCZOS)

    # phone shadow, then the body (the screen goes on top in ffmpeg)
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([PHONE_X + 10, PHONE_Y + 40, PHONE_X + SCREEN_W + 2 * BEZEL - 10, PHONE_Y + SCREEN_H + 2 * BEZEL + 30], radius=SCREEN_R + BEZEL, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(38))
    img.paste(Image.new("RGB", (W, H), (8, 5, 20)), (0, 0), shadow)
    body = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    x0, y0 = PHONE_X * S, PHONE_Y * S
    x1, y1 = (PHONE_X + SCREEN_W + 2 * BEZEL) * S, (PHONE_Y + SCREEN_H + 2 * BEZEL) * S
    rim = mix(mix(GROUND, MAIN, 0.3), INK, 0.35)
    frame = mix(GROUND, MAIN, 0.3)
    bd.rounded_rectangle([x0 - 2 * S, y0 - 2 * S, x1 + 2 * S, y1 + 2 * S], radius=(SCREEN_R + BEZEL + 2) * S, fill=rim)
    bd.rounded_rectangle([x0, y0, x1, y1], radius=(SCREEN_R + BEZEL) * S, fill=frame)
    bd.rounded_rectangle([x0 + 5 * S, y0 + 5 * S, x1 - 5 * S, y1 - 5 * S], radius=(SCREEN_R + BEZEL - 5) * S, fill=mix(frame, GROUND, 0.45))
    for (bx, by, bh) in [(x0 - 5 * S, y0 + 210 * S, 64), (x0 - 5 * S, y0 + 300 * S, 104), (x1, y0 + 260 * S, 146)]:
        bd.rounded_rectangle([bx, by, bx + 5 * S, by + bh * S], radius=3 * S, fill=frame)
    body = body.resize((W, H), Image.LANCZOS)
    img = img.convert("RGBA")
    img.alpha_composite(body)
    img.convert("RGB").save(path)


def hill(base, amp, freq, S):
    pts = [(0, H * S)]
    for i in range(0, 97):
        x = W * i / 96
        y = base + amp * math.sin(x / W * math.pi * 2 * freq + 0.6) + amp * 0.5 * math.sin(x / W * math.pi * 5.3)
        pts.append((x * S, y * S))
    pts.append((W * S, H * S))
    return pts


def draw_screen_mask(path):
    S = 4
    m = Image.new("L", (SCREEN_W * S, SCREEN_H * S), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, SCREEN_W * S - 1, SCREEN_H * S - 1], radius=SCREEN_R * S, fill=255)
    m.resize((SCREEN_W, SCREEN_H), Image.LANCZOS).save(path)


def draw_ripple(path):
    S = 4
    size = 140
    im = Image.new("RGBA", (size * S, size * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = size * S / 2
    d.ellipse([c - 62 * S, c - 62 * S, c + 62 * S, c + 62 * S], outline=INK + (235,), width=6 * S)
    d.ellipse([c - 30 * S, c - 30 * S, c + 30 * S, c + 30 * S], fill=INK + (120,))
    im.resize((size, size), Image.LANCZOS).save(path)


def wrap(draw, text, f, width):
    """Greedy wrap to find the line count, then balance: the same number of lines with the shortest longest
    line, so a headline never ends on one stranded word ("Write it. Pick when it / opens.")."""
    words, lines, line = text.split(), [], ""
    for w in words:
        trial = (line + " " + w).strip()
        if draw.textlength(trial, font=f) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = w
    if line:
        lines.append(line)
    n = len(lines)
    if n < 2:
        return lines
    best = None

    def split(i, k):  # words[i:] into k lines
        if k == 1:
            ln = " ".join(words[i:])
            return [ln] if draw.textlength(ln, font=f) <= width else None
        out = None
        for j in range(i + 1, len(words) - k + 2):
            head = " ".join(words[i:j])
            if draw.textlength(head, font=f) > width:
                break
            rest = split(j, k - 1)
            if rest:
                cand = [head] + rest
                if out is None or max(draw.textlength(x, font=f) for x in cand) < max(draw.textlength(x, font=f) for x in out):
                    out = cand
        return out

    if len(words) <= 24:
        best = split(0, n)
    return best or lines


def draw_caption(path, ev):
    """One caption block, left of the phone, vertically centred. Transparent PNG at full frame size."""
    style = ev.get("style", "step")
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    big = style in ("title", "end")
    f_kick = font("Inter.ttf", 26, 700)
    f_title = font("SpaceGrotesk.ttf", 140 if big else 92, 700)
    f_sub = font("Inter.ttf", 38 if big else 36, 400)
    f_chip = font("Inter.ttf", 30, 500)
    blocks = []  # (kind, lines, font, color, gap_after)
    if ev.get("kicker"):
        blocks.append(("kick", [ev["kicker"].upper()], f_kick, ACCENT, 26))
    blocks.append(("title", wrap(d, ev["title"], f_title, TEXT_W), f_title, INK, 30))
    if style == "end":
        blocks.append(("rule", [], None, ACCENT, 34))
    if ev.get("sub"):
        blocks.append(("sub", wrap(d, ev["sub"], f_sub, 860), f_sub, mix(INK, GROUND, 0.18), 30))
    if ev.get("chip"):
        blocks.append(("chip", [ev["chip"]], f_chip, INK, 0))

    def line_h(f):
        a, b = f.getmetrics()
        return a + b

    total = 0
    for kind, lines, f, _, gap in blocks:
        total += 10 if kind == "rule" else (74 if kind == "chip" else int(line_h(f) * (0.98 if kind == "title" else 1.12)) * len(lines))
        total += gap
    y = (H - total) // 2 - 10
    for kind, lines, f, color, gap in blocks:
        if kind == "rule":
            d.rounded_rectangle([TEXT_X, y, TEXT_X + 440, y + 10], radius=5, fill=ACCENT)
            y += 10 + gap
            continue
        if kind == "chip":
            tw = d.textlength(lines[0], font=f)
            d.rounded_rectangle([TEXT_X, y, TEXT_X + tw + 52, y + 64], radius=18, fill=mix(GROUND, INK, 0.12), outline=ACCENT, width=2)
            d.text((TEXT_X + 26, y + 32), lines[0], font=f, fill=color, anchor="lm")
            y += 74 + gap
            continue
        step = int(line_h(f) * (0.98 if kind == "title" else 1.12))
        for ln in lines:
            if kind == "kick":
                x = TEXT_X
                for ch in ln:  # letter-spaced
                    d.text((x, y), ch, font=f, fill=color)
                    x += d.textlength(ch, font=f) + 4
            else:
                d.text((TEXT_X, y), ln, font=f, fill=color)
            y += step
        y += gap
    box = im.getbbox() or (0, 0, 2, 2)
    box = (max(0, box[0] - 4), max(0, box[1] - 4), min(W, box[2] + 4), min(H, box[3] + 4))
    im.crop(box).save(path)
    return box[0], box[1]


def draw_footer(bg_path, text):
    """The run's details, small along the bottom: baked into the background since it never changes."""
    im = Image.open(bg_path).convert("RGB")
    d = ImageDraw.Draw(im)
    f = font("Inter.ttf", 24, 500)
    d.text((TEXT_X, H - 64), text, font=f, fill=mix(INK, GROUND, 0.35))
    im.save(bg_path)


# ── time ───────────────────────────────────────────────────────────────────────

AN_FPS, AN_W, AN_H = 10, 144, 312   # the analysis copy of the recording: 10 fps, small, grayscale
PIX_DIFF = 14                        # a pixel "changed" if it moved more than this (0-255)
STATIC_FRAC = 0.002                  # a frame is "static" if less than this share of pixels changed
                                     # (a blinking cursor or a "34 sec ago" label stays under it; a typed word doesn't)
TRIM_KEEP = 0.25                     # what's left of a trimmed static stretch, in seconds
TYPE_KEEP = 0.12                     # ... between keystrokes
TYPE_RATE = 11.0                     # characters a second: typing is re-timed to this pace


def load_frames(recording, s0, length):
    """The recording from s0 for `length` seconds as a (frames, H, W) uint8 array at AN_FPS. Seeking on the input
    keeps simctl's messy timestamps out of the fps filter (see build_screen)."""
    import numpy as np
    raw = subprocess.run([FFMPEG, "-v", "error", "-ss", f"{s0:.3f}", "-t", f"{length:.3f}", "-i", recording,
                          "-vf", f"fps={AN_FPS},scale={AN_W}:{AN_H}:flags=area,format=gray", "-f", "rawvideo", "-"],
                         check=True, capture_output=True).stdout
    n = len(raw) // (AN_W * AN_H)
    return np.frombuffer(raw[: n * AN_W * AN_H], dtype=np.uint8).reshape(n, AN_H, AN_W)


def change_maps(frames):
    """changed[k] = which pixels differ between frame k-1 and k (changed[0] is all False)."""
    import numpy as np
    d = np.zeros(frames.shape, dtype=bool)
    d[1:] = np.abs(frames[1:].astype(np.int16) - frames[:-1].astype(np.int16)) > PIX_DIFF
    return d


def region_series(changed, ev, grow=0.06):
    """Share of changed pixels per frame inside the event's element (normalized box), grown a little."""
    import numpy as np
    w, h = ev.get("w", 0.2), ev.get("h", 0.06)
    x0 = max(0.0, ev["x"] - w / 2 - grow); x1 = min(1.0, ev["x"] + w / 2 + grow)
    y0 = max(0.0, ev["y"] - h / 2 - grow / 2); y1 = min(1.0, ev["y"] + h / 2 + grow / 2)
    sub = changed[:, int(y0 * AN_H): max(int(y0 * AN_H) + 1, int(y1 * AN_H)), int(x0 * AN_W): max(int(x0 * AN_W) + 1, int(x1 * AN_W))]
    return sub.reshape(len(changed), -1).mean(axis=1) if sub.size else np.zeros(len(changed))


def find_offset(changed, actions, s0, lo=-90.0, hi=40.0):
    """How far the recording's clock is from the markers' clock. Each action (a tap or a typing call) must change
    the screen on its element while it runs, and the screen must be still just before it; slide the actions along
    the recording and keep the offset where they fit best. Returns (offset, confidence)."""
    import numpy as np
    if len(actions) < 3:
        return 0.0, 0.0
    n = len(changed)
    whole = changed.reshape(n, -1).mean(axis=1)
    # A hit is a change concentrated on the element: an app launch or a sheet changes the whole screen at once and
    # would otherwise "match" every action.
    series = [(np.clip(region_series(changed, a) - 1.5 * whole, 0, None), a["_a"], a["_b"]) for a in actions]
    offs = np.arange(lo, hi + 1e-9, 0.1)
    score = np.zeros(len(offs))
    for j, d in enumerate(offs):
        tot = 0.0
        for ser, a, b in series:
            k0, k1 = int(math.floor((a + d - s0) * AN_FPS)), int(math.ceil((b + d - s0) * AN_FPS)) + 1
            k0, k1 = max(0, k0), min(n, k1)
            if k1 > k0:
                tot += min(1.0, float(ser[k0:k1].max()) * 20)
            # XCUITest waits for the app to go quiet before it acts, so the screen is still just before each
            # action. A home screen with live widgets or an app launching is not: that's a wrong offset.
            q0, q1 = max(0, k0 - int(1.2 * AN_FPS)), min(n, max(0, k0 - 1))
            if q1 > q0:
                tot -= min(1.0, float(whole[q0:q1].mean()) / 0.01)
        score[j] = tot
    top = [j for j in range(len(offs)) if score[j] >= score.max() - 1e-6]
    best = top[len(top) // 2]  # the middle of the best plateau
    far = [score[j] for j in range(len(offs)) if abs(offs[j] - offs[best]) > 1.5]
    runner = max(far) if far else 0.0
    return float(offs[best]), float((score[best] - runner) / max(score[best], 1e-6))


def subtract(iv, cuts):
    """Interval iv minus a list of intervals."""
    out = [iv]
    for c0, c1 in cuts:
        nxt = []
        for a, b in out:
            if c1 <= a or c0 >= b:
                nxt.append((a, b))
            else:
                if c0 > a:
                    nxt.append((a, c0))
                if c1 < b:
                    nxt.append((c1, b))
        out = nxt
    return out


def build_segments(start, end, pieces):
    """pieces: non-overlapping (a, b, factor, dip) in recording time; factor 0 drops the stretch. Fills the gaps at
    1x and returns sorted (a, b, factor, dip) covering [start, end]."""
    segs, cur = [], start
    for a, b, f, dip in sorted(pieces):
        a, b = max(a, start, cur), min(b, end)
        if b <= a:
            continue
        if a > cur:
            segs.append((cur, a, 1.0, False))
        segs.append((a, b, float(f), dip))
        cur = b
    if cur < end:
        segs.append((cur, end, 1.0, False))
    return segs


def warp(segs, r):
    """Recording time -> output time."""
    out = 0.0
    for a, b, f, _ in segs:
        if r <= a:
            return out
        if r < b:
            return out + ((r - a) / f if f else 0.0)
        out += (b - a) / f if f else 0.0
    return out


def reading_time(ch):
    """Seconds a caption needs on screen: a beat to notice it, then about 25 characters a second."""
    chars = len(ch.get("title", "")) + len(ch.get("sub", "")) + len(ch.get("chip", ""))
    return 1.0 + chars / 25.0


# ── main ───────────────────────────────────────────────────────────────────────

def run(cmd, label=""):
    import time
    t = time.time()
    subprocess.run(cmd, check=True)
    print(f"  {label or ' '.join(cmd[:4])}: {time.time() - t:.1f}s", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recording", required=True)
    ap.add_argument("--markers", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--footer", default="")
    ap.add_argument("--quality", choices=["high", "draft"], default="high")
    ap.add_argument("--keep", help="keep intermediate files in this folder")
    ap.add_argument("--save-source", help="also write the synced, trimmed-to-length screen recording (source.mp4) and its "
                                          "markers.json to this folder, to iterate on the board in Linux later")
    ap.add_argument("--no-trim", action="store_true", help="don't trim dead air")
    args = ap.parse_args()

    M = json.load(open(args.markers))
    t0 = float(M["recordingStart"])
    evs = sorted(M["events"], key=lambda e: e["t"])
    chapters = [e for e in evs if e["kind"] == "chapter"]
    if not chapters:
        sys.exit("markers.json has no chapters")
    ends = [e for e in evs if e["kind"] == "end"]
    nominal_start = max(0.0, chapters[0]["t"] - t0 - 0.2)
    nominal_end = (ends[-1]["t"] if ends else evs[-1]["t"] + 3) - t0

    # 1. Look at the recording: what changes when.
    s0 = max(0.0, nominal_start - 90)  # the offset search covers -90..+40 s
    frames = load_frames(args.recording, s0, nominal_end - s0 + 20)
    changed = change_maps(frames)
    import numpy as np
    moving = changed.reshape(len(changed), -1).mean(axis=1)

    # 2. Sync: recording time = marker time - t0 + offset.
    actions = []
    for e in evs:
        if e["kind"] == "tap" and "x" in e:
            actions.append(dict(e, _a=e.get("pre", e["t"] - 2.5) - t0, _b=e["t"] + 0.15 - t0))
        elif e["kind"] == "type" and "x" in e:
            actions.append(dict(e, _a=e["t"] - t0, _b=e["until"] + 0.15 - t0))
    if M.get("synced"):
        offset, conf, how = 0.0, 1.0, "markers already synced"
    else:
        offset, conf = find_offset(changed, actions, s0)
        how = f"{len(actions)} taps and typing"
    if conf < 0.08 and not M.get("synced"):
        print(f"sync: no clear match by {how} (best {offset:+.1f}s, confidence {conf:.2f}); using recordingStart as is")
        offset = 0.0
    else:
        print(f"sync: the recording runs {offset:+.1f}s from recordingStart, by {how} (confidence {conf:.2f})")
    R = lambda t: t - t0 + offset            # marker epoch -> recording time
    K = lambda r: int(round((r - s0) * AN_FPS))  # recording time -> analysis frame
    start, end = nominal_start + offset, nominal_end + offset
    start = max(0.0, start)

    # 3. Time: explicit fast-forwards and cuts, then trim the dead air everywhere else.
    explicit = []
    for e in evs:
        if e["kind"] == "speed":
            explicit.append((R(e["t"]), R(e["until"]), e.get("factor", 4), False))
        elif e["kind"] == "cut":
            explicit.append((R(e["t"]), R(e["until"]), 0, True))
    # Typing: XCUITest types in uneven bursts with stalls (worse on a busy Simulator). Find the frames where the
    # text visibly changes and re-time them so keystrokes land evenly at TYPE_RATE, like a person typing.
    for e in evs:
        if e["kind"] != "type" or "x" not in e or not e.get("chars"):
            continue
        a, b = R(e["t"]), R(e["until"]) + 0.15
        ser = region_series(changed, e, grow=0.02)
        keys = [k for k in range(max(0, K(a)), min(len(ser), K(b) + 1)) if ser[k] > 0.004]
        if len(keys) < 2:
            continue
        rs = [s0 + k / AN_FPS for k in keys]
        step = (e["chars"] / TYPE_RATE) / (len(rs) - 1)
        for r0, r1 in zip(rs, rs[1:]):
            explicit.append((r0, r1, max(0.12, min(8.0, (r1 - r0) / step)), False))  # XCUITest can type 30+ a second
    explicit.sort()
    clean = []
    for a, b, f, dip in explicit:  # no overlaps
        if clean and a < clean[-1][1]:
            a = clean[-1][1]
        if b > a:
            clean.append((a, b, f, dip))
    explicit = clean
    holds = [(R(e["t"]), R(e["until"])) for e in evs if e["kind"] == "hold"]
    typing = [(R(e["t"]), R(e["until"]), e) for e in evs if e["kind"] == "type"]
    protected = holds + [(a, b) for a, b, _, _ in explicit]

    trims = []
    if not args.no_trim:
        k, n = K(start), min(len(moving), K(end))
        while k < n:
            if moving[k] < STATIC_FRAC:
                j = k
                while j < n and moving[j] < STATIC_FRAC:
                    j += 1
                a, b = s0 + k / AN_FPS, s0 + j / AN_FPS
                for p0, p1 in subtract((a, b), sorted(protected)):
                    # Between keystrokes keep less, so typing flows at a person's pace instead of stalling.
                    keep = TYPE_KEEP if any(ta <= (p0 + p1) / 2 <= tb for ta, tb, _ in typing) else TRIM_KEEP
                    if p1 - p0 > keep + 0.15:
                        trims.append([p0 + keep / 2, p1 - keep / 2])
                k = j
            else:
                k += 1

    def segments():
        return build_segments(start, end, explicit + [(a, b, 0, False) for a, b in trims if b > a])

    # Every chapter keeps time to read its caption: give back trimmed time (latest first) where it's short.
    ch_r = [R(c["t"]) for c in chapters] + [end]
    given = []  # still time kept back so a caption can be read: as deliberate as a pause
    for i, ch in enumerate(chapters):
        segs = segments()
        short = reading_time(ch) - (warp(segs, ch_r[i + 1]) - warp(segs, ch_r[i]))
        for tr in sorted([t for t in trims if ch_r[i] <= t[0] < ch_r[i + 1]], key=lambda t: -t[0]):
            if short <= 0:
                break
            give = min(short, tr[1] - tr[0])
            given.append((tr[1] - give, tr[1]))
            tr[1] -= give
            short -= give
        if short > 0.05:
            print(f"  note: chapter '{ch['title']}' is {short:.1f}s short of its reading time (lengthen its pause)")
    segs = segments()
    dur = warp(segs, end)
    trimmed = sum(b - a for a, b in trims if b > a)
    print(f"recording {start:.2f}-{end:.2f}s -> {dur:.2f}s of video: {len(chapters)} chapters, "
          f"{sum(1 for e in evs if e['kind'] == 'tap')} taps, {sum(1 for e in evs if e['kind'] == 'speed')} fast-forwards, "
          f"{sum(1 for x in explicit if not x[2])} cuts, {trimmed:.1f}s of dead air trimmed")

    # Tap ripples land on the first change near the element while the tap ran (XCUITest's own timing is loose).
    taps = []
    for e in evs:
        if e["kind"] != "tap":
            continue
        r = R(e["t"])
        if "x" in e and "pre" in e:
            ser = region_series(changed, e, grow=0.02) - 1.5 * moving  # a change on the element, not the whole screen
            k0, k1 = max(0, K(R(e["pre"]))), min(len(ser), K(R(e["t"] + 0.15)) + 1)
            hit = [k for k in range(k0, k1) if ser[k] > 0.01]
            if hit:
                r = s0 + hit[0] / AN_FPS - 0.08
        taps.append((r, e))

    work = args.keep or tempfile.mkdtemp(prefix="demo-")
    os.makedirs(work, exist_ok=True)
    bg, mask, ripple = (os.path.join(work, n) for n in ("bg.png", "mask.png", "ripple.png"))
    draw_background(bg)
    draw_screen_mask(mask)
    draw_ripple(ripple)
    caps = []
    for i, ch in enumerate(chapters):
        p = os.path.join(work, f"cap-{i:02d}.png")
        ox, oy = draw_caption(p, ch)
        a = warp(segs, ch_r[i])
        b = warp(segs, ch_r[i + 1]) if i + 1 < len(chapters) else dur
        caps.append((p, a, b, ox, oy))
    if args.footer:
        draw_footer(bg, args.footer)

    # x264 "veryfast" at CRF 16 is visually identical to "slow" on this content (SSIM 0.998) at a fraction of the time.
    enc = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high", "-movflags", "+faststart"]
    preset, crf = os.environ.get("X264_PRESET"), os.environ.get("X264_CRF")
    enc += ["-preset", preset or ("veryfast" if args.quality == "high" else "ultrafast"), "-crf", crf or ("16" if args.quality == "high" else "23")]

    # 4. The screen. simctl records a variable frame rate with messy decode timestamps, so filters that read the
    #    raw timestamps (trim, select) see the wrong frames. Seeking on the input is reliable, and after fps= the
    #    timestamps are clean: so one pass seeks to `start`, fixes the rate, scales to the phone's screen, then cuts
    #    and fast-forwards. A cut dips the screen to black for a moment on each side, like an app switch.
    keep = [s for s in segs if s[2]]
    screen = os.path.join(work, "screen.mp4")
    parts = [f"[0:v]fps={FPS},scale={SCREEN_W}:{SCREEN_H}:flags=lanczos,setsar=1,split={len(keep)}" + "".join(f"[p{i}]" for i in range(len(keep)))]
    for i, (a, b, f, _) in enumerate(keep):
        fx = ""
        pos = segs.index(keep[i])
        out_len = (b - a) / f
        if pos + 1 < len(segs) and segs[pos + 1][3] and out_len > 0.4:
            fx += f",fade=t=out:st={out_len - 0.18:.3f}:d=0.18"
        if pos > 0 and segs[pos - 1][3] and out_len > 0.4:
            fx += ",fade=t=in:st=0:d=0.18"
        parts.append(f"[p{i}]trim=start={a - start:.3f}:end={b - start:.3f},setpts=(PTS-STARTPTS)/{f}{fx}[s{i}]")
    graph = ";".join(parts) + ";" + "".join(f"[s{i}]" for i in range(len(keep))) + f"concat=n={len(keep)}:v=1:a=0,fps={FPS}[v]"
    run([FFMPEG, "-v", "error", "-y", "-ss", f"{start:.3f}", "-t", f"{end - start + 0.5:.3f}", "-i", args.recording,
         "-filter_complex", graph, "-map", "[v]", "-t", f"{dur:.3f}", "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", screen], "screen")

    # 5. The board: background, masked screen, captions (fade + drift in), tap ripples.
    #    Every still is decoded once and repeated with the loop filter: "-loop 1" would decode the PNG again for
    #    every frame. Captions and ripples exist only for their own window (setpts shifts them into place).
    def still(idx, length, offset=0.0):
        return f"[{idx}:v]format=rgba,loop=-1:1:0,fps={FPS},trim=duration={length:.3f},setpts=PTS-STARTPTS+{offset:.3f}/TB"

    inputs = ["-i", bg, "-i", screen, "-i", mask]
    n = 3
    g = [f"[0:v]loop=-1:1:0,fps={FPS},trim=duration={dur:.3f}[bgv]",
         f"[2:v]format=gray,loop=-1:1:0,fps={FPS},trim=duration={dur:.3f}[msk]",
         f"[1:v]format=rgba[scr];[scr][msk]alphamerge[scrm]",
         f"[bgv][scrm]overlay={SCREEN_X}:{SCREEN_Y}:format=auto[b0]"]
    last = "b0"
    for i, (p, a, b, ox, oy) in enumerate(caps):
        fin = max(0.0, a - 0.05)
        last_cap = i == len(caps) - 1
        span = (dur - fin) if last_cap else (b - fin)
        inputs += ["-i", p]
        fout = fin + max(0.5, span - 0.35)
        out_fade = "" if last_cap else f",fade=t=out:st={fout:.3f}:d=0.35:alpha=1"
        g.append(still(n, span, fin) + f",fade=t=in:st={fin:.3f}:d=0.5:alpha=1{out_fade}[c{i}]")
        drift = f"{ox}+40*max(0\\,1-(t-{fin:.3f})/0.6)"
        g.append(f"[{last}][c{i}]overlay=x='{drift}':y={oy}:eof_action=pass:repeatlast=0[b{i + 1}]")
        last = f"b{i + 1}"
        n += 1
    for j, (r, tp) in enumerate(taps):
        tt = warp(segs, r)
        if tt <= 0.1 or tt >= dur - 0.7:
            continue
        cx, cy = SCREEN_X + tp["x"] * SCREEN_W, SCREEN_Y + tp["y"] * SCREEN_H
        st = tt - 0.06
        inputs += ["-i", ripple]
        sz = f"(60+90*min(1\\,max(0\\,(t-{tt:.3f})/0.55)))"
        g.append(still(n, 0.7, st) + f",scale=w='{sz}':h='{sz}':eval=frame,fade=t=in:st={st:.3f}:d=0.06:alpha=1,fade=t=out:st={tt + 0.2:.3f}:d=0.4:alpha=1[r{j}]")
        g.append(f"[{last}][r{j}]overlay=x='{cx:.1f}-overlay_w/2':y='{cy:.1f}-overlay_h/2':eof_action=pass:repeatlast=0[t{j}]")
        last = f"t{j}"
        n += 1
    g.append(f"[{last}]fade=t=in:st=0:d=0.4,fade=t=out:st={max(0, dur - 0.6):.3f}:d=0.6,format=yuv420p[out]")
    tmp = args.out + ".part.mp4"
    run([FFMPEG, "-v", "error", "-y", *inputs, "-filter_complex", ";".join(g), "-map", "[out]", "-r", str(FPS), "-t", f"{dur:.3f}", *enc, tmp], "board + encode")
    os.replace(tmp, args.out)

    # 6. Optionally keep the synced source for iterating on the board later without a Mac.
    if args.save_source:
        os.makedirs(args.save_source, exist_ok=True)
        lead = min(start, 1.0)
        run([FFMPEG, "-v", "error", "-y", "-ss", f"{start - lead:.3f}", "-t", f"{end - start + lead + 0.5:.3f}", "-i", args.recording,
             "-vf", f"fps={FPS},scale={SCREEN_W * 2}:{SCREEN_H * 2}:flags=lanczos,setsar=1",
             "-c:v", "libx264", "-preset", "ultrafast", "-crf", "22", "-pix_fmt", "yuv420p", os.path.join(args.save_source, "source.mp4")], "source")
        m2 = dict(M, recordingStart=t0 - offset + (start - lead), synced=True)
        json.dump(m2, open(os.path.join(args.save_source, "markers.json"), "w"), indent=1)

    # 7. What the video contains, in output time, for demo/review.py to check against the pixels.
    report = {
        "duration": dur, "offset": offset, "syncConfidence": conf, "trimmed": trimmed,
        "screen": [SCREEN_X, SCREEN_Y, SCREEN_W, SCREEN_H],
        "chapters": [{"title": ch["title"], "style": ch.get("style", "step"), "start": caps[i][1], "end": caps[i][2], "reading": reading_time(ch)} for i, ch in enumerate(chapters)],
        "ripples": [{"t": warp(segs, r), "x": e["x"], "y": e["y"], "w": e.get("w", 0.2), "h": e.get("h", 0.06)} for r, e in taps],
        "typing": [{"start": warp(segs, a), "end": warp(segs, b), "chars": e.get("chars", 0), "x": e.get("x", 0.5), "y": e.get("y", 0.2),
                    "w": e.get("w", 0.9), "h": e.get("h", 0.06)} for a, b, e in typing],
        "holds": [[warp(segs, a), warp(segs, b)] for a, b in holds + given],
        "cuts": [warp(segs, a) for a, b, f, dip in explicit if not f],
        "fastForwards": [[warp(segs, a), warp(segs, b), f] for a, b, f, dip in explicit if f],
    }
    json.dump(report, open(os.path.splitext(args.out)[0] + ".report.json", "w"), indent=1)

    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1e6:.1f} MB, {dur:.1f}s)")


if __name__ == "__main__":
    main()
