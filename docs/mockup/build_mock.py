"""Compute dashboard figures from the synthetic raw CSVs (same cleaning rules the
SILVER layer will apply) and render a branded dashboard mockup as HTML/SVG."""
import csv, datetime as dt, json, os, sys
from collections import defaultdict

RAW = sys.argv[1]
OUT = sys.argv[2]

def pdate(s):
    s = s.strip()
    for f in ("%Y-%m-%d", "%d/%m/%Y", "%Y%m%d"):
        try: return dt.datetime.strptime(s, f).date()
        except ValueError: pass
    return None

def pnum(s):
    s = s.strip().replace(",", "")
    try: return float(s)
    except ValueError: return None

def read(name):
    with open(os.path.join(RAW, name), newline="") as fh:
        rows = list(csv.DictReader(fh))
    seen, out = set(), []
    for r in rows:
        k = tuple(r.values())
        if k not in seen:
            seen.add(k); out.append(r)
    return out

SECTORS = ["Healthcare", "Software & Technology", "Business Services", "Industrials", "Consumer",
           "Education", "Financial Services", "Transportation & Logistics", "Food & Beverage", "Telecommunications"]
SECT = {s.lower(): s for s in SECTORS}
INSTR = ["Unitranche", "Senior Secured Term Loan", "Revolving Credit Facility", "Second Lien", "Holdco PIK Note"]
INS = {s.lower(): s for s in INSTR}
CTRY = {"gb": "United Kingdom", "gbr": "United Kingdom", "united kingdom": "United Kingdom",
        "de": "Germany", "deu": "Germany", "germany": "Germany", "fr": "France", "fra": "France", "france": "France",
        "nl": "Netherlands", "nld": "Netherlands", "netherlands": "Netherlands", "es": "Spain", "esp": "Spain", "spain": "Spain",
        "it": "Italy", "ita": "Italy", "italy": "Italy", "se": "Sweden", "swe": "Sweden", "sweden": "Sweden",
        "dk": "Denmark", "dnk": "Denmark", "denmark": "Denmark", "be": "Belgium", "bel": "Belgium", "belgium": "Belgium",
        "ie": "Ireland", "irl": "Ireland", "ireland": "Ireland", "pt": "Portugal", "prt": "Portugal", "portugal": "Portugal"}

borrowers = {r["borrower_id"]: {"name": r["borrower_name"], "sector": SECT[r["sector"].strip().lower()],
                                "country": CTRY[r["country"].strip().lower()]} for r in read("borrowers.csv")}
fac = {}
for r in read("facilities.csv"):
    c, o = pnum(r["commitment_amount"]), pdate(r["origination_date"])
    if c is None or o is None or r["borrower_id"] not in borrowers:
        continue
    fac[r["facility_id"]] = {"b": r["borrower_id"], "fund": r["fund_code"], "instr": INS[r["instrument_type"].strip().lower()],
                             "ccy": r["currency"].strip().upper(), "commit": c, "spread": int(r["spread_bps"]),
                             "floor": int(r["floor_bps"])}
fx = {}
for r in read("fx_rates.csv"):
    fx[(pdate(r["rate_date"]), r["currency"].strip().upper())] = float(r["eur_per_unit"])

marks = defaultdict(dict)  # month -> facility -> mark
for r in read("loan_marks.csv"):
    if r["facility_id"] not in fac: continue
    d = pdate(r["as_of_date"])
    marks[d][r["facility_id"]] = {"out": pnum(r["outstanding_principal"]), "px": float(r["fair_value_price"]),
                                  "rating": int(r["internal_rating"]) if r["internal_rating"].strip() else None,
                                  "dpd": int(r["days_past_due"]), "na": r["non_accrual_flag"] == "Y"}
months = sorted(marks)
M = months[-1]

def base(ccy, d):
    t = max((d.year - 2024) * 12 + d.month - 11, 0)
    return {"EUR": max(1.90, 3.00 - 0.09 * t), "GBP": max(3.75, 4.75 - 0.06 * t)}.get(ccy, max(3.60, 4.60 - 0.06 * t))

