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
    ("Healthcare", 15), ("Software & Technology", 18), ("Business Services", 16),
    ("Industrials", 12), ("Consumer", 8), ("Education", 6),
    ("Financial Services", 7), ("Transportation & Logistics", 7),
    ("Food & Beverage", 6), ("Telecommunications", 5),
]

NAME_A = ["Nord", "Alta", "Vero", "Lumen", "Castell", "Aurel", "Brava", "Cobalt",
          "Delta", "Ever", "Fjord", "Gran", "Helio", "Iber", "Juno", "Kestrel",
          "Lago", "Marin", "Nova", "Orion", "Pala", "Quill", "Rhea", "Solano",
          "Terra", "Ulmo", "Vanta", "Wester", "Xeno", "Zenit"]
NAME_B = ["wind", "bridge", "point", "field", "stone", "gate", "crest", "vale",
          "line", "mark", "path", "core", "haven", "works", "spring", "light"]
NAME_C = {
    "Healthcare": ["Clinics", "Pharma", "Dental Group", "Diagnostics", "Care"],
    "Software & Technology": ["Software", "Systems", "Analytics", "Cloud", "Digital"],
    "Business Services": ["Consulting", "Services", "Outsourcing", "Partners"],
    "Industrials": ["Engineering", "Manufacturing", "Components", "Industries"],
    "Consumer": ["Brands", "Retail", "Leisure", "Living"],
    "Education": ["Learning", "Academy", "Education", "Schools"],
    "Financial Services": ["Payments", "Insurance Services", "Finance", "Capital Services"],
    "Transportation & Logistics": ["Logistics", "Freight", "Transport", "Mobility"],
    "Food & Beverage": ["Foods", "Beverages", "Bakeries", "Ingredients"],
    "Telecommunications": ["Telecom", "Networks", "Fibre", "Connect"],
}
SPONSORS = ["Arden Equity Partners", "Blackmoor Capital", "Calder & Co Private Equity",
            "Dunmore Investors", "Elmstead Partners", "Foxley Capital",
            "Greyhaven Equity", "Hartwell Partners", "Ivyridge Capital",
            "Juniper Lane Equity", "Kingsmere Partners", "Larchfield Capital",
            None]  # None = sponsorless

FUNDS = [
    # code, name, vintage, strategy, size EUR
    ("EDL-III", "European Direct Lending Fund III", 2021, "Senior Direct Lending", 3_500_000_000),
    ("EDL-IV", "European Direct Lending Fund IV", 2024, "Senior Direct Lending", 5_000_000_000),
    ("SCF-I", "Strategic Credit Fund I", 2022, "Opportunistic / Junior Credit", 1_500_000_000),
]

