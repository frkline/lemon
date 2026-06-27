#!/usr/bin/env python3
"""Generate the README hero banner (Daylight + Midnight) from the Lemon
design tokens. Renders to PNG via headless Chrome; embedded in README.md
through a <picture> that swaps on GitHub's light/dark.

Per the app's own rule, the menu-bar popover is warm-dark glass in BOTH
themes (it depicts the real app over a desktop); only the page background
and headline ink flip between Daylight and Midnight."""
import pathlib

OUT = pathlib.Path("/Users/frank/Projects/lemon/design/landing/readme-hero")
OUT.mkdir(parents=True, exist_ok=True)

THEMES = {
  "light": {
    "page": "radial-gradient(125% 90% at 14% -10%, #FCF8F0 0%, #F4EEE0 46%, #ECE3D0 100%)",
    "ink": "#241D12", "ink2": "rgba(40,32,18,.66)", "ink3": "rgba(40,32,18,.44)",
    "hair": "rgba(40,32,18,.12)", "accent": "#B07E1A",
  },
  "dark": {
    "page": "radial-gradient(125% 90% at 14% -10%, #2f2740 0%, #201a13 42%, #15100a 100%)",
    "ink": "#ECE6D8", "ink2": "rgba(236,230,216,.66)", "ink3": "rgba(236,230,216,.42)",
    "hair": "rgba(236,230,216,.12)", "accent": "#F7C842",
  },
}

# The popover card — identical across themes (always warm-dark glass).
POPOVER = """
<div class="scene">
  <div class="pop">
    <div class="phead">
      <span class="brand"><span class="lm">🍋</span> Lemon</span>
      <span class="count"><i></i>2 running</span>
    </div>
    <div class="srow">
      <div class="r1"><span class="src">L</span><span class="id mono">LEM-42</span>
        <span class="st"><span class="d" style="--c:#F7C842"></span>Executing</span></div>
      <div class="title">Wire up the Liquid Glass token set</div>
      <div class="term mono">› claude --permission-mode auto …</div>
    </div>
    <div class="srow b">
      <div class="r1"><span class="src gh">gh</span><span class="id mono">acme/web#7</span>
        <span class="st"><span class="d" style="--c:#FF6B46"></span>Waiting</span></div>
      <div class="title">Re-trigger fires on shipped revisions</div>
    </div>
  </div>
</div>"""