def snapshot(d):
    rows = []
    for fid, m in marks[d].items():
        f = fac[fid]; rate = fx[(d, f["ccy"])]
        out = m["out"] * rate
        rows.append({**f, **m, "fid": fid, "out_eur": out, "fv_eur": out * m["px"] / 100,
                     "commit_eur": f["commit"] * rate,
                     "allin": max(base(f["ccy"], d), f["floor"] / 100) + f["spread"] / 100})
    return rows

snap = snapshot(M)
prev = snapshot(months[-13])  # same month last year
def kpis(rows):
    out = sum(r["out_eur"] for r in rows)
    return {"commit": sum(r["commit_eur"] for r in rows), "out": out, "fv": sum(r["fv_eur"] for r in rows),
            "spread": sum(r["spread"] * r["out_eur"] for r in rows) / out,
            "allin": sum(r["allin"] * r["out_eur"] for r in rows) / out,
            "borrowers": len({r["b"] for r in rows}), "facilities": len(rows),
            "na_pct": 100 * sum(r["out_eur"] for r in rows if r["na"]) / out,
            "watch": sum(1 for r in rows if (r["rating"] or 0) >= 4 or r["na"])}
K, KP = kpis(snap), kpis(prev)

def group(rows, key):
    g = defaultdict(float)
    for r in rows: g[key(r)] += r["out_eur"]
    return sorted(g.items(), key=lambda x: -x[1])

sector = group(snap, lambda r: borrowers[r["b"]]["sector"])
country = group(snap, lambda r: borrowers[r["b"]]["country"])
instr = group(snap, lambda r: r["instr"])
rating = defaultdict(float)
for r in snap: rating[r["rating"] or 0] += r["out_eur"]

FUNDS = ["EDL-III", "EDL-IV", "SCF-I"]
trend = {f: [sum(r["out_eur"] for r in snapshot(d) if r["fund"] == f) for d in months] for f in FUNDS}

interest = defaultdict(float)
for r in read("cash_flows.csv"):
    if r["transaction_type"].strip().lower() == "interest" and r["facility_id"] in fac:
        d = pdate(r["transaction_date"]); md = dt.date(d.year, d.month, 1)
        me = max(x for x in months if x.year == d.year and x.month == d.month)
        interest[me] += pnum(r["amount"]) * fx[(me, r["currency"].strip().upper())]

watch = sorted([r for r in snap if (r["rating"] or 0) >= 4 or r["na"]], key=lambda r: (-(r["na"]), -(r["rating"] or 0), -r["out_eur"]))[:8]

# ---------------------------------------------------------------- render
m_ = lambda x: f"€{x/1e6:,.0f}m"
bn = lambda x: f"€{x/1e9:,.2f}bn"
def esc(s): return s.replace("&", "&amp;").replace("<", "&lt;")

def delta(cur, old, fmt, good_up=True, unit=""):
    d = cur - old
    up = d >= 0
    cls = "pos" if up == good_up else "neg"
    arrow = "▲" if up else "▼"
    return f'<span class="delta {cls}">{arrow} {fmt(abs(d))}{unit}</span><span class="vs"> vs Oct-25</span>'

tiles = [
    ("Total commitments", bn(K["commit"]), delta(K["commit"], KP["commit"], lambda v: f"€{v/1e9:.2f}bn")),
    ("Drawn / outstanding", bn(K["out"]), delta(K["out"], KP["out"], lambda v: f"€{v/1e9:.2f}bn")),
    ("Fair value", bn(K["fv"]), f'<span class="sub">{100*K["fv"]/K["out"]:.1f}% of par</span>'),
    ("W.avg spread", f'E+{K["spread"]:.0f}bps', delta(K["spread"], KP["spread"], lambda v: f"{v:.0f}", unit="bps")),
    ("W.avg all-in yield", f'{K["allin"]:.2f}%', delta(K["allin"], KP["allin"], lambda v: f"{v:.2f}", unit="pp")),
    ("Borrowers · facilities", f'{K["borrowers"]} · {K["facilities"]}', f'<span class="sub">{len(country)} countries · {len(sector)} sectors</span>'),
    ("Non-accrual", f'{K["na_pct"]:.1f}%', delta(K["na_pct"], KP["na_pct"], lambda v: f"{v:.1f}", good_up=False, unit="pp")),
]