INSTRUMENTS = [
    # name, weight, spread range bps, typical share of commitment drawn
    ("Unitranche", 40, (500, 675)),
    ("Senior Secured Term Loan", 30, (425, 575)),
    ("Revolving Credit Facility", 12, (350, 450)),
    ("Second Lien", 10, (725, 900)),
    ("Holdco PIK Note", 8, (900, 1150)),
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
    return rng.choices(items, weights=[i[-1] if isinstance(i[-1], (int, float)) else i[1] for i in items])[0]


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


def dirt_free_date(v: str) -> dt.date | None:
    """Parse the three dirty date formats the generator emits (YYYY-MM-DD, DD/MM/YYYY, YYYYMMDD)."""
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y%m%d"):
        try:
            return dt.datetime.strptime(v, fmt).date()
        except ValueError:
            pass
    return None


def write_csv(path: str, header: list[str], rows: list[list], rng: random.Random, dup_rate=0.015):
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
    counts["funds"] = write_csv(os.path.join(out_dir, "funds.csv"),
                                ["fund_code", "fund_name", "vintage_year", "strategy",
                                 "fund_size_eur", "base_currency"], fund_rows, rng, dup_rate=0)

    # ---- borrowers -----------------------------------------------------
    borrowers = []
    used = set()
    for i in range(1, 141):
        iso2 = weighted(rng, COUNTRIES)[0]
        sector = weighted(rng, SECTORS)[0]
        while True:
            name = f"{rng.choice(NAME_A)}{rng.choice(NAME_B)} {rng.choice(NAME_C[sector])}"
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
        b_rows.append([
            b["id"], b["name"], dirt.category(b["sector"]), dirt.country(b["country"]),
            b["sponsor"] or "", dt.date(rng.randint(1975, 2016), 1, 1).year,
        ])
    counts["borrowers"] = write_csv(os.path.join(out_dir, "borrowers.csv"),
                                    ["borrower_id", "borrower_name", "sector", "country",
                                     "pe_sponsor", "founded_year"], b_rows, rng)

    # ---- borrower financials (quarterly, LTM) -----------------------------
    # Quarter ends from Q4-2024 .. Q3-2026 (8 quarters)
    quarters = [month_end(y, m) for y, m in
                [(2024, 12), (2025, 3), (2025, 6), (2025, 9), (2025, 12), (2026, 3), (2026, 6), (2026, 9)]]
    fin_rows = []
    health = {}  # borrower -> {quarter_end: leverage}
    for b in borrowers:
        ebitda = b["ebitda0"]
        debt = b["ebitda0"] * b["lev0"]
        health[b["id"]] = {}
        stressed = rng.random() < 0.08  # ~8% of the book deteriorates
        for qi, q in enumerate(quarters):
            shock = rng.gauss(b["drift"] - (0.07 if stressed and qi >= 3 else 0), b["vol"])
            ebitda = max(ebitda * (1 + shock), b["ebitda0"] * 0.15)
            debt = debt * (1 + rng.gauss(-0.005, 0.01))  # light amortisation / add-ons
            cash = debt * b["cash_ratio"] * rng.uniform(0.7, 1.3)
            revenue = ebitda / b["margin"]
            int_exp = debt * rng.uniform(0.075, 0.105)
            health[b["id"]][q] = (debt - cash) / ebitda
            fin_rows.append([
                b["id"], dirt.date(q), dirt.amount(revenue, 0), dirt.amount(ebitda, 0),
                dirt.amount(debt, 0), dirt.amount(cash, 0), dirt.amount(int_exp, 0), "EUR",
            ])
    # a couple of rows with missing EBITDA (late reporting)
    for r in rng.sample(fin_rows, 6):
        r[3] = ""
    counts["borrower_financials"] = write_csv(
        os.path.join(out_dir, "borrower_financials.csv"),
        ["borrower_id", "period_end_date", "revenue_ltm", "ebitda_ltm", "total_debt",
         "cash_and_equivalents", "interest_expense_ltm", "reporting_currency"], fin_rows, rng)

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
        fund = ("EDL-III" if orig.year < 2024 else "EDL-IV")
        if rng.random() < 0.18:
            fund = "SCF-I"
        used_instr = set()
        for k in range(n_fac):
            fid += 1
            choices = [i for i in INSTRUMENTS if i[0] not in used_instr]
            if fund == "SCF-I":
                choices = [i for i in choices if i[0] in ("Second Lien", "Holdco PIK Note", "Unitranche")] or choices
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
            facilities.append({
                "id": f"F{fid:05d}", "borrower": b["id"], "fund": fund, "instr": instr,
                "ccy": ccy, "commitment": commitment,
                "spread": rng.randrange(lo, hi + 1, 25),
                "floor": rng.choice([0, 0, 50, 75, 100]),
                "oid": rng.choice([97.5, 98.0, 98.5, 99.0, 99.5]),
                "orig": o, "mat": mat, "repaid": repaid,
                "draw_share": rng.uniform(0.0, 0.6) if instr == "Revolving Credit Facility" else 1.0,
                "amort": 0.01 if instr in ("Senior Secured Term Loan", "Unitranche") else 0.0,
            })

    fac_rows = []
    for f in facilities:
        fac_rows.append([
            f["id"], f["borrower"], f["fund"], dirt.category(f["instr"]), dirt.ccy(f["ccy"]),
            dirt.amount(f["commitment"]), BASE_RATE[f["ccy"]], f["spread"], f["floor"],
            f"{f['oid']:.2f}", dirt.date(f["orig"]), dirt.date(f["mat"]),
        ])
    # unparseable rows that the silver layer must reject
    fac_rows.append(["F99901", "B0001", "EDL-IV", "Unitranche", "EUR", "TBC", "EURIBOR 3M",
                     "550", "0", "99.00", "2026-02-30", "2033-02-28"])
    fac_rows.append(["F99902", "B9999", "EDL-IV", "Unitranche", "EUR", "25000000", "EURIBOR 3M",
                     "550", "0", "99.00", "2026-03-15", "2033-03-15"])
    counts["facilities"] = write_csv(
        os.path.join(out_dir, "facilities.csv"),
        ["facility_id", "borrower_id", "fund_code", "instrument_type", "currency",
         "commitment_amount", "base_rate", "spread_bps", "floor_bps", "oid_price",
         "origination_date", "maturity_date"], fac_rows, rng)

    # ---- monthly marks + cash flows --------------------------------------
    mark_rows, cf_rows = [], []
    txn = 0

    def add_cf(f, d, typ, amt):
        nonlocal txn
        txn += 1
        cf_rows.append([f"T{txn:07d}", f["id"], dirt.date(d), dirt.category(typ),
                        dirt.amount(amt), dirt.ccy(f["ccy"])])

    for f in facilities:
        outstanding = f["commitment"] * f["draw_share"]
        if f["orig"] >= FIRST_MONTH:
            pass  # drawdown appears in the window
        non_accrual = False
        for m in MONTHS:
            if f["orig"] > m:
                continue
            if f["repaid"] and m > f["repaid"]:
                break
            first = f["orig"] > add_months(m, -1)
            if first and f["orig"] >= FIRST_MONTH - dt.timedelta(days=30):
                add_cf(f, f["orig"], "Drawdown", outstanding)
            lev = lev_at(f["borrower"], m)
            # internal rating 1 (strong) .. 5 (impaired), driven by leverage
            rating = 1 if lev < 3.5 else 2 if lev < 5.0 else 3 if lev < 6.5 else 4 if lev < 8.0 else 5
            if f["instr"] in ("Second Lien", "Holdco PIK Note"):
                rating = min(5, rating + (1 if lev > 6 else 0))
            non_accrual = non_accrual or rating == 5 and rng.random() < 0.12
            dpd = 0
            if rating >= 4:
                dpd = rng.choice([0, 0, 15, 30, 45]) if not non_accrual else rng.choice([60, 90, 120])
            price = {1: 100.25, 2: 99.75, 3: 98.25, 4: 92.0, 5: 71.0}[rating] + rng.uniform(-0.75, 0.75)
            if non_accrual:
                price = min(price, rng.uniform(45, 65))
            # RCF utilisation moves around
            if f["instr"] == "Revolving Credit Facility" and not first:
                new = f["commitment"] * min(1.0, max(0.0, f["draw_share"] + rng.gauss(0, 0.08)))
                delta = new - outstanding
                if abs(delta) > 1e5:
                    add_cf(f, m - dt.timedelta(days=rng.randint(1, 20)),
                           "Drawdown" if delta > 0 else "Repayment", abs(delta))
                    outstanding = new
            # quarterly amortisation
            if f["amort"] and m.month in (3, 6, 9, 12) and not first:
                a = f["commitment"] * f["amort"] / 4
                outstanding = max(outstanding - a, 0)
                add_cf(f, m, "Repayment", a)
            # monthly interest (cash pay unless PIK / non-accrual)
            rate = max(base_rate_pct(f["ccy"], m), f["floor"] / 100) + f["spread"] / 100
            interest = outstanding * rate / 100 / 12
            if f["instr"] == "Holdco PIK Note":
                outstanding += interest  # capitalised
            elif not non_accrual and outstanding > 0:
                add_cf(f, m, "Interest", interest)
            if first and f["orig"] >= FIRST_MONTH - dt.timedelta(days=30):
                add_cf(f, f["orig"], "Fee", f["commitment"] * (100 - f["oid"]) / 100)
            mark_rows.append([
                f["id"], dirt.date(m), dirt.amount(outstanding), f"{price:.3f}",
                rating if not dirt.hit(0.05) else "", dpd, "Y" if non_accrual else "N",
            ])
        if f["repaid"] and f["repaid"] <= MONTHS[-1]:
            add_cf(f, f["repaid"], "Repayment", outstanding)
            if f["instr"] != "Revolving Credit Facility":
                add_cf(f, f["repaid"], "Fee", outstanding * 0.01)  # prepayment fee

    counts["loan_marks"] = write_csv(
        os.path.join(out_dir, "loan_marks.csv"),
        ["facility_id", "as_of_date", "outstanding_principal", "fair_value_price",
         "internal_rating", "days_past_due", "non_accrual_flag"], mark_rows, rng)
    counts["cash_flows"] = write_csv(
        os.path.join(out_dir, "cash_flows.csv"),
        ["transaction_id", "facility_id", "transaction_date", "transaction_type",
         "amount", "currency"], cf_rows, rng)

    # ---- FX rates (month-end, units of EUR per 1 unit of currency) ---------
    fx_rows = []
    for i, m in enumerate(MONTHS):
        gbp = 1.18 + 0.03 * math.sin(i / 4) + rng.uniform(-0.01, 0.01)
        usd = 0.93 - 0.004 * i + 0.02 * math.sin(i / 3) + rng.uniform(-0.01, 0.01)
        fx_rows.append([dirt.date(m), "EUR", "1.000000"])
        fx_rows.append([dirt.date(m), dirt.ccy("GBP"), f"{gbp:.6f}"])
        fx_rows.append([dirt.date(m), dirt.ccy("USD"), f"{usd:.6f}"])
    counts["fx_rates"] = write_csv(os.path.join(out_dir, "fx_rates.csv"),
                                   ["rate_date", "currency", "eur_per_unit"], fx_rows, rng, dup_rate=0)

    # ---- reference (base) rates, month-end, % p.a. --------------------------
    rr_rows = []
    for m in MONTHS:
        for ccy, name in BASE_RATE.items():
            rr_rows.append([dirt.date(m), name, f"{base_rate_pct(ccy, m):.4f}"])
    counts["reference_rates"] = write_csv(os.path.join(out_dir, "reference_rates.csv"),
                                          ["rate_date", "rate_name", "rate_pct"], rr_rows, rng, dup_rate=0)

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
        r2[3] = f"{float(r[3]) + rng.choice([-1.5, -0.75, 0.5, 1.0]):.3f}"   # corrected price
        delta_marks.append(r2)
    counts["delta/loan_marks"] = write_csv(
        os.path.join(delta_dir, "loan_marks.csv"),
        ["facility_id", "as_of_date", "outstanding_principal", "fair_value_price",
         "internal_rating", "days_past_due", "non_accrual_flag"], delta_marks, rng, dup_rate=0)
    delta_cf = []
    for r in rng.sample(restated, 5):
        txn += 1
        f = next(x for x in facilities if x["id"] == r[0])
        delta_cf.append([f"T{txn:07d}", f["id"], last.isoformat(), "Interest",
                         f"{f['commitment'] * 0.004:.2f}", f["ccy"]])
    counts["delta/cash_flows"] = write_csv(
        os.path.join(delta_dir, "cash_flows.csv"),
        ["transaction_id", "facility_id", "transaction_date", "transaction_type",
         "amount", "currency"], delta_cf, rng, dup_rate=0)

    for k, v in counts.items():
        print(f"  {k:<22} {v:>7,} rows")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "..", "raw"))
    ap.add_argument("--seed", type=int, default=42)
    a = ap.parse_args()
    print(f"Generating synthetic private-credit data (seed={a.seed}) -> {os.path.normpath(a.out)}")
    generate(a.out, a.seed)


if __name__ == "__main__":
    main()
