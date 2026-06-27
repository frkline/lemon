#!/usr/bin/env python3
"""On-brand README mocks rendered from the Lemon design tokens — replacing
the old pre-glass screenshots. Same warm-dark glass language as the hero.
Cards are fairly opaque (glass suggested by hairlines + inner highlights),
so they read on both GitHub light and dark, framed transparently."""
import pathlib
OUT = pathlib.Path("/Users/frank/Projects/lemon/design/landing/readme-hero")
IMG = pathlib.Path("/Users/frank/Projects/lemon/docs/img")

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
.mono{font-family:"SF Mono",ui-monospace,Menlo,monospace;font-feature-settings:"ss01"}
html,body{margin:0;height:100%;background:transparent}
body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;display:grid;place-items:center}
.frame{display:grid;place-items:center}
/* warm-dark glass card */
.card{background:rgba(24,18,11,.95);border-radius:16px;color:#ECE6D8;
  box-shadow:inset 0 0 0 .5px rgba(255,255,255,.10),
             inset 0 1px 0 rgba(255,255,255,.05),
             0 30px 70px rgba(8,5,2,.5)}
.dot{width:6px;height:6px;border-radius:50%;flex:none}
.src{display:inline-flex;align-items:center;justify-content:center;min-width:19px;height:19px;
  padding:0 5px;border-radius:6px;font-size:10px;font-weight:700;
  font-family:"SF Mono",ui-monospace,Menlo,monospace;color:#EAAE3A;
  background:rgba(234,174,58,.13);box-shadow:inset 0 0 0 .5px rgba(234,174,58,.30)}
.src.gh{color:#6BD180;background:rgba(107,209,128,.12);box-shadow:inset 0 0 0 .5px rgba(107,209,128,.30)}
.chip{display:inline-flex;align-items:center;gap:6px;font-size:11px;font-weight:600;
  color:#C9C2B2;background:rgba(255,255,255,.05);padding:4px 9px;border-radius:999px;
  box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08)}
"""

def write(name, w, h, inner, png):
    # Frame fills the viewport and centers; the window (>=520px wide to clear
    # Chrome's headless min-width clamp) defines the PNG size. Transparent
    # margins around the card are fine on GitHub.
    (OUT/name).write_text(
      f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}
.frame{{width:100vw;min-height:100vh}}</style></head><body>
<div class="frame">{inner}</div></body></html>""")
    return (name, w, h, png)

JOBS = []

# ---- 1. live-list → session popover -----------------------------------------
def srow(src, ident, title, label, color, term=None, terminal=False, last=False):
    g = f'<span class="src{" gh" if src=="gh" else ""}">{src}</span>'
    dot = '' if terminal else f'<span class="dot" style="background:{color};box-shadow:0 0 7px {color}"></span>'
    termln = f'<div class="mono" style="margin-top:9px;font-size:11.5px;color:#C9BFA6;background:#17110A;padding:8px 11px;border-radius:9px;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.05);white-space:nowrap">{term}</div>' if term else ''
    sep = '' if last else 'box-shadow:inset 0 -.5px 0 rgba(255,255,255,.07);'
    strip = f'<span style="width:3px;align-self:stretch;border-radius:2px;background:{color};margin:2px 12px 2px 0"></span>'
    return f"""<div style="display:flex;padding:13px 16px;{sep}">{strip}
      <div style="flex:1">
        <div style="display:flex;align-items:center;gap:8px">{g}
          <span class="mono" style="font-size:11px;font-weight:600;color:#A9A293">{ident}</span>
          <span style="margin-left:auto;display:inline-flex;align-items:center;gap:5px;font-size:11px;font-weight:600;color:#C9C2B2">{dot}{label}</span></div>
        <div style="margin-top:7px;font-size:13px;font-weight:500;color:#ECE6D8;letter-spacing:-.1px">{title}</div>
        {termln}</div></div>"""
popover = f"""<div class="card" style="width:404px;overflow:hidden">
  <div style="height:3px;background:linear-gradient(90deg,#F7C842,rgba(247,200,66,0))"></div>
  <div style="display:flex;align-items:center;gap:8px;padding:14px 16px 12px;box-shadow:inset 0 -.5px 0 rgba(255,255,255,.08)">
    <span style="font-size:14px;font-weight:700">🍋 Lemon</span>
    <span class="dot" style="background:#F7C842;box-shadow:0 0 7px #F7C842;margin-left:2px"></span>
    <span class="chip" style="margin-left:auto"><span class="dot" style="background:#45C27A;box-shadow:0 0 7px #45C27A"></span>2 active</span>
  </div>
  {srow("L","LEM-42","Wire up the Liquid Glass token set","Executing","#F7C842",term="› claude --permission-mode auto …")}
  {srow("gh","acme/web#7","Re-trigger fires on shipped revisions","Waiting","#FF6B46")}
  {srow("L","LEM-39","Public-readiness scaffolding + CI","Done","#45C27A",terminal=True,last=True)}
</div>"""
JOBS.append(write("rm-popover.html", 520, 560, popover, "live-list.png"))

# ---- 2. setup-3-localai → Local AI onboarding card --------------------------
def ready(title, sub):
    return f"""<div style="display:flex;align-items:center;gap:11px;padding:12px 14px;border-radius:11px;
      background:rgba(255,255,255,.035);box-shadow:inset 0 0 0 .5px rgba(255,255,255,.07);margin-top:9px">
      <span style="width:22px;height:22px;border-radius:7px;display:flex;align-items:center;justify-content:center;
        background:rgba(69,194,122,.16);color:#45C27A;font-size:12px;flex:none">✓</span>
      <div style="flex:1"><div style="font-size:12.5px;font-weight:600">{title}</div>
        <div class="mono" style="font-size:10.5px;color:#9A9384;margin-top:2px">{sub}</div></div>
      <span style="font-size:10.5px;font-weight:700;color:#45C27A">ready</span></div>"""