def hbars(items, w=520, color="var(--navy)", top=None, label_w=190):
    items = items[:top] if top else items
    mx = max(v for _, v in items); tot = sum(v for _, v in (sector))
    bh, gap = 20, 9
    h = len(items) * (bh + gap)
    out = [f'<svg viewBox="0 0 {w} {h}" width="100%" role="img">']
    for i, (k, v) in enumerate(items):
        y = i * (bh + gap); bw = (w - label_w - 110) * v / mx
        out.append(f'<text x="{label_w-10}" y="{y+bh/2+4}" text-anchor="end" class="lbl">{esc(k)}</text>')
        out.append(f'<path d="M{label_w},{y} h{bw-4} a4,4 0 0 1 4,4 v{bh-8} a4,4 0 0 1 -4,4 h-{bw-4} z" fill="{color}"/>')
        out.append(f'<text x="{label_w+bw+8}" y="{y+bh/2+4}" class="val">{m_(v)} <tspan class="muted">{100*v/K["out"]:.0f}%</tspan></text>')
    out.append("</svg>")
    return "".join(out)

def line_chart(w=1000, h=300):
    pl, pr, pt, pb = 56, 90, 16, 30
    mx = max(max(v) for v in trend.values()) * 1.1
    mx = (int(mx / 1e9) + 1) * 1e9
    n = len(months)
    X = lambda i: pl + (w - pl - pr) * i / (n - 1)
    Y = lambda v: pt + (h - pt - pb) * (1 - v / mx)
    o = [f'<svg viewBox="0 0 {w} {h}" width="100%" role="img">']
    step = 1e9
    v = 0
    while v <= mx + 1:
        o.append(f'<line x1="{pl}" x2="{w-pr}" y1="{Y(v)}" y2="{Y(v)}" class="grid"/>')
        o.append(f'<text x="{pl-8}" y="{Y(v)+4}" text-anchor="end" class="tick">€{v/1e9:.0f}bn</text>')
        v += step
    for i, d in enumerate(months):
        if i % 3 == 0 or i == n - 1:
            o.append(f'<text x="{X(i)}" y="{h-8}" text-anchor="middle" class="tick">{d.strftime("%b-%y")}</text>')
    colors = {"EDL-III": "var(--s1)", "EDL-IV": "var(--s2)", "SCF-I": "var(--s3)"}
    ends = []
    for f in FUNDS:
        pts = " ".join(f"{X(i):.1f},{Y(v):.1f}" for i, v in enumerate(trend[f]))
        o.append(f'<polyline points="{pts}" fill="none" stroke="{colors[f]}" stroke-width="2" stroke-linejoin="round"/>')
        ends.append([Y(trend[f][-1]), f, trend[f][-1]])
    ends.sort()
    for i in range(1, len(ends)):
        if ends[i][0] - ends[i-1][0] < 32: ends[i][0] = ends[i-1][0] + 32
    for y, f, v in ends:
        o.append(f'<circle cx="{X(n-1)}" cy="{Y(trend[f][-1])}" r="4" fill="{colors[f]}" stroke="var(--card)" stroke-width="2"/>')
        o.append(f'<text x="{X(n-1)+10}" y="{y}" class="lbl b">{f}</text><text x="{X(n-1)+10}" y="{y+13}" class="val muted">{bn(v)}</text>')
    o.append("</svg>")
    return "".join(o)

