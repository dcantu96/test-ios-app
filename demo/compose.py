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
    {"t": <epoch>, "kind": "tap", "x": 0..1, "y": 0..1},          # position on the screen, normalized
    {"t": <epoch>, "kind": "speed", "until": <epoch>, "factor": 4},  # fast-forward this stretch
    {"t": <epoch>, "kind": "end"}
  ]
}
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
    for _ in range(60):
        rad = (820 + rng.random() * 1500) * S
        a0 = math.pi * (0.12 + rng.random() * 0.8)
        length = 0.04 + rng.random() * 0.09
        width = max(2, int((1.4 + rng.random() * 2.2) * S))
        alpha = int(255 * (0.14 + rng.random() * 0.34))
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
    return lines


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

def build_segments(start, end, speeds):
    """Cut [start, end] of the recording into (a, b, factor) pieces; sped-up stretches play `factor` times faster."""
    segs, cur = [], start
    for a, b, f in sorted(speeds):
        a, b = max(a, start), min(b, end)
        if b <= a:
            continue
        if a > cur:
            segs.append((cur, a, 1.0))
        segs.append((a, b, float(f)))
        cur = b
    if cur < end:
        segs.append((cur, end, 1.0))
    return segs


def warp(segs, r):
    """Recording time -> output time."""
    out = 0.0
    for a, b, f in segs:
        if r <= a:
            return out
        if r < b:
            return out + (r - a) / f
        out += (b - a) / f
    return out


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
    args = ap.parse_args()

    M = json.load(open(args.markers))
    t0 = float(M["recordingStart"])
    evs = sorted(M["events"], key=lambda e: e["t"])
    chapters = [e for e in evs if e["kind"] == "chapter"]
    taps = [e for e in evs if e["kind"] == "tap"]
    speeds = [(e["t"] - t0, e["until"] - t0, e.get("factor", 4)) for e in evs if e["kind"] == "speed"]
    ends = [e for e in evs if e["kind"] == "end"]
    if not chapters:
        sys.exit("markers.json has no chapters")
    start = max(0.0, chapters[0]["t"] - t0 - 0.2)
    end = (ends[-1]["t"] if ends else evs[-1]["t"] + 3) - t0
    segs = build_segments(start, end, speeds)
    dur = warp(segs, end)
    print(f"recording {start:.2f}–{end:.2f}s -> {dur:.2f}s of video, {len(chapters)} chapters, {len(taps)} taps, {len(speeds)} fast-forwards")

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
        a = warp(segs, ch["t"] - t0)
        b = warp(segs, chapters[i + 1]["t"] - t0) if i + 1 < len(chapters) else dur
        caps.append((p, a, b, ox, oy))
    if args.footer:
        draw_footer(bg, args.footer)

    # x264 "veryfast" at CRF 16 is visually identical to "slow" on this content (SSIM 0.998) at a fraction of the time.
    enc = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high", "-movflags", "+faststart"]
    preset, crf = os.environ.get("X264_PRESET"), os.environ.get("X264_CRF")
    enc += ["-preset", preset or ("veryfast" if args.quality == "high" else "ultrafast"), "-crf", crf or ("16" if args.quality == "high" else "23")]

    # 1. The screen. simctl records a variable frame rate with messy decode timestamps, so filters that read the
    #    raw timestamps (trim, select) see the wrong frames. Seeking on the input is reliable, and after fps= the
    #    timestamps are clean: so one pass seeks to `start`, fixes the rate, scales to the phone's screen, then cuts
    #    and fast-forwards.
    screen = os.path.join(work, "screen.mp4")
    parts = [f"[0:v]fps={FPS},scale={SCREEN_W}:{SCREEN_H}:flags=lanczos,setsar=1,split={len(segs)}" + "".join(f"[p{i}]" for i in range(len(segs)))]
    for i, (a, b, f) in enumerate(segs):
        parts.append(f"[p{i}]trim=start={a - start:.3f}:end={b - start:.3f},setpts=(PTS-STARTPTS)/{f}[s{i}]")
    graph = ";".join(parts) + ";" + "".join(f"[s{i}]" for i in range(len(segs))) + f"concat=n={len(segs)}:v=1:a=0,fps={FPS}[v]"
    run([FFMPEG, "-v", "error", "-y", "-ss", f"{start:.3f}", "-t", f"{end - start + 0.5:.3f}", "-i", args.recording,
         "-filter_complex", graph, "-map", "[v]", "-t", f"{dur:.3f}", "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", screen], "screen")

    # 2. The board: background, masked screen, captions (fade + drift in), tap ripples.
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
    for j, tp in enumerate(taps):
        tt = warp(segs, tp["t"] - t0)
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
    if not args.keep:
        shutil.rmtree(work, ignore_errors=True)
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1e6:.1f} MB, {dur:.1f}s)")


if __name__ == "__main__":
    main()