localai = f"""<div class="card" style="width:392px;padding:20px">
  <div style="display:flex;align-items:center;gap:8px">
    <span class="mono" style="font-size:9px;font-weight:700;letter-spacing:1.6px;color:#9A9384">LOCAL AI · STEP 3</span>
    <span class="chip" style="margin-left:auto">on device</span></div>
  <div style="margin-top:14px;font-size:19px;font-weight:700;letter-spacing:-.4px">The supervisor runs on your Mac.</div>
  <div style="margin-top:7px;font-size:12.5px;line-height:1.5;color:#B7AF9E">A quantized Gemma reads each diff on the GPU. Nothing leaves the machine.</div>
  {ready("Gemma 4 · E2B","gemma-4-e2b-it-4bit · 4-bit MLX · ~4 GB")}
  {ready("SwiftLM runner","127.0.0.1:8765 · build b648")}
  <div style="margin-top:16px;display:flex;align-items:center;gap:10px">
    <span style="background:#F7C842;color:#2D4A1E;font-size:13px;font-weight:600;padding:9px 18px;border-radius:9px">Continue</span>
    <span class="mono" style="font-size:10.5px;color:#9A9384">tmux · hf · 4-bit MLX · ready</span></div>
</div>"""
JOBS.append(write("rm-localai.html", 480, 430, localai, "setup-3-localai.png"))

# ---- 3. lemon-linear → connection tiles -------------------------------------
def conn(src, name, meta):
    g = f'<span class="src{" gh" if src=="gh" else ""}" style="min-width:24px;height:24px;border-radius:7px;font-size:11px">{src}</span>'
    return f"""<div style="display:flex;align-items:center;gap:11px;padding:12px 14px;border-radius:12px;
      background:rgba(255,255,255,.035);box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08);margin-top:9px">
      {g}<div style="flex:1"><div style="font-size:12.5px;font-weight:600">{name}</div>
      <div class="mono" style="font-size:10.5px;color:#9A9384;margin-top:2px">{meta}</div></div>
      <span class="dot" style="background:#45C27A;box-shadow:0 0 6px #45C27A"></span></div>"""
connect = f"""<div class="card" style="width:264px;padding:16px">
  <div style="display:flex;align-items:center;gap:7px"><span style="font-size:15px">🍋</span>
    <span style="font-size:12.5px;font-weight:700">watching</span>
    <span class="chip" style="margin-left:auto">2 sources</span></div>
  {conn("L","Engineering","Linear · 6 teams")}
  {conn("gh","acme/web","GitHub · main")}
</div>"""
JOBS.append(write("rm-connect.html", 360, 300, connect, "lemon-linear.png"))

# ---- 4. lemon-mini → menu-bar strip -----------------------------------------
WIFI = '<svg width="16" height="14" viewBox="0 0 16 13" style="opacity:.8"><path d="M8 11.2a1.3 1.3 0 1 0 0 .01M3.6 7.2a6.2 6.2 0 0 1 8.8 0M1.2 4.6a9.6 9.6 0 0 1 13.6 0M5.9 9.7a3 3 0 0 1 4.2 0" fill="none" stroke="#ECE6D8" stroke-width="1.3" stroke-linecap="round"/></svg>'
BATT = '<svg width="24" height="13" viewBox="0 0 25 13" style="opacity:.8"><rect x="1" y="2" width="20" height="9" rx="2.4" fill="none" stroke="#ECE6D8" stroke-width="1.2"/><rect x="2.6" y="3.6" width="13" height="5.8" rx="1.2" fill="#ECE6D8"/><rect x="22.4" y="4.4" width="1.8" height="4.2" rx=".9" fill="#ECE6D8"/></svg>'
SEARCH = '<svg width="14" height="14" viewBox="0 0 16 16" style="opacity:.75"><circle cx="7" cy="7" r="4.4" fill="none" stroke="#ECE6D8" stroke-width="1.3"/><path d="M10.4 10.4 14 14" stroke="#ECE6D8" stroke-width="1.3" stroke-linecap="round"/></svg>'
menubar = f"""<div class="card" style="width:404px;border-radius:13px;padding:0;overflow:hidden;background:rgba(20,15,9,.92)">
  <div style="display:flex;align-items:center;gap:15px;padding:9px 15px">
    <span class="mono" style="font-size:12.5px;font-weight:600;opacity:.82">Finder</span>
    <span style="margin-left:auto"></span>
    {WIFI}{BATT}{SEARCH}
    <span class="chip" style="gap:6px;padding:4px 11px 4px 8px;white-space:nowrap;background:rgba(247,200,66,.15);box-shadow:inset 0 0 0 .5px rgba(247,200,66,.32);color:#F7C842">
      <span style="font-size:13px">🍋</span><span class="dot" style="background:#45C27A;box-shadow:0 0 6px #45C27A"></span>2&nbsp;running</span>
    <span class="mono" style="font-size:12.5px;opacity:.72">Thu 26 Jun&nbsp;&nbsp;9:41</span>
  </div>
</div>"""
JOBS.append(write("rm-menubar.html", 480, 150, menubar, "lemon-mini.png"))

print("\n".join(f"{n} -> {png} ({w}x{h})" for n,w,h,png in JOBS))