def interest_bars(w=560, h=300):
    pl, pr, pt, pb = 44, 8, 16, 30
    vals = [interest[d] for d in months]
    mx = (int(max(vals) / 20e6) + 1) * 20e6
    n = len(vals); slot = (w - pl - pr) / n; bw = slot - 2
    Y = lambda v: pt + (h - pt - pb) * (1 - v / mx)
    o = [f'<svg viewBox="0 0 {w} {h}" width="100%" role="img">']
    v = 0
    while v <= mx + 1:
        o.append(f'<line x1="{pl}" x2="{w-pr}" y1="{Y(v)}" y2="{Y(v)}" class="grid"/><text x="{pl-6}" y="{Y(v)+4}" text-anchor="end" class="tick">{v/1e6:.0f}</text>')
        v += 20e6
    for i, val in enumerate(vals):
        x = pl + i * slot + 1; y = Y(val); hh = Y(0) - y
        o.append(f'<path d="M{x},{Y(0)} v-{hh-4} a4,4 0 0 1 4,-4 h{bw-8} a4,4 0 0 1 4,4 v{hh-4} z" fill="var(--s1)"/>')
        if i % 3 == 0:
            o.append(f'<text x="{x+bw/2}" y="{h-8}" text-anchor="middle" class="tick">{months[i].strftime("%b-%y")}</text>')
    last = vals[-1]
    o.append(f'<text x="{pl + (n-1)*slot + bw/2}" y="{Y(last)-8}" text-anchor="end" class="val">€{last/1e6:.1f}m</text>')
    o.append("</svg>")
    return "".join(o)

