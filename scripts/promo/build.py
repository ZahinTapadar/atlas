#!/usr/bin/env python3
"""Render the ATLAS promo video (1920x1080, 30 fps, H.264, silent).

Plates and captions are HTML rendered to PNG with headless Chrome; ffmpeg animates
them (slow push-ins, caption fades) and joins the scenes with cross-fades.
Screens come from docs/assets/screens (the app's --demo mode: synthetic data).

    python3 scripts/promo/build.py            # -> docs/assets/atlas-promo.mp4 + poster
"""
import os, subprocess, shutil, tempfile, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCREENS = ROOT / "docs/assets/screens"
ICON = ROOT / "Resources/Icon/source.png"
OUT = ROOT / "docs/assets/atlas-promo.mp4"
POSTER = ROOT / "docs/assets/atlas-promo-poster.jpg"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FPS = 30
W, H = 1920, 1080

work = pathlib.Path(tempfile.mkdtemp(prefix="atlas-promo-"))

BASE_CSS = """
*{box-sizing:border-box;margin:0}
html,body{width:%dpx;height:%dpx;overflow:hidden}
body{font-family:-apple-system,"SF Pro Display",BlinkMacSystemFont,sans-serif;-webkit-font-smoothing:antialiased}
"""


def shot(name, html, w=W, h=H, transparent=False):
    page = work / f"{name}.html"
    page.write_text(f"<!doctype html><html><head><meta charset='utf-8'><style>{BASE_CSS % (w, h)}</style></head><body>{html}</body></html>")
    out = work / f"{name}.png"
    args = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
            f"--window-size={w},{h}", f"--user-data-dir={work / 'chrome'}", "--allow-file-access-from-files",
            "--virtual-time-budget=3000", f"--screenshot={out}", f"file://{page}"]
    if transparent:
        args.insert(1, "--default-background-color=00000000")
    subprocess.run(args, check=True, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    return out


GROUND = "background:radial-gradient(120% 90% at 70% 10%,#2a2a30 0%,#121215 55%,#0b0b0d 100%)"


def plate(name, screen):
    """A 4K plate: the app window floating on the graphite ground (zoomed later)."""
    return shot(name, f"""
      <div style="width:100%;height:100%;{GROUND};display:flex;align-items:center;justify-content:center">
        <img src="file://{SCREENS / screen}" style="width:3240px;border-radius:44px;
             box-shadow:0 60px 160px -30px rgba(0,0,0,.75),0 0 0 2px rgba(255,255,255,.06)">
      </div>""", 3840, 2160)


def caption(name, title, sub=""):
    return shot(name, f"""
      <div style="position:absolute;left:96px;bottom:84px;max-width:1100px;padding:30px 36px 32px;border-radius:28px;
                  background:rgba(14,14,16,.82);backdrop-filter:blur(20px);box-shadow:0 30px 80px -20px rgba(0,0,0,.6);
                  border:1px solid rgba(255,255,255,.08)">
        <div style="color:#f4f4f6;font:700 58px/1.04 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:-.035em">{title}</div>
        {f'<div style="color:#a1a1aa;font:500 26px/1.35 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;margin-top:14px">{sub}</div>' if sub else ''}
      </div>""", transparent=True)


def card(name, inner):
    return shot(name, f"<div style='width:100%;height:100%;{GROUND};display:flex;align-items:center;justify-content:center;flex-direction:column;color:#f4f4f6;text-align:center'>{inner}</div>")


def loop_plate():
    """Illustrated scene (synthetic content): email, calendar and Things updated by a check-in."""
    ev = lambda t, top, h, bg, fg, sub="": f"""<div style="position:absolute;left:150px;right:30px;top:{top}px;height:{h}px;border-radius:18px;
            background:{bg};color:{fg};padding:18px 22px;font:600 28px/1.2 system-ui,-apple-system,BlinkMacSystemFont,sans-serif">{t}
            {f'<div style="font:500 22px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;opacity:.75;margin-top:6px">{sub}</div>' if sub else ''}</div>"""
    hours = "".join(f"<div style='position:absolute;left:30px;top:{40 + i * 210}px;color:#8f8f99;font:500 24px -apple-system'>{h}</div>"
                    f"<div style='position:absolute;left:130px;right:0;top:{56 + i * 210}px;height:1px;background:rgba(255,255,255,.07)'></div>"
                    for i, h in enumerate(["12 PM", "1 PM", "2 PM", "3 PM", "4 PM", "5 PM", "6 PM"]))
    todo = lambda t, done, m="": f"""<div style="display:flex;align-items:center;gap:20px;padding:20px 0;border-top:1px solid rgba(255,255,255,.08);
            font:500 30px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;color:{'#8f8f99' if done else '#f4f4f6'}">
            <span style="width:34px;height:34px;border-radius:50%;flex:none;{'background:#3dd68c' if done else 'border:3px solid #6e6e78'};
                  display:flex;align-items:center;justify-content:center;color:#0b0b0d;font:800 22px system-ui,-apple-system,BlinkMacSystemFont,sans-serif">{'✓' if done else ''}</span>
            <span style="flex:1;{'text-decoration:line-through' if done else ''}">{t}</span><span style="color:#8f8f99;font-size:26px">{m}</span></div>"""
    return shot("plate-loop", f"""
      <div style="width:100%;height:100%;{GROUND};position:relative;color:#f4f4f6">
        <div style="position:absolute;left:220px;top:300px;width:1180px;height:1560px;border-radius:44px;background:#1a1a1e;
                    box-shadow:0 60px 160px -30px rgba(0,0,0,.75);overflow:hidden;border:2px solid rgba(255,255,255,.06)">
          <div style="padding:44px 50px 20px;font:700 44px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:-.02em">Calendar · Today</div>
          <div style="position:relative;height:1480px">{hours}
            {ev("Did · Coding: Xcode (62m)", 120, 200, "rgba(161,161,170,.18)", "#d4d4d8", "Logged by ATLAS")}
            {ev("Physics tutorial", 560, 150, "#2f6bff", "#fff", "4:30 – 5:15 PM")}
            {ev("Did · Reading: Chapter 7 (48m)", 760, 160, "rgba(161,161,170,.18)", "#d4d4d8")}
            {ev("Next · Physics lab analysis", 1090, 250, "#3dd68c", "#0b2a19", "6:15 – 7:15 PM · reminder at start")}
          </div>
        </div>
        <div style="position:absolute;left:1500px;top:300px;width:2120px;height:700px;border-radius:44px;background:#1a1a1e;
                    box-shadow:0 60px 160px -30px rgba(0,0,0,.75);padding:52px 60px;border:2px solid rgba(255,255,255,.06)">
          <div style="display:flex;justify-content:space-between;color:#8f8f99;font:500 28px system-ui,-apple-system,BlinkMacSystemFont,sans-serif">
            <span>From ATLAS · to you</span><span>3:00 PM</span></div>
          <div style="font:700 56px/1.1 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;margin-top:26px;letter-spacing:-.03em">ATLAS · <span style="color:#3dd68c">On track</span> · 15:00</div>
          <div style="font:500 36px/1.45 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;color:#d4d4d8;margin-top:28px">1h 39m of focused coding on the Habit app, gaming held to 16m.</div>
          <div style="font:600 34px/1.4 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;margin-top:26px">→ Finish the physics lab analysis before the 4:30 tutorial.</div>
        </div>
        <div style="position:absolute;left:1500px;top:1080px;width:2120px;height:780px;border-radius:44px;background:#1a1a1e;
                    box-shadow:0 60px 160px -30px rgba(0,0,0,.75);padding:52px 60px;border:2px solid rgba(255,255,255,.06)">
          <div style="font:700 44px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;margin-bottom:18px;letter-spacing:-.02em">Things · Today</div>
          {todo("Organic Chemistry: read Chapter 7", True, "48m")}
          {todo("Habit app: streak logic", True, "1h 39m")}
          {todo("Physics lab 4: analysis", False, "41m")}
          {todo("Problem set 3 (chemistry)", False)}
        </div>
      </div>""", 3840, 2160)


# ---- assets ---------------------------------------------------------------
intro = card("intro", f"""<img src="file://{ICON}" style="width:300px;height:300px;filter:drop-shadow(0 40px 60px rgba(0,0,0,.6))">
             <div style="font:700 64px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:.18em;margin-top:56px">ATLAS</div>""")
title = card("title", """<div style="font:700 128px/1.0 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:-.05em;max-width:1500px">Know where your time actually goes.</div>
             <div style="font:500 36px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;color:#a1a1aa;margin-top:44px">A quiet activity tracker for macOS, with a coach every three hours.</div>""")
outro = card("outro", f"""<img src="file://{ICON}" style="width:180px;height:180px;filter:drop-shadow(0 30px 50px rgba(0,0,0,.6))">
             <div style="font:700 96px/1.05 system-ui,-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:-.045em;margin-top:52px">Track honestly. Act on it.</div>
             <div style="font:500 34px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;color:#a1a1aa;margin-top:30px">Free and open source for macOS · local-first · works with Claude</div>
             <div style="font:600 34px system-ui,-apple-system,BlinkMacSystemFont,sans-serif;margin-top:46px;padding:18px 34px;border-radius:999px;background:#f4f4f6;color:#0b0b0d">zahintapadar.github.io/atlas</div>""")
p_today = plate("plate-today", "today-light.webp")
p_check = plate("plate-checkins", "checkins-dark.webp")
p_time = plate("plate-timeline", "timeline-light.webp")
p_rep = plate("plate-reports", "reports-dark.webp")
p_loop = loop_plate()
c = {
    "verdict": caption("cap-verdict", "One verdict leads.", "Every three hours, Claude reads your day and says plainly whether you're on track."),
    "todos": caption("cap-todos", "Your plan, kept honest.", "Today's to-dos sync with Things: done, in progress, not started."),
    "checkins": caption("cap-checkins", "A coach, not a scold.", "Minutes as evidence, and a concrete next step timed to your calendar."),
    "loop": caption("cap-loop", "It closes the loop.", "Email, calendar blocks for what you did and what's next, and Things updates."),
    "timeline": caption("cap-timeline", "Every minute, honestly labeled.", "Uncertain time stays uncertain. Correct anything, and ATLAS learns."),
    "reports": caption("cap-reports", "Patterns over the week.", "Local-first: your day never leaves your Mac except as a short summary."),
}

# ---- scenes ---------------------------------------------------------------
# (image, caption, seconds, zoom_from, zoom_to, focus_x, focus_y) — focus is the fraction of the plate to push toward.
scenes = [
    (intro, None, 3.0, 1.0, 1.04, .5, .5),
    (title, None, 3.6, 1.0, 1.03, .5, .5),
    (p_today, c["verdict"], 5.0, 1.0, 1.45, .48, .30),
    (p_today, c["todos"], 4.6, 1.45, 1.55, .52, .52),
    (p_check, c["checkins"], 4.6, 1.05, 1.35, .45, .32),
    (p_loop, c["loop"], 5.2, 1.0, 1.12, .55, .45),
    (p_time, c["timeline"], 4.4, 1.05, 1.3, .55, .35),
    (p_rep, c["reports"], 4.4, 1.05, 1.28, .5, .3),
    (outro, None, 4.4, 1.0, 1.03, .5, .5),
]
XF = 0.6  # cross-fade seconds

clips = []
for i, (img, cap, dur, z0, z1, fx, fy) in enumerate(scenes):
    n = int(round(dur * FPS))
    out = work / f"clip{i}.mp4"
    # Ease-out push-in; x/y keep the focus point fixed while zooming.
    zexpr = f"{z0}+({z1}-{z0})*(1-pow(1-on/{n},3))"
    xexpr = f"(iw-iw/zoom)*{fx}"
    yexpr = f"(ih-ih/zoom)*{fy}"
    inputs = ["-loop", "1", "-i", str(img)]
    fc = (f"[0:v]scale=3840:2160,zoompan=z='{zexpr}':x='{xexpr}':y='{yexpr}':d={n}:s={W}x{H}:fps={FPS},"
          f"format=yuv420p[bg]")
    if cap:
        inputs += ["-loop", "1", "-i", str(cap)]
        fc += (f";[1:v]format=rgba,fade=in:st=0.45:d=0.55:alpha=1,fade=out:st={dur - 0.7}:d=0.5:alpha=1[cap];"
               f"[bg][cap]overlay=0:0:shortest=1,format=yuv420p[v]")
    else:
        fc += ";[bg]null[v]"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", fc, "-map", "[v]",
                    "-t", f"{dur}", "-r", str(FPS), "-c:v", "libx264", "-preset", "medium", "-crf", "18", str(out)], check=True)
    clips.append((out, dur))

# Join with cross-fades.
inputs, fc, prev, offset = [], "", "[0:v]", 0.0
for i, (p, d) in enumerate(clips):
    inputs += ["-i", str(p)]
for i in range(1, len(clips)):
    offset += clips[i - 1][1] - XF
    label = f"[x{i}]"
    fc += f"{prev}[{i}:v]xfade=transition=fade:duration={XF}:offset={offset:.3f}{label};"
    prev = label
fc += f"{prev}fade=in:st=0:d=0.6,format=yuv420p[out]"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", fc, "-map", "[out]",
                "-c:v", "libx264", "-preset", "slow", "-crf", "22", "-movflags", "+faststart", "-pix_fmt", "yuv420p", str(OUT)], check=True)
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "8.5", "-i", str(OUT), "-frames:v", "1", "-q:v", "3", str(POSTER)], check=True)
shutil.rmtree(work, ignore_errors=True)
print(f"wrote {OUT.relative_to(ROOT)} and {POSTER.relative_to(ROOT)}")
