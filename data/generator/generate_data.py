#!/usr/bin/env python3
"""Synthetic data generator for a European direct-lending (private credit) fund.

Produces the raw CSV extracts that feed the BRONZE layer. The data is fully
synthetic (no real companies), deterministic (fixed seed) and deliberately
"dirty" in the ways real source extracts are, so that the SILVER layer has
real cleaning work to do:

  * mixed date formats (ISO, DD/MM/YYYY, YYYYMMDD)
  * amounts formatted with thousands separators, sometimes blank
  * inconsistent casing / stray whitespace in categorical fields
  * country written as ISO-2, ISO-3 or full name
  * lower-case currency codes
  * ~1.5% exact duplicate rows
  * a few unparseable rows that must be rejected

Only the Python standard library is used.

Usage:  python3 data/generator/generate_data.py [--out data/raw] [--seed 42]
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import itertools
import math
import os
import random

# --------------------------------------------------------------------------
# Reference data
# --------------------------------------------------------------------------
COUNTRIES = [
    # iso2, iso3, full name, legal suffix, weight
    ("GB", "GBR", "United Kingdom", "Ltd", 26),
    ("DE", "DEU", "Germany", "GmbH", 18),
    ("FR", "FRA", "France", "SAS", 16),
    ("NL", "NLD", "Netherlands", "B.V.", 9),
    ("ES", "ESP", "Spain", "S.L.", 8),
    ("IT", "ITA", "Italy", "S.r.l.", 7),
    ("SE", "SWE", "Sweden", "AB", 5),
    ("DK", "DNK", "Denmark", "ApS", 3),
    ("BE", "BEL", "Belgium", "SA", 3),
    ("IE", "IRL", "Ireland", "Ltd", 3),
    ("PT", "PRT", "Portugal", "Lda", 2),
]
COUNTRY_CCY = {"GB": "GBP", "SE": "EUR", "DK": "EUR"}  # everyone else EUR

SECTORS = [
    ("Healthcare", 15),
    ("Software & Technology", 18),
    ("Business Services", 16),
    ("Industrials", 12),
    ("Consumer", 8),
    ("Education", 6),
    ("Financial Services", 7),
    ("Transportation & Logistics", 7),
    ("Food & Beverage", 6),
    ("Telecommunications", 5),
]

NAME_A = [
    "Nord",
    "Alta",
    "Vero",
    "Lumen",
    "Castell",
    "Aurel",
    "Brava",
    "Cobalt",
    "Delta",
    "Ever",
    "Fjord",
    "Gran",
    "Helio",
    "Iber",
    "Juno",
    "Kestrel",
    "Lago",
    "Marin",
    "Nova",
    "Orion",
    "Pala",
    "Quill",
    "Rhea",
    "Solano",
    "Terra",
    "Ulmo",
    "Vanta",
    "Wester",
    "Xeno",
    "Zenit",
]
NAME_B = [
    "wind",
    "bridge",
    "point",
    "field",
    "stone",
    "gate",
    "crest",
    "vale",
    "line",
    "mark",
    "path",
    "core",
    "haven",
    "works",
    "spring",
    "light",
]
NAME_C = {
    "Healthcare": ["Clinics", "Pharma", "Dental Group", "Diagnostics", "Care"],
    "Software & Technology": ["Software", "Systems", "Analytics", "Cloud", "Digital"],
    "Business Services": ["Consulting", "Services", "Outsourcing", "Partners"],
    "Industrials": ["Engineering", "Manufacturing", "Components", "Industries"],
    "Consumer": ["Brands", "Retail", "Leisure", "Living"],
    "Education": ["Learning", "Academy", "Education", "Schools"],
    "Financial Services": [
        "Payments",
        "Insurance Services",
        "Finance",
        "Capital Services",
    ],
    "Transportation & Logistics": ["Logistics", "Freight", "Transport", "Mobility"],
    "Food & Beverage": ["Foods", "Beverages", "Bakeries", "Ingredients"],
    "Telecommunications": ["Telecom", "Networks", "Fibre", "Connect"],
}
SPONSORS = [
    "Arden Equity Partners",
    "Blackmoor Capital",
    "Calder & Co Private Equity",
    "Dunmore Investors",
    "Elmstead Partners",
    "Foxley Capital",
    "Greyhaven Equity",
    "Hartwell Partners",
    "Ivyridge Capital",
    "Juniper Lane Equity",
    "Kingsmere Partners",
    "Larchfield Capital",
    None,
]  # None = sponsorless

FUNDS = [
    # code, name, vintage, strategy, size EUR
    (
        "EDL-III",
        "European Direct Lending Fund III",
        2021,
        "Senior Direct Lending",
        3_500_000_000,
    ),
    (
        "EDL-IV",
        "European Direct Lending Fund IV",
        2024,
        "Senior Direct Lending",
        5_000_000_000,
    ),
    (
        "SCF-I",
        "Strategic Credit Fund I",
        2022,
        "Opportunistic / Junior Credit",
        1_500_000_000,
    ),
]

INSTRUMENTS = [
    # name, weight, spread range bps, typical share of commitment drawn
    ("Unitranche", 40, (500, 675)),
    ("Senior Secured Term Loan", 30, (425, 575)),
    ("Revolving Credit Facility", 12, (350, 450)),
    ("Second Lien", 10, (725, 900)),
    ("Holdco PIK Note", 8, (900, 1150)),
    ("Equity co-invest", 4, (0, 0)),  # spec 003: priced PER_UNIT, no coupon
]
EQUITY = "Equity co-invest"

FUND_TERMS = [
    # spec 005: code, mgmt fee % p.a., fee basis, frequency, expenses % p.a., carry %, hurdle % p.a., catch-up %
    ("EDL-III", 1.00, "INVESTED", "Q", 0.15, 10.0, 6.0, 100.0),
    ("EDL-IV", 0.90, "INVESTED", "Q", 0.12, 10.0, 6.0, 100.0),
    ("SCF-I", 1.50, "INVESTED", "Q", 0.20, 15.0, 8.0, 100.0),
]
BASE_RATE = {"EUR": "EURIBOR 3M", "GBP": "SONIA", "USD": "SOFR"}

FIRST_MONTH = dt.date(2024, 11, 30)
N_MONTHS = 24  # Nov-2024 .. Oct-2026


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def month_end(year: int, month: int) -> dt.date:
    nxt = dt.date(year + (month == 12), month % 12 + 1, 1)
    return nxt - dt.timedelta(days=1)


def add_months(d: dt.date, n: int) -> dt.date:
    m = d.month - 1 + n
    return month_end(d.year + m // 12, m % 12 + 1)


MONTHS = [add_months(FIRST_MONTH, i) for i in range(N_MONTHS)]


def base_rate_pct(ccy: str, d: dt.date) -> float:
    """Simple stylised reference-rate path (% p.a.)."""
    t = (d.year - 2024) * 12 + d.month - 11  # months since Nov-2024
    t = max(t, 0)
    if ccy == "EUR":
        return max(1.90, 3.00 - 0.09 * t)
    if ccy == "GBP":
        return max(3.75, 4.75 - 0.06 * t)
    return max(3.60, 4.60 - 0.06 * t)


def weighted(rng: random.Random, items):
    return rng.choices(
        items,
        weights=[i[-1] if isinstance(i[-1], (int, float)) else i[1] for i in items],
    )[0]


class Dirt:
    """Applies source-system messiness to individual values."""

    def __init__(self, rng: random.Random, rate: float = 0.12):
        self.rng, self.rate = rng, rate

    def hit(self, mult: float = 1.0) -> bool:
        return self.rng.random() < self.rate * mult

    def date(self, d: dt.date | None) -> str:
        if d is None:
            return ""
        if self.hit():
            return d.strftime("%d/%m/%Y")
        if self.hit(0.4):
            return d.strftime("%Y%m%d")
        return d.isoformat()

    def amount(self, x: float | None, decimals: int = 2) -> str:
        if x is None:
            return ""
        if self.hit():
            return f"{x:,.{decimals}f}"
        return f"{x:.{decimals}f}"

    def category(self, s: str) -> str:
        r = self.rng.random()
        if r < self.rate * 0.5:
            return s.upper()
        if r < self.rate:
            return f"  {s.lower()} "
        return s

    def country(self, iso2: str) -> str:
        iso3, name = next((c[1], c[2]) for c in COUNTRIES if c[0] == iso2)
        r = self.rng.random()
        if r < self.rate:
            return name
        if r < self.rate * 1.5:
            return iso3
        if r < self.rate * 1.8:
            return iso2.lower()
        return iso2

    def ccy(self, c: str) -> str:
        return c.lower() if self.hit(0.5) else c

    def price(self, p: float | None, decimals: int = 2) -> str:
        """Transaction price as the administrator sends it (spec 003): blank 6%,
        '0' 2%, comma decimal 3%, otherwise a plain number."""
        if p is None:
            return ""
        r = self.rng.random()
        if r < 0.06:
            return ""
        if r < 0.08:
            return "0"
        if r < 0.11:
            return f"{p:.{decimals}f}".replace(".", ",")
        return f"{p:.{decimals}f}"


def dirt_free_date(v: str) -> dt.date | None:
    """Parse the three dirty date formats the generator emits (YYYY-MM-DD, DD/MM/YYYY, YYYYMMDD)."""
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y%m%d"):
        try:
            return dt.datetime.strptime(v, fmt).date()
        except ValueError:
            pass
    return None


def write_csv(
    path: str, header: list[str], rows: list[list], rng: random.Random, dup_rate=0.015
):
    out = list(rows)
    # inject exact duplicates (typical of re-sent extracts)
    for r in rows:
        if rng.random() < dup_rate:
            out.insert(rng.randrange(len(out) + 1), list(r))
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(out)
    return len(out)


def fund_cash_flows(ledger, fx_map, rng):
    """Spec 005 section 3.1: LP calls / distributions and quarterly fees per fund, in EUR, from each
    fund's first drawdown month to the last month. Flows before the first FX month-end use the
    first rate (decision D1). Returns (dirty rows incl. 2 planted bad rows, next flow number)."""
    dirt = Dirt(rng)
    first_fx = MONTHS[0]

    def eur(d, amt, ccy):
        me = month_end(d.year, d.month)
        return amt * fx_map[(max(me, first_fx), ccy)]

    month = {}  # (fund, month_end) -> {drawn, inflow}
    for fund, d, typ, amt, ccy in ledger:
        if typ == "PIK":
            continue  # capitalised, not cash
        k = (fund, month_end(d.year, d.month))
        b = month.setdefault(k, {"drawn": 0.0, "repaid": 0.0, "inflow": 0.0})
        e = eur(d, amt, ccy)
        if typ == "Drawdown":
            b["drawn"] += e
        else:
            b["inflow"] += e
            if typ == "Repayment":
                b["repaid"] += e

    rows, n = [], 0
    for code, fee_pct, _, _, exp_pct, *_ in FUND_TERMS:
        ms = sorted(m for f, m in month if f == code)
        if not ms:
            continue
        m, invested = ms[0], 0.0
        # zeros for the months of the first quarter before the first drawdown
        q_bal = [0.0] * ((m.month - 1) % 3)
        while m <= MONTHS[-1]:
            b = month.get((code, m), {"drawn": 0.0, "repaid": 0.0, "inflow": 0.0})
            invested = max(invested + b["drawn"] - b["repaid"], 0.0)
            q_bal.append(invested)
            flows = []
            if m.month in (
                3,
                6,
                9,
                12,
            ):  # quarterly in arrears on average invested cost
                avg = sum(q_bal) / len(q_bal)
                q_bal = []
                flows += [
                    ("mgmt_fee", fee_pct / 100 * avg * 90 / 365),
                    ("fund_expense", exp_pct / 100 * avg * 90 / 365),
                ]
            call = b["drawn"] + sum(amt for _, amt in flows)
            flows += [("lp_call", call), ("lp_distribution", b["inflow"])]
            for typ, amt in flows:
                if amt <= 0 and typ.startswith("lp_"):
                    continue
                n += 1
                rows.append(
                    [
                        f"FF{n:06d}",
                        code,
                        dirt.date(m),
                        dirt.category(
                            typ.replace("lp_", "LP_") if rng.random() < 0.3 else typ
                        ),
                        f"{amt:.2f}",
                        dirt.ccy("EUR"),
                    ]
                )
            m = add_months(m, 1)
    rows.append(
        [
            f"FF{n + 1:06d}",
            "XX-9",
            MONTHS[5].isoformat(),
            "lp_call",
            "1000000.00",
            "EUR",
        ]
    )  # unknown fund
    rows.append(
        [
            f"FF{n + 2:06d}",
            "EDL-IV",
            MONTHS[5].isoformat(),
            "mgmt_fee",
            "-12500.00",
            "EUR",
        ]
    )  # negative amount
    return rows, n + 3


# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------
def generate(out_dir: str, seed: int) -> None:
    rng = random.Random(seed)
    dirt = Dirt(rng)
    os.makedirs(out_dir, exist_ok=True)
    counts = {}

    # ---- funds ---------------------------------------------------------
    fund_rows = [[c, n, v, s, f"{size:.0f}", "EUR"] for c, n, v, s, size in FUNDS]
    counts["funds"] = write_csv(
        os.path.join(out_dir, "funds.csv"),
        [
            "fund_code",
            "fund_name",
            "vintage_year",
            "strategy",
            "fund_size_eur",
            "base_currency",
        ],
        fund_rows,
        rng,
        dup_rate=0,
    )

    # ---- borrowers -----------------------------------------------------
    borrowers = []
    used = set()
    for i in range(1, 141):
        iso2 = weighted(rng, COUNTRIES)[0]
        sector = weighted(rng, SECTORS)[0]
        while True:
            name = (
                f"{rng.choice(NAME_A)}{rng.choice(NAME_B)} {rng.choice(NAME_C[sector])}"
            )
            if name not in used:
                used.add(name)
                break
        suffix = next(c[3] for c in COUNTRIES if c[0] == iso2)
        b = {
            "id": f"B{i:04d}",
            "name": f"{name} {suffix}",
            "sector": sector,
            "country": iso2,
            "sponsor": rng.choice(SPONSORS),
            # latent credit health: drift of EBITDA per quarter
            "drift": rng.gauss(0.015, 0.035),
            "vol": rng.uniform(0.02, 0.06),
            "ebitda0": rng.uniform(12, 140) * 1e6,
            "lev0": rng.uniform(3.8, 6.4),
            "cash_ratio": rng.uniform(0.04, 0.18),
            "margin": rng.uniform(0.12, 0.32),
        }
        borrowers.append(b)

    b_rows = []
    for b in borrowers:
        b_rows.append(
            [
                b["id"],
                b["name"],
                dirt.category(b["sector"]),
                dirt.country(b["country"]),
                b["sponsor"] or "",
                dt.date(rng.randint(1975, 2016), 1, 1).year,
            ]
        )
    counts["borrowers"] = write_csv(
        os.path.join(out_dir, "borrowers.csv"),
        [
            "borrower_id",
            "borrower_name",
            "sector",
            "country",
            "pe_sponsor",
            "founded_year",
        ],
        b_rows,
        rng,
    )

    # ---- borrower financials (quarterly, LTM) -----------------------------
    # Quarter ends from Q4-2024 .. Q3-2026 (8 quarters)
    quarters = [
        month_end(y, m)
        for y, m in [
            (2024, 12),
            (2025, 3),
            (2025, 6),
            (2025, 9),
            (2025, 12),
            (2026, 3),
            (2026, 6),
            (2026, 9),
        ]
    ]
    fin_rows = []
    health: dict[str, dict[dt.date, float]] = {}  # borrower -> {quarter_end: leverage}
    for b in borrowers:
        ebitda = b["ebitda0"]
        debt = b["ebitda0"] * b["lev0"]
        health[b["id"]] = {}
        stressed = rng.random() < 0.08  # ~8% of the book deteriorates
        for qi, q in enumerate(quarters):
            shock = rng.gauss(
                b["drift"] - (0.07 if stressed and qi >= 3 else 0), b["vol"]
            )
            ebitda = max(ebitda * (1 + shock), b["ebitda0"] * 0.15)
            debt = debt * (1 + rng.gauss(-0.005, 0.01))  # light amortisation / add-ons
            cash = debt * b["cash_ratio"] * rng.uniform(0.7, 1.3)
            revenue = ebitda / b["margin"]
            int_exp = debt * rng.uniform(0.075, 0.105)
            health[b["id"]][q] = (debt - cash) / ebitda
            fin_rows.append(
                [
                    b["id"],
                    dirt.date(q),
                    dirt.amount(revenue, 0),
                    dirt.amount(ebitda, 0),
                    dirt.amount(debt, 0),
                    dirt.amount(cash, 0),
                    dirt.amount(int_exp, 0),
                    "EUR",
                ]
            )
    # a couple of rows with missing EBITDA (late reporting)
    for r in rng.sample(fin_rows, 6):
        r[3] = ""
    counts["borrower_financials"] = write_csv(
        os.path.join(out_dir, "borrower_financials.csv"),
        [
            "borrower_id",
            "period_end_date",
            "revenue_ltm",
            "ebitda_ltm",
            "total_debt",
            "cash_and_equivalents",
            "interest_expense_ltm",
            "reporting_currency",
        ],
        fin_rows,
        rng,
    )

    def lev_at(bid: str, d: dt.date) -> float:
        # latest available quarter on/before d (else first quarter)
        qs = [q for q in quarters if q <= d]
        return health[bid][qs[-1] if qs else quarters[0]]

    # ---- facilities ------------------------------------------------------
    facilities = []
    fid = 0
    for b in borrowers:
        n_fac = rng.choices([1, 2, 3], weights=[55, 35, 10])[0]
        ccy = COUNTRY_CCY.get(b["country"], "EUR")
        if rng.random() < 0.08:
            ccy = "USD"
        orig = dt.date(2021, 1, 15) + dt.timedelta(days=rng.randint(0, 2000))
        if orig > dt.date(2026, 9, 30):
            orig = dt.date(2026, 9, 30) - dt.timedelta(days=rng.randint(0, 400))
        fund = "EDL-III" if orig.year < 2024 else "EDL-IV"
        if rng.random() < 0.18:
            fund = "SCF-I"
        used_instr = set()
        for k in range(n_fac):
            fid += 1
            choices = [i for i in INSTRUMENTS if i[0] not in used_instr]
            if fund == "SCF-I":
                choices = [
                    i
                    for i in choices
                    if i[0] in ("Second Lien", "Holdco PIK Note", "Unitranche")
                ] or choices
            instr, _, (lo, hi) = weighted(rng, choices)
            used_instr.add(instr)
            commitment = round(rng.uniform(10, 90) * 1e6 / 5e5) * 5e5
            if instr == "Revolving Credit Facility":
                commitment = round(commitment * 0.3 / 5e5) * 5e5 or 5e6
            o = orig + dt.timedelta(days=rng.randint(0, 120) if k else 0)
            tenor = 5 if instr == "Revolving Credit Facility" else rng.choice([6, 7])
            mat = dt.date(o.year + tenor, o.month, min(o.day, 28))
            repaid = None
            if rng.random() < 0.10:  # early refinancing during the window
                repaid = rng.choice(MONTHS[3:-2])
                if repaid <= o:
                    repaid = None
            is_eq = instr == EQUITY
            if is_eq:
                commitment = round(commitment * 0.15 / 5e5) * 5e5 or 5e6
            facilities.append(
                {
                    "id": f"F{fid:05d}",
                    "borrower": b["id"],
                    "fund": fund,
                    "instr": instr,
                    "ccy": ccy,
                    "commitment": commitment,
                    "equity": is_eq,
                    "spread": rng.randrange(lo, hi + 1, 25),
                    "floor": 0 if is_eq else rng.choice([0, 0, 50, 75, 100]),
                    # debt: OID price per 100; equity: acquisition price per unit (1 unit = 1.00 invested)
                    "oid": round(rng.uniform(0.95, 1.05), 2)
                    if is_eq
                    else rng.choice([97.5, 98.0, 98.5, 99.0, 99.5]),
                    "orig": o,
                    "mat": mat,
                    "repaid": repaid,
                    "draw_share": rng.uniform(0.0, 0.6)
                    if instr == "Revolving Credit Facility"
                    else 1.0,
                    "amort": 0.01
                    if instr in ("Senior Secured Term Loan", "Unitranche")
                    else 0.0,
                }
            )

    fac_rows = []
    for f in facilities:
        fac_rows.append(
            [
                f["id"],
                f["borrower"],
                f["fund"],
                dirt.category(f["instr"]),
                dirt.ccy(f["ccy"]),
                dirt.amount(f["commitment"]),
                "" if f["equity"] else BASE_RATE[f["ccy"]],
                f["spread"],
                f["floor"],
                f"{f['oid']:.2f}",
                dirt.date(f["orig"]),
                dirt.date(f["mat"]),
            ]
        )
    # unparseable rows that the silver layer must reject
    fac_rows.append(
        [
            "F99901",
            "B0001",
            "EDL-IV",
            "Unitranche",
            "EUR",
            "TBC",
            "EURIBOR 3M",
            "550",
            "0",
            "99.00",
            "2026-02-30",
            "2033-02-28",
        ]
    )
    fac_rows.append(
        [
            "F99902",
            "B9999",
            "EDL-IV",
            "Unitranche",
            "EUR",
            "25000000",
            "EURIBOR 3M",
            "550",
            "0",
            "99.00",
            "2026-03-15",
            "2033-03-15",
        ]
    )
    counts["facilities"] = write_csv(
        os.path.join(out_dir, "facilities.csv"),
        [
            "facility_id",
            "borrower_id",
            "fund_code",
            "instrument_type",
            "currency",
            "commitment_amount",
            "base_rate",
            "spread_bps",
            "floor_bps",
            "oid_price",
            "origination_date",
            "maturity_date",
        ],
        fac_rows,
        rng,
    )

    # ---- monthly marks + cash flows --------------------------------------
    mark_rows, cf_rows = [], []
    ledger = []  # spec 005: clean (fund, date, type, amount, ccy) of every cash flow, no RNG used
    txn = 0

    def add_cf(f, d, typ, amt, price=None):
        nonlocal txn
        txn += 1
        ledger.append((f["fund"], d, typ, amt, f["ccy"]))
        cf_rows.append(
            [
                f"T{txn:07d}",
                f["id"],
                dirt.date(d),
                dirt.category(typ),
                dirt.amount(amt),
                dirt.ccy(f["ccy"]),
                dirt.price(price, 4 if f["equity"] else 2),
            ]
        )

    def draw_price(f):
        # debt: OID +/- 0.25 per 100; equity: acquisition price per unit
        return (
            f["oid"] if f["equity"] else f["oid"] + rng.choice([-0.25, 0.0, 0.0, 0.25])
        )

    # spec 003 AC8: one facility whose acquisition cash flow is missing from the ledger
    no_draw = next(
        x["id"]
        for x in facilities
        if x["instr"] == "Senior Secured Term Loan" and not x["repaid"]
    )

    for f in facilities:
        outstanding = f["commitment"] * f["draw_share"]
        # acquisition cash flow at origination, also for facilities originated before
        # the data window (spec 003 needs it for the cost basis)
        if outstanding > 0 and f["id"] != no_draw:
            add_cf(f, f["orig"], "Drawdown", outstanding, draw_price(f))
        non_accrual = False
        for m in MONTHS:
            if f["orig"] > m:
                continue
            if f["repaid"] and m > f["repaid"]:
                break
            first = f["orig"] > add_months(m, -1)
            lev = lev_at(f["borrower"], m)
            # internal rating 1 (strong) .. 5 (impaired), driven by leverage
            rating = (
                1
                if lev < 3.5
                else 2
                if lev < 5.0
                else 3
                if lev < 6.5
                else 4
                if lev < 8.0
                else 5
            )
            if f["instr"] in ("Second Lien", "Holdco PIK Note"):
                rating = min(5, rating + (1 if lev > 6 else 0))
            non_accrual = not f["equity"] and (
                non_accrual or rating == 5 and rng.random() < 0.12
            )
            dpd = 0
            if rating >= 4:
                dpd = (
                    rng.choice([0, 0, 15, 30, 45])
                    if not non_accrual
                    else rng.choice([60, 90, 120])
                )
            price = {1: 100.25, 2: 99.75, 3: 98.25, 4: 92.0, 5: 71.0}[
                rating
            ] + rng.uniform(-0.75, 0.75)
            if non_accrual:
                price = min(price, rng.uniform(45, 65))
            if f["equity"]:  # price per unit, 1.00 = at cost
                price = {1: 1.35, 2: 1.15, 3: 1.0, 4: 0.75, 5: 0.45}[
                    rating
                ] + rng.uniform(-0.05, 0.05)
            # RCF utilisation moves around
            if f["instr"] == "Revolving Credit Facility" and not first:
                new = f["commitment"] * min(
                    1.0, max(0.0, f["draw_share"] + rng.gauss(0, 0.08))
                )
                delta = new - outstanding
                if abs(delta) > 1e5:
                    add_cf(
                        f,
                        m - dt.timedelta(days=rng.randint(1, 20)),
                        "Drawdown" if delta > 0 else "Repayment",
                        abs(delta),
                        100.0,
                    )
                    outstanding = new
            # quarterly amortisation
            if f["amort"] and m.month in (3, 6, 9, 12) and not first:
                a = f["commitment"] * f["amort"] / 4
                outstanding = max(outstanding - a, 0)
                add_cf(f, m, "Repayment", a, 100.0)
            # monthly interest (cash pay unless PIK / non-accrual)
            rate = max(base_rate_pct(f["ccy"], m), f["floor"] / 100) + f["spread"] / 100
            interest = outstanding * rate / 100 / 12
            if f["equity"]:
                pass  # no coupon on equity
            elif f["instr"] == "Holdco PIK Note":
                outstanding += interest  # capitalised
                add_cf(f, m, "PIK", interest)
            elif not non_accrual and outstanding > 0:
                add_cf(f, m, "Interest", interest)
            if (
                first
                and f["orig"] >= FIRST_MONTH - dt.timedelta(days=30)
                and not f["equity"]
            ):
                add_cf(f, f["orig"], "Fee", f["commitment"] * (100 - f["oid"]) / 100)
            mark_rows.append(
                [
                    f["id"],
                    dirt.date(m),
                    dirt.amount(outstanding),
                    f"{price:.3f}",
                    rating if not dirt.hit(0.05) else "",
                    dpd,
                    "Y" if non_accrual else "N",
                ]
            )
        if f["repaid"] and f["repaid"] <= MONTHS[-1]:
            exit_price = (
                price if f["equity"] else rng.uniform(97, 101)
            )  # prepayment / exit trade price
            add_cf(f, f["repaid"], "Repayment", outstanding, exit_price)
            if f["instr"] != "Revolving Credit Facility" and not f["equity"]:
                add_cf(f, f["repaid"], "Fee", outstanding * 0.01)  # prepayment fee

    counts["loan_marks"] = write_csv(
        os.path.join(out_dir, "loan_marks.csv"),
        [
            "facility_id",
            "as_of_date",
            "outstanding_principal",
            "fair_value_price",
            "internal_rating",
            "days_past_due",
            "non_accrual_flag",
        ],
        mark_rows,
        rng,
    )
    # spec 003 AC4: one amortisation repayment with an impossible price (> 200 per 100)
    by_id = {x["id"]: x for x in facilities}
    planted = next(
        r
        for r in cf_rows
        if r[3].strip().lower() == "repayment"
        and r[6] not in ("", "0")
        and by_id[r[1]]["instr"] == "Unitranche"
    )
    planted[6] = "250.00"
    counts["cash_flows"] = write_csv(
        os.path.join(out_dir, "cash_flows.csv"),
        [
            "transaction_id",
            "facility_id",
            "transaction_date",
            "transaction_type",
            "amount",
            "currency",
            "price",
        ],
        cf_rows,
        rng,
    )

    # ---- FX rates (month-end, units of EUR per 1 unit of currency) ---------
    fx_rows = []
    fx_map = {}  # spec 005: (month_end, ccy) -> EUR per unit, clean
    for i, m in enumerate(MONTHS):
        gbp = 1.18 + 0.03 * math.sin(i / 4) + rng.uniform(-0.01, 0.01)
        usd = 0.93 - 0.004 * i + 0.02 * math.sin(i / 3) + rng.uniform(-0.01, 0.01)
        fx_map[(m, "EUR")], fx_map[(m, "GBP")], fx_map[(m, "USD")] = (
            1.0,
            round(gbp, 6),
            round(usd, 6),
        )
        fx_rows.append([dirt.date(m), "EUR", "1.000000"])
        fx_rows.append([dirt.date(m), dirt.ccy("GBP"), f"{gbp:.6f}"])
        fx_rows.append([dirt.date(m), dirt.ccy("USD"), f"{usd:.6f}"])
    counts["fx_rates"] = write_csv(
        os.path.join(out_dir, "fx_rates.csv"),
        ["rate_date", "currency", "eur_per_unit"],
        fx_rows,
        rng,
        dup_rate=0,
    )

    # ---- fund terms and fund-level cash flows (spec 005) ---------------------
    rng5 = random.Random(seed + 5)  # own RNG: the extracts above stay byte-identical
    fund_flows, ff_next = fund_cash_flows(ledger, fx_map, rng5)
    counts["fund_terms"] = write_csv(
        os.path.join(out_dir, "fund_terms.csv"),
        [
            "fund_code",
            "mgmt_fee_pct",
            "fee_basis",
            "fee_frequency",
            "expense_pct",
            "carry_pct",
            "hurdle_pct",
            "catch_up_pct",
        ],
        [
            [
                c,
                f"{fee:.4f}",
                basis if c != "EDL-IV" else basis.lower(),
                freq,
                f"{exp:.4f}",
                f"{carry:.4f}",
                f"{hurdle:.4f}",
                f"{cu:.4f}",
            ]
            for c, fee, basis, freq, exp, carry, hurdle, cu in FUND_TERMS
        ]
        + [
            [
                "XX-9",
                "1.0000",
                "INVESTED",
                "Q",
                "0.1000",
                "10.0000",
                "6.0000",
                "100.0000",
            ]
        ],  # unknown fund
        rng5,
        dup_rate=0,
    )
    counts["fund_cash_flows"] = write_csv(
        os.path.join(out_dir, "fund_cash_flows.csv"),
        ["flow_id", "fund_code", "flow_date", "flow_type", "amount", "currency"],
        fund_flows,
        rng5,
    )

    # ---- reference (base) rates, month-end, % p.a. --------------------------
    rr_rows = []
    for m in MONTHS:
        for ccy, name in BASE_RATE.items():
            rr_rows.append([dirt.date(m), name, f"{base_rate_pct(ccy, m):.4f}"])
    counts["reference_rates"] = write_csv(
        os.path.join(out_dir, "reference_rates.csv"),
        ["rate_date", "rate_name", "rate_pct"],
        rr_rows,
        rng,
        dup_rate=0,
    )

    # ---- delta extracts for the incremental demo (data/raw/delta) ----------
    # A restated LAST month: the administrator re-sends ~15 marks with corrected
    # prices, plus a handful of late cash flows dated in that same month. Loaded
    # with sql/01_staging/11_load_delta.sql (append) and picked up by
    # CALL dbo.usp_run_etl('incremental') through the staging watermark.
    delta_dir = os.path.join(out_dir, "delta")
    os.makedirs(delta_dir, exist_ok=True)
    last = MONTHS[-1]
    last_marks = [r for r in mark_rows if dirt_free_date(r[1]) == last]
    restated = rng.sample(last_marks, 15)
    delta_marks = []
    for r in restated:
        r2 = list(r)
        r2[3] = (
            f"{float(r[3]) + rng.choice([-1.5, -0.75, 0.5, 1.0]):.3f}"  # corrected price
        )
        delta_marks.append(r2)
    counts["delta/loan_marks"] = write_csv(
        os.path.join(delta_dir, "loan_marks.csv"),
        [
            "facility_id",
            "as_of_date",
            "outstanding_principal",
            "fair_value_price",
            "internal_rating",
            "days_past_due",
            "non_accrual_flag",
        ],
        delta_marks,
        rng,
        dup_rate=0,
    )
    delta_cf = []
    for r in rng.sample(restated, 5):
        txn += 1
        f = next(x for x in facilities if x["id"] == r[0])
        delta_cf.append(
            [
                f"T{txn:07d}",
                f["id"],
                last.isoformat(),
                "Interest",
                f"{f['commitment'] * 0.004:.2f}",
                f["ccy"],
                "",
            ]
        )
    # spec 003 AC7: a late add-on Drawdown dated in the restated month
    late = next(by_id[r[0]] for r in restated if not by_id[r[0]]["equity"])
    txn += 1
    delta_cf.append(
        [
            f"T{txn:07d}",
            late["id"],
            (last - dt.timedelta(days=5)).isoformat(),
            "Drawdown",
            "2000000.00",
            late["ccy"],
            "99.00",
        ]
    )
    counts["delta/cash_flows"] = write_csv(
        os.path.join(delta_dir, "cash_flows.csv"),
        [
            "transaction_id",
            "facility_id",
            "transaction_date",
            "transaction_type",
            "amount",
            "currency",
            "price",
        ],
        delta_cf,
        rng,
        dup_rate=0,
    )

    # spec 005: one late lp_distribution per fund, dated in the restated month
    delta_ff = [
        [
            f"FF{ff_next + i:06d}",
            code,
            (last - dt.timedelta(days=2)).isoformat(),
            "lp_distribution",
            f"{amt:.2f}",
            "EUR",
        ]
        for i, (code, amt) in enumerate(
            [("EDL-III", 4_500_000), ("EDL-IV", 3_000_000), ("SCF-I", 1_500_000)]
        )
    ]
    counts["delta/fund_cash_flows"] = write_csv(
        os.path.join(delta_dir, "fund_cash_flows.csv"),
        ["flow_id", "fund_code", "flow_date", "flow_type", "amount", "currency"],
        delta_ff,
        rng5,
        dup_rate=0,
    )

    # ---- external credit ratings, effective-dated (spec 004) -----------------
    # One row per borrower x agency x validity interval. The internal committee
    # grade follows leverage (re-graded 20-45 days after each quarter end); S&P
    # (~60% of borrowers) and Moody's (~45%) follow it with a lag. valid_to is
    # exclusive and blank for the interval still in force.
    SP = {
        1: ["BBB", "BBB-"],
        2: ["BB+", "BB", "BB-"],
        3: ["B+", "B"],
        4: ["B-", "CCC+"],
        5: ["CCC", "CCC-"],
    }
    MOODY = {
        1: ["Baa2", "Baa3"],
        2: ["Ba1", "Ba2", "Ba3"],
        3: ["B1", "B2"],
        4: ["B3", "Caa1"],
        5: ["Caa2", "Caa3"],
    }
    COMMITTEE = {1: ["A"], 2: ["B"], 3: ["C"], 4: ["D"], 5: ["E"]}
    last = MONTHS[-1]

    def grade(lev):
        return (
            1
            if lev < 3.5
            else 2
            if lev < 5.0
            else 3
            if lev < 6.5
            else 4
            if lev < 8.0
            else 5
        )

    cr = []  # [borrower, agency, rating, valid_from, valid_to, updated_at] (clean dates)
    history = {}  # (borrower, agency) -> list of rows, for the delta
    for b in borrowers:
        changes = [
            (
                dt.date(2024, 6, 30) - dt.timedelta(days=rng.randint(0, 400)),
                grade(health[b["id"]][quarters[0]]),
            )
        ]
        for q in quarters[1:]:
            g = grade(health[b["id"]][q])
            vf = q + dt.timedelta(days=rng.randint(20, 45))
            if g != changes[-1][1] and vf <= last:
                changes.append((vf, g))
        agencies = [("Committee", COMMITTEE, 0)]
        if rng.random() < 0.60:
            agencies.append(("S&P", SP, rng.randint(5, 60)))
        if rng.random() < 0.45:
            agencies.append(("Moody's", MOODY, rng.randint(5, 60)))
        for agency, scale, lag in agencies:
            rows: list[list] = []
            for vf, g in changes:
                vf = min(vf + dt.timedelta(days=lag), last)
                if rows and vf <= rows[-1][3]:
                    continue
                rows.append(
                    [
                        b["id"],
                        agency,
                        rng.choice(scale[g]),
                        vf,
                        None,
                        vf + dt.timedelta(days=rng.randint(1, 5)),
                    ]
                )
            for a, nxt in itertools.pairwise(rows):
                a[4] = nxt[3]
            history[(b["id"], agency)] = rows
            cr.extend(rows)

    # planted overlaps: the earlier interval runs 20 days past the next one's start
    # (the later row is also the more recently updated one, so it wins)
    multi = [rows for rows in history.values() if len(rows) >= 2]
    overlap_rows = [rng.choice(multi)[0] for _ in range(max(1, len(borrowers) // 20))]
    for r in overlap_rows:
        if r[4] is not None:
            r[4] = r[4] + dt.timedelta(days=20)

    def cr_row(r):
        rating = r[2].lower() if rng.random() < 0.10 else r[2]  # 10% lower-case
        return [
            r[0],
            dirt.category(r[1]) if r[1] != "S&P" else r[1],
            rating,
            dirt.date(r[3]),
            dirt.date(r[4]),
            dirt.date(r[5]),
        ]

    cr_rows = [cr_row(r) for r in cr]
    cr_rows.append(
        ["B0003", "Fitch", "BB", "2025-01-15", "", "2025-01-17"]
    )  # unknown agency
    cr_rows.append(
        ["B9999", "Committee", "C", "2025-01-15", "", "2025-01-17"]
    )  # unknown borrower
    cr_rows.append(
        ["B0004", "Committee", "B", "2025-06-17", "2025-03-31", "2025-06-18"]
    )  # inverted interval
    counts["credit_ratings"] = write_csv(
        os.path.join(out_dir, "credit_ratings.csv"),
        ["borrower_id", "agency", "rating", "valid_from", "valid_to", "updated_at"],
        cr_rows,
        rng,
    )

    # delta: 6 rating actions dated inside the restated month (4 committee, 2 S&P)
    active = {by_id[r[0]]["borrower"] for r in last_marks}
    delta_cr: list[list] = []
    for agency, scale, n in [("Committee", COMMITTEE, 4), ("S&P", SP, 2)]:
        picks = [
            k
            for k, rows in history.items()
            if k[1] == agency
            and k[0] in active
            and rows[-1][3] < last - dt.timedelta(days=15)
            and k[0] not in {d[0] for d in delta_cr}
        ]
        for bid, _ in rng.sample(sorted(picks), n):
            cur = history[(bid, agency)][-1][2]
            g = next(k for k, v in scale.items() if cur in v)
            g2 = g + 1 if g < 5 else g - 1  # mostly downgrades
            delta_cr.append(
                [
                    bid,
                    agency,
                    scale[g2][0],
                    (last - dt.timedelta(days=10)).isoformat(),
                    "",
                    (last + dt.timedelta(days=3)).isoformat(),
                ]
            )
    counts["delta/credit_ratings"] = write_csv(
        os.path.join(delta_dir, "credit_ratings.csv"),
        ["borrower_id", "agency", "rating", "valid_from", "valid_to", "updated_at"],
        delta_cr,
        rng,
        dup_rate=0,
    )

    for name, n in counts.items():
        print(f"  {name:<22} {n:>7,} rows")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "..", "raw"))
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()
    print(
        f"Generating synthetic private-credit data (seed={a.seed}) -> {os.path.normpath(a.out)}"
    )
    generate(a.out, a.seed)


if __name__ == "__main__":
    main()