def rating_bar(w=520):
    labels = {1: "1 · Strong", 2: "2 · Satisfactory", 3: "3 · Monitor", 4: "4 · Watchlist", 5: "5 · Impaired", 0: "Not rated"}
    ramp = {1: "#B9D9EB", 2: "#6B94CE", 3: "#3D7CC9", 4: "#195094", 5: "#192C50", 0: "#D7D2CB"}
    tot = sum(rating.values()); x = 0
    o = [f'<svg viewBox="0 0 {w} 150" width="100%" role="img">']
    keys = [k for k in (1, 2, 3, 4, 5, 0) if rating.get(k)]
    for k in keys:
        bw = w * rating[k] / tot
        o.append(f'<rect x="{x+1}" y="0" width="{max(bw-2,1)}" height="34" rx="4" fill="{ramp[k]}"/>')
        x += bw
    for i, k in enumerate(keys):
        cx = (i % 3) * (w / 3); cy = 60 + (i // 3) * 44
        o.append(f'<rect x="{cx}" y="{cy}" width="12" height="12" rx="3" fill="{ramp[k]}"/>')
        o.append(f'<text x="{cx+18}" y="{cy+10}" class="lbl">{labels[k]}</text>')
        o.append(f'<text x="{cx+18}" y="{cy+27}" class="val">{100*rating[k]/tot:.1f}% <tspan class="muted">{m_(rating[k])}</tspan></text>')
    o.append("</svg>")
    return "".join(o)

def watch_table():
    rows = []
    for r in watch:
        b = borrowers[r["b"]]
        if r["na"]: st = '<span class="badge crit">■ Non-accrual</span>'
        elif r["rating"] == 5: st = '<span class="badge crit">■ Impaired</span>'
        else: st = '<span class="badge warn">▲ Watchlist</span>'
        rows.append(f'<tr><td class="strong">{esc(b["name"])}</td><td>{esc(b["sector"])}</td><td>{b["country"]}</td><td>{r["fund"]}</td>'
                    f'<td>{esc(r["instr"])}</td><td class="num">{m_(r["out_eur"])}</td><td class="num">{r["px"]:.1f}</td>'
                    f'<td class="num">{r["rating"] or "–"}</td><td class="num">{r["dpd"]}</td><td>{st}</td></tr>')
    return "".join(rows)

tiles_html = "".join(f'<div class="tile"><div class="tl">{t}</div><div class="tv">{v}</div><div class="td">{d}</div></div>' for t, v, d in tiles)

html = f"""<!doctype html><html><head><meta charset="utf-8"><title>Portfolio Monitor</title><style>
@font-face{{font-family:Baskerville;src:url(fonts/Libre-Baskerville-Regular.woff2)}}
@font-face{{font-family:Baskerville;font-weight:700;src:url(fonts/Libre-Baskerville-Bold.woff2)}}
@font-face{{font-family:Didot;src:url(fonts/GFSDidot-Regular.woff2)}}
:root{{--navy:#192C50;--blue:#3D7CC9;--blue2:#195094;--slate:#474D70;--stone:#D7D2CB;--ice:#EAF3F9;
--s1:#3D7CC9;--s2:#6BBD4A;--s3:#7D63BD;--page:#F4F2EE;--card:#FFFFFF;--ink:#192C50;--ink2:#474D70;--muted:#7F8496;
--grid:#E6E3DD;--warn:#fab219;--crit:#d03b3b;--good:#0ca30c}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--page);font-family:Inter,"Helvetica Neue",Arial,sans-serif;color:var(--ink)}}
header{{background:var(--navy);color:#fff;padding:22px 32px 18px;display:flex;align-items:flex-end;justify-content:space-between}}
header .eyebrow{{font-size:11px;letter-spacing:.18em;text-transform:uppercase;color:#B9D9EB}}
header h1{{font-family:Didot,Baskerville,serif;font-weight:400;font-size:34px;margin:4px 0 0;letter-spacing:.01em}}
header .meta{{font-size:12px;color:#B9D9EB;text-align:right;line-height:1.6}}
.filters{{display:flex;gap:10px;padding:14px 32px;background:#fff;border-bottom:1px solid var(--grid);align-items:center}}
.chip{{border:1px solid #CBCED6;border-radius:6px;padding:7px 12px;font-size:12.5px;color:var(--ink2);background:#fff}}
.chip b{{color:var(--ink);font-weight:600}} .chip.on{{border-color:var(--blue);box-shadow:inset 0 0 0 1px var(--blue)}}
.spacer{{flex:1}} .tag{{font-size:11px;color:var(--muted)}}
main{{padding:20px 32px 28px;display:grid;grid-template-columns:repeat(12,1fr);gap:16px}}
.card{{background:var(--card);border-radius:8px;border:1px solid rgba(25,44,80,.08);padding:18px 20px}}
.card h2{{font-family:Baskerville,serif;font-size:15.5px;font-weight:700;margin:0 0 2px;color:var(--navy)}}
.card .cap{{font-size:11.5px;color:var(--muted);margin:0 0 12px}}
.tiles{{grid-column:span 12;display:grid;grid-template-columns:repeat(7,1fr);gap:16px}}
.tile{{background:var(--card);border-radius:8px;border:1px solid rgba(25,44,80,.08);padding:14px 16px;border-top:3px solid var(--navy)}}
.tl{{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}}
.tv{{font-size:27px;font-weight:600;margin:6px 0 4px;color:var(--navy);letter-spacing:-.01em}}
.td{{font-size:11.5px}} .delta.pos{{color:#006300}} .delta.neg{{color:var(--crit)}} .vs,.sub{{color:var(--muted)}}
svg text{{font-family:Inter,sans-serif}} .lbl{{font-size:12px;fill:var(--ink2)}} .lbl.b{{font-weight:600;fill:var(--ink)}}
.val{{font-size:11.5px;fill:var(--ink);font-variant-numeric:tabular-nums}} .muted{{fill:var(--muted);color:var(--muted)}}
.tick{{font-size:10.5px;fill:var(--muted);font-variant-numeric:tabular-nums}} .grid{{stroke:var(--grid);stroke-width:1}}
.legend{{display:flex;gap:16px;font-size:12px;color:var(--ink2);margin:-4px 0 6px}} .legend i{{display:inline-block;width:14px;height:3px;border-radius:2px;margin-right:6px;vertical-align:middle}}
table{{width:100%;border-collapse:collapse;font-size:12.5px}} th{{text-align:left;font-weight:600;color:var(--muted);font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;padding:6px 8px;border-bottom:1px solid var(--grid)}}
td{{padding:8px;border-bottom:1px solid #F0EEEA;color:var(--ink2)}} td.strong{{color:var(--ink);font-weight:600}} .num{{text-align:right;font-variant-numeric:tabular-nums}} th.num{{text-align:right}}
.badge{{font-size:11px;font-weight:600;padding:3px 8px;border-radius:4px;white-space:nowrap}} .badge.warn{{background:#FEF3D6;color:#8A5A00}} .badge.crit{{background:#FBE3E3;color:#A32626}}
.ghost{{border:1.5px dashed var(--blue);background:var(--ice);display:flex;flex-direction:column;justify-content:center}}
.ghost h2{{color:var(--blue2)}} .ghost p{{font-size:12px;color:var(--ink2);margin:6px 0 0;line-height:1.5}} .ghost code{{font-family:"JetBrains Mono",monospace;font-size:11.5px;background:#fff;padding:1px 5px;border-radius:3px;color:var(--navy)}}
footer{{padding:0 32px 22px;font-size:11px;color:var(--muted)}}
</style></head><body>
<header><div><div class="eyebrow">Private Credit · Portfolio Monitoring</div><h1>Direct Lending Portfolio Monitor</h1></div>
<div class="meta">As of 31 October 2026 · Reporting currency EUR<br>Source: bi views over dbo · refreshed nightly</div></header>
<div class="filters"><span class="chip on">Fund: <b>All funds</b> ▾</span><span class="chip">As of: <b>Oct-2026</b> ▾</span><span class="chip">Sector: <b>All</b> ▾</span>
<span class="chip">Country: <b>All</b> ▾</span><span class="chip">Instrument: <b>All</b> ▾</span><span class="spacer"></span><span class="tag">Metabase · Postgres: staging → dbo (procedures) → bi (views) · synthetic demo data</span></div>
<main>
<div class="tiles">{tiles_html}</div>
<div class="card" style="grid-column:span 8"><h2>Outstanding exposure by fund</h2><p class="cap">Month-end drawn principal, EUR · Nov-24 to Oct-26</p>
<div class="legend"><span><i style="background:var(--s1)"></i>EDL-III</span><span><i style="background:var(--s2)"></i>EDL-IV</span><span><i style="background:var(--s3)"></i>SCF-I</span></div>{line_chart()}</div>
<div class="card" style="grid-column:span 4"><h2>Cash interest received</h2><p class="cap">Monthly, EUR m · excludes PIK and non-accrual</p>{interest_bars()}</div>
<div class="card" style="grid-column:span 4"><h2>Exposure by sector</h2><p class="cap">Outstanding, EUR · share of portfolio</p>{hbars(sector)}</div>
<div class="card" style="grid-column:span 4"><h2>Exposure by country</h2><p class="cap">Outstanding, EUR · share of portfolio</p>{hbars(country, label_w=130)}</div>
<div class="card" style="grid-column:span 4;display:flex;flex-direction:column;gap:18px">
<div><h2>Instrument mix</h2><p class="cap">Outstanding, EUR</p>{hbars(instr, label_w=180, color="var(--blue)")}</div>
<div><h2>Internal rating distribution</h2><p class="cap">% of outstanding · 1 strong → 5 impaired</p>{rating_bar()}</div></div>
<div class="card" style="grid-column:span 9"><h2>Watchlist &amp; non-accrual</h2><p class="cap">Facilities rated 4–5 or on non-accrual · {K["watch"]} facilities · top 8 by severity</p>
<table><thead><tr><th>Borrower</th><th>Sector</th><th>Country</th><th>Fund</th><th>Instrument</th><th class="num">Outstanding</th><th class="num">Price</th><th class="num">Rating</th><th class="num">DPD</th><th>Status</th></tr></thead><tbody>{watch_table()}</tbody></table></div>
<div class="card ghost" style="grid-column:span 3"><h2>Net leverage (x EBITDA)</h2><p>Reserved for part 2 of the demo. The new column <code>net_leverage</code> = (total debt − cash) ÷ LTM EBITDA is specified, built and tested by AI from a spec, then flows staging → dbo → bi → here.</p></div>
</main><footer>Illustrative mockup built from the synthetic demo dataset ({K["facilities"]} facilities, {K["borrowers"]} borrowers, 3 funds). Not real portfolio data.</footer>
</body></html>"""
open(OUT, "w").write(html)
print(json.dumps({k: round(v, 2) if isinstance(v, float) else v for k, v in K.items()}, indent=1))
print("sector", [(k, round(v/1e6)) for k, v in sector][:4]); print("watch", len(watch))