def banner(theme, t):
  return f"""<!doctype html><html><head><meta charset="utf-8"><style>
*{{box-sizing:border-box;margin:0;padding:0}}
.mono{{font-family:"SF Mono",ui-monospace,Menlo,monospace;font-feature-settings:"ss01"}}
html,body{{width:1200px;height:420px}}
.banner{{position:relative;width:1200px;height:420px;overflow:hidden;
  background:{t['page']};
  font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
  display:flex;align-items:center}}
/* warm light bloom behind the headline */
.banner::before{{content:"";position:absolute;inset:0;
  background:radial-gradient(48% 60% at 76% 18%, rgba(247,200,66,.18), transparent 60%),
             radial-gradient(40% 50% at 90% 92%, rgba(255,107,70,.10), transparent 60%);
  pointer-events:none}}

.copy{{position:relative;z-index:2;padding:0 0 0 72px;width:640px;flex:none;
  display:flex;flex-direction:column;justify-content:center}}
.eyebrow{{display:inline-flex;align-items:center;gap:9px;color:{t['ink3']};
  font-size:12.5px;font-weight:700;letter-spacing:1.8px;text-transform:uppercase}}
.eyebrow .dot{{width:7px;height:7px;border-radius:50%;background:#F7C842;flex:none}}
.eyebrow .lm{{font-size:15px;letter-spacing:0}}
h1{{margin:22px 0 0;color:{t['ink']};font-size:66px;line-height:.94;
  letter-spacing:-2.4px;font-weight:700}}
h1 em{{font-style:italic;font-weight:700;color:{t['accent']}}}
.sub{{margin:20px 0 0;color:{t['ink2']};font-size:17.5px;line-height:1.5;
  letter-spacing:-.1px;max-width:33ch;font-weight:400}}
.spec{{margin:30px 0 0;display:inline-flex;align-items:center;gap:10px;
  color:{t['ink3']};font-size:13px;letter-spacing:.2px}}
.spec .pr{{color:{t['accent']};font-weight:700}}
.spec b{{color:{t['ink2']};font-weight:600}}

/* ---- popover scene (always warm-dark glass) ---- */
.scene{{position:absolute;right:0;top:0;height:420px;width:560px;z-index:1;
  display:flex;align-items:center;justify-content:flex-start;
  -webkit-mask-image:linear-gradient(to right,#000 0%,#000 62%,transparent 99%);
          mask-image:linear-gradient(to right,#000 0%,#000 62%,transparent 99%)}}
.pop{{width:384px;border-radius:18px;overflow:hidden;
  background:rgba(26,20,12,.80);backdrop-filter:blur(26px) saturate(1.3);
  box-shadow:inset 0 0 0 .5px rgba(255,255,255,.10),0 40px 90px rgba(12,8,3,.42);
  color:#ECE6D8;transform:translateY(2px)}}
.phead{{display:flex;align-items:center;gap:9px;padding:15px 16px 13px;
  box-shadow:inset 0 -.5px 0 rgba(255,255,255,.08)}}
.phead .brand{{font-size:14px;font-weight:700;display:flex;align-items:center;gap:6px}}
.phead .brand .lm{{font-size:14px}}
.phead .count{{margin-left:auto;display:inline-flex;align-items:center;gap:6px;
  font-size:11px;font-weight:600;color:#C9C2B2;
  background:rgba(255,255,255,.05);padding:4px 9px;border-radius:999px;
  box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08)}}
.phead .count i{{width:6px;height:6px;border-radius:50%;background:#45C27A;
  box-shadow:0 0 7px #45C27A}}
.srow{{padding:13px 16px}}
.srow.b{{box-shadow:inset 0 .5px 0 rgba(255,255,255,.07)}}
.r1{{display:flex;align-items:center;gap:8px}}
.src{{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;
  padding:0 5px;border-radius:6px;font-size:9.5px;font-weight:700;
  font-family:"SF Mono",ui-monospace,Menlo,monospace;color:#EAAE3A;
  background:rgba(234,174,58,.12);box-shadow:inset 0 0 0 .5px rgba(234,174,58,.28)}}
.src.gh{{color:#6BD180;background:rgba(107,209,128,.12);
  box-shadow:inset 0 0 0 .5px rgba(107,209,128,.28)}}
.id{{font-size:11px;font-weight:600;color:#A9A293}}
.st{{margin-left:auto;display:inline-flex;align-items:center;gap:5px;font-size:11px;
  font-weight:600;color:#C9C2B2}}
.st .d{{width:6px;height:6px;border-radius:50%;background:var(--c);box-shadow:0 0 6px var(--c)}}
.title{{margin-top:7px;font-size:13px;font-weight:500;color:#ECE6D8;letter-spacing:-.1px}}
.term{{margin-top:9px;font-size:11.5px;color:#C9BFA6;background:#17110A;
  padding:8px 11px;border-radius:9px;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.05);
  white-space:nowrap}}
</style></head><body>
<div class="banner">
  <div class="copy">
    <span class="eyebrow"><span class="dot"></span><span class="lm">🍋</span> Lemon · menu-bar orchestrator</span>
    <h1>Claude&nbsp;Code,<br>no&nbsp;<em>cruft.</em></h1>
    <p class="sub">Tag an issue with 🍋. Lemon spins the worktree, runs your own <span class="mono">claude</span>, and ships the PR.</p>
    <div class="spec mono"><span class="pr">›</span> <b>macOS&nbsp;26</b> · Gemma&nbsp;4 on-device · Linear&nbsp;+&nbsp;GitHub</div>
  </div>
  {POPOVER}
</div>
</body></html>"""

for name, t in THEMES.items():
  (OUT / f"hero-{name}.html").write_text(banner(name, t))
  print("wrote", OUT / f"hero-{name}.html")
