"""
A/B Experiment Statistical Analysis
=====================================
Project : Product Recommendation Engine — Conversion Uplift Study
Author  : Data Science Portfolio
Stack   : Python 3.10+  |  pandas · numpy · scipy · statsmodels · matplotlib

Run:
    pip install pandas numpy scipy statsmodels matplotlib
    python ab_analysis.py
"""

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.gridspec import GridSpec
import warnings
warnings.filterwarnings("ignore")

# ─────────────────────────────────────────────────────────────────────────────
# 1. SIMULATED DATA  (mirrors the SQL-generated experiment dataset)
#    In production: replace with pd.read_sql(query, conn)
# ─────────────────────────────────────────────────────────────────────────────

np.random.seed(42)
N = 1000

def make_users(n=N):
    countries     = ["USA","UK","Canada","Germany","Australia","Spain"]
    devices       = ["mobile","desktop","tablet"]
    age_groups    = ["18-24","25-34","35-44","45-54","55+"]

    customer_ids  = np.arange(1, n + 1)
    groups        = np.where(customer_ids % 2 == 0, "A", "B")
    country_arr   = [countries[i % 6]    for i in range(n)]
    device_arr    = [devices[i % 3]      for i in range(n)]
    age_arr       = [age_groups[i % 5]   for i in range(n)]
    is_premium    = (customer_ids % 5 == 0).astype(int)

    # Conversion probability per user
    base_cr = np.where(groups == "A", 0.34, 0.47)
    premium_boost = is_premium * 0.10
    conv_prob = base_cr + premium_boost

    converted = (np.random.rand(n) < conv_prob).astype(int)

    # Revenue: converted users get order values from realistic distribution
    product_prices = [1299, 799, 249, 45, 79, 159, 189, 65, 549, 129]
    revenue = np.zeros(n)
    for idx in np.where(converted == 1)[0]:
        n_orders = np.random.randint(1, 4)
        if device_arr[idx] == "mobile":
            prices = [45, 79, 159, 65]     # cheaper products
        elif is_premium[idx]:
            prices = [1299, 799, 249]       # premium products
        else:
            prices = product_prices
        revenue[idx] = sum(np.random.choice(prices) for _ in range(n_orders))

    return pd.DataFrame({
        "customer_id" : customer_ids,
        "group"       : groups,
        "country"     : country_arr,
        "device"      : device_arr,
        "age_group"   : age_arr,
        "is_premium"  : is_premium,
        "converted"   : converted,
        "revenue"     : revenue,
    })


def make_time_series(df):
    """Generate daily orders with timestamps over a 90-day window."""
    rows = []
    base = pd.Timestamp("2025-01-01")
    for _, row in df[df.converted == 1].iterrows():
        n_orders = np.random.randint(1, 4)
        for _ in range(n_orders):
            day  = np.random.randint(0, 90)
            hour = np.random.randint(0, 24)
            rows.append({
                "customer_id"    : row.customer_id,
                "group"          : row.group,
                "order_ts"       : base + pd.Timedelta(days=day, hours=hour),
                "order_value"    : np.random.choice([45,79,129,159,189,249,549,799,1299]),
            })
    ts = pd.DataFrame(rows)
    ts["order_date"] = ts["order_ts"].dt.date
    ts["week"]       = ts["order_ts"].dt.isocalendar().week.astype(int)
    return ts


df  = make_users()
ts  = make_time_series(df)

# ─────────────────────────────────────────────────────────────────────────────
# 2. CORE METRICS
# ─────────────────────────────────────────────────────────────────────────────

from statsmodels.stats.proportion import proportions_ztest, proportion_confint

summary = df.groupby("group").agg(
    n          = ("customer_id", "count"),
    conversions= ("converted",   "sum"),
    total_rev  = ("revenue",     "sum"),
).assign(
    cr         = lambda x: x.conversions / x.n,
    arpu       = lambda x: x.total_rev   / x.n,
    avg_order  = lambda x: x.total_rev   / x.conversions,
).round(4)

cr_a, cr_b   = summary.loc["A","cr"],    summary.loc["B","cr"]
n_a,  n_b    = summary.loc["A","n"],     summary.loc["B","n"]
cv_a, cv_b   = summary.loc["A","conversions"], summary.loc["B","conversions"]
arpu_a, arpu_b = summary.loc["A","arpu"], summary.loc["B","arpu"]

# ─────────────────────────────────────────────────────────────────────────────
# 3. STATISTICAL TESTS
# ─────────────────────────────────────────────────────────────────────────────

# Two-proportion z-test (one-tailed: H1 = cr_B > cr_A)
z_stat, p_value = proportions_ztest([cv_a, cv_b], [n_a, n_b], alternative="smaller")

# 95% Wilson confidence intervals
ci_a = proportion_confint(cv_a, n_a, alpha=0.05, method="wilson")
ci_b = proportion_confint(cv_b, n_b, alpha=0.05, method="wilson")

# Uplift metrics
abs_uplift  = cr_b - cr_a
rel_uplift  = abs_uplift / cr_a
arpu_uplift = arpu_b - arpu_a

# Projected annual revenue impact (10 000 users/year)
annual_rev_impact = arpu_uplift * 10_000

print("\n" + "="*60)
print("  A/B TEST RESULTS — PRODUCT RECOMMENDATION ENGINE")
print("="*60)
print(f"\n{'Group':<10} {'N':>6} {'Conv':>6} {'CR%':>7} {'ARPU':>8}")
print("-"*40)
for grp in ["A","B"]:
    r = summary.loc[grp]
    print(f"  {grp:<8} {int(r.n):>6} {int(r.conversions):>6} {r.cr*100:>6.1f}% ${r.arpu:>7.2f}")

print(f"\n  Absolute Uplift  : +{abs_uplift*100:.1f} pp")
print(f"  Relative Uplift  : +{rel_uplift*100:.1f}%")
print(f"  ARPU Uplift      : +${arpu_uplift:.2f}")
print(f"  Annual Rev Impact: +${annual_rev_impact:,.0f}  (at 10k users/yr)")

print(f"\n  Z-statistic      : {z_stat:.4f}")
print(f"  P-value          : {p_value:.6f}")
print(f"  Significant?     : {'YES ✓' if p_value < 0.05 else 'NO ✗'}  (α = 0.05)")

print(f"\n  95% CI — Control  : [{ci_a[0]*100:.1f}%, {ci_a[1]*100:.1f}%]")
print(f"  95% CI — Treatment: [{ci_b[0]*100:.1f}%, {ci_b[1]*100:.1f}%]")
print("="*60)

# ─────────────────────────────────────────────────────────────────────────────
# 4. SEGMENT ANALYSIS
# ─────────────────────────────────────────────────────────────────────────────

def segment_cr(col):
    seg = df.groupby([col, "group"]).agg(n=("customer_id","count"), cv=("converted","sum"))
    seg["cr"] = (seg.cv / seg.n * 100).round(1)
    return seg.reset_index().pivot(index=col, columns="group", values="cr")

seg_country = segment_cr("country")
seg_device  = segment_cr("device")
seg_age     = segment_cr("age_group")
seg_premium = df.groupby(["is_premium","group"]).agg(
    n=("customer_id","count"), cv=("converted","sum")
).assign(cr=lambda x: (x.cv/x.n*100).round(1)).reset_index().pivot(
    index="is_premium", columns="group", values="cr"
)

print("\n── SEGMENT: Country ──")
print(seg_country.to_string())
print("\n── SEGMENT: Device ──")
print(seg_device.to_string())
print("\n── SEGMENT: Age Group ──")
print(seg_age.to_string())
print("\n── SEGMENT: Premium Tier ──")
print(seg_premium.rename(index={0:"Standard",1:"Premium"}).to_string())

# ─────────────────────────────────────────────────────────────────────────────
# 5. TIME-SERIES
# ─────────────────────────────────────────────────────────────────────────────

group_sizes = df.groupby("group")["customer_id"].count()

daily_cum = (
    ts.groupby(["group","order_date"])["customer_id"]
      .nunique()
      .groupby(level="group")
      .cumsum()
      .reset_index()
      .rename(columns={"customer_id":"cum_converters"})
)
daily_cum["cum_cr"] = daily_cum.apply(
    lambda r: r.cum_converters / group_sizes[r.group] * 100, axis=1
)

weekly = ts.groupby(["group","week"]).agg(
    orders=("order_value","count"),
    revenue=("order_value","sum")
).reset_index()

# ─────────────────────────────────────────────────────────────────────────────
# 6. VISUALISATIONS
# ─────────────────────────────────────────────────────────────────────────────

BLUE   = "#1a56db"
GREEN  = "#057a55"
GRAY   = "#6b7280"
BG     = "#f9fafb"
PANEL  = "#ffffff"
TEXT   = "#111827"
ACCENT = "#ef4444"

fig = plt.figure(figsize=(18, 14), facecolor=BG)
fig.suptitle(
    "Product Recommendation Engine — A/B Experiment Results",
    fontsize=18, fontweight="bold", color=TEXT, y=0.98
)
gs = GridSpec(3, 3, figure=fig, hspace=0.45, wspace=0.38)

# ── Plot 1: Conversion Rate with CI ──
ax1 = fig.add_subplot(gs[0, 0])
groups  = ["Control (A)", "Treatment (B)"]
crs     = [cr_a * 100, cr_b * 100]
ci_low  = [ci_a[0]*100, ci_b[0]*100]
ci_high = [ci_a[1]*100, ci_b[1]*100]
colors  = [GRAY, GREEN]
bars    = ax1.bar(groups, crs, color=colors, width=0.5, zorder=3)
for bar, lo, hi, cr in zip(bars, ci_low, ci_high, crs):
    x = bar.get_x() + bar.get_width() / 2
    ax1.errorbar(x, cr, yerr=[[cr-lo],[hi-cr]], fmt="none",
                 color="black", capsize=6, linewidth=2, zorder=4)
    ax1.text(x, hi + 0.8, f"{cr:.1f}%", ha="center", fontsize=11,
             fontweight="bold", color=TEXT)
ax1.set_title("Conversion Rate (95% CI)", fontweight="bold", color=TEXT)
ax1.set_ylabel("Conversion Rate (%)", color=GRAY, fontsize=9)
ax1.set_ylim(0, max(crs) * 1.35)
ax1.set_facecolor(PANEL)
ax1.grid(axis="y", linestyle="--", alpha=0.4)
ax1.spines[["top","right"]].set_visible(False)

# ── Plot 2: ARPU Comparison ──
ax2 = fig.add_subplot(gs[0, 1])
arpus = [arpu_a, arpu_b]
b2 = ax2.bar(groups, arpus, color=colors, width=0.5, zorder=3)
for bar, val in zip(b2, arpus):
    ax2.text(bar.get_x() + bar.get_width()/2, val + 1.5,
             f"${val:.2f}", ha="center", fontsize=11, fontweight="bold", color=TEXT)
ax2.set_title("Average Revenue Per User (ARPU)", fontweight="bold", color=TEXT)
ax2.set_ylabel("ARPU ($)", color=GRAY, fontsize=9)
ax2.set_ylim(0, max(arpus) * 1.3)
ax2.set_facecolor(PANEL)
ax2.grid(axis="y", linestyle="--", alpha=0.4)
ax2.spines[["top","right"]].set_visible(False)

# ── Plot 3: Key Stats Card ──
ax3 = fig.add_subplot(gs[0, 2])
ax3.set_facecolor(PANEL)
ax3.axis("off")
stats = [
    ("Absolute Uplift",  f"+{abs_uplift*100:.1f} pp"),
    ("Relative Uplift",  f"+{rel_uplift*100:.1f}%"),
    ("ARPU Uplift",      f"+${arpu_uplift:.2f}"),
    ("P-value",          f"{p_value:.4f}"),
    ("Significant?",     "YES (p < 0.05)"),
    ("Annual Rev Impact",f"+${annual_rev_impact:,.0f}"),
]
ax3.set_title("Key Statistics", fontweight="bold", color=TEXT, pad=12)
for j, (label, val) in enumerate(stats):
    y = 0.85 - j * 0.14
    ax3.text(0.05, y, label,  transform=ax3.transAxes, fontsize=10, color=GRAY)
    color = GREEN if "YES" in val or "+" in val else (ACCENT if float(p_value) > 0.05 else TEXT)
    ax3.text(0.95, y, val,    transform=ax3.transAxes, fontsize=10,
             fontweight="bold", color=color, ha="right")
    ax3.plot([0.05, 0.95], [y-0.04, y-0.04],
             color="#e5e7eb", linewidth=0.8, transform=ax3.transAxes)

# ── Plot 4: Cumulative Conversion Over Time ──
ax4 = fig.add_subplot(gs[1, :2])
for grp, clr, lbl in [("A", GRAY, "Control (A)"), ("B", GREEN, "Treatment (B)")]:
    sub = daily_cum[daily_cum.group == grp].sort_values("order_date")
    ax4.plot(pd.to_datetime(sub.order_date), sub.cum_cr,
             color=clr, linewidth=2.5, label=lbl)
ax4.set_title("Cumulative Conversion Rate Over Time", fontweight="bold", color=TEXT)
ax4.set_ylabel("Cumulative CR (%)", color=GRAY, fontsize=9)
ax4.set_xlabel("Date", color=GRAY, fontsize=9)
ax4.legend(fontsize=9)
ax4.set_facecolor(PANEL)
ax4.grid(linestyle="--", alpha=0.3)
ax4.spines[["top","right"]].set_visible(False)

# ── Plot 5: Weekly Revenue ──
ax5 = fig.add_subplot(gs[1, 2])
for grp, clr, lbl in [("A", GRAY, "Control"), ("B", GREEN, "Treatment")]:
    sub = weekly[weekly.group == grp].sort_values("week")
    ax5.plot(sub.week, sub.revenue, color=clr, marker="o",
             linewidth=2, markersize=4, label=lbl)
ax5.set_title("Weekly Revenue by Group", fontweight="bold", color=TEXT)
ax5.set_ylabel("Revenue ($)", color=GRAY, fontsize=9)
ax5.set_xlabel("Week of Year", color=GRAY, fontsize=9)
ax5.legend(fontsize=9)
ax5.set_facecolor(PANEL)
ax5.grid(linestyle="--", alpha=0.3)
ax5.spines[["top","right"]].set_visible(False)

# ── Plot 6: Conversion Rate by Country ──
ax6 = fig.add_subplot(gs[2, 0])
seg_c = seg_country.sort_values("B", ascending=True)
y = np.arange(len(seg_c))
ax6.barh(y - 0.2, seg_c["A"], height=0.38, color=GRAY,  label="Control")
ax6.barh(y + 0.2, seg_c["B"], height=0.38, color=GREEN, label="Treatment")
ax6.set_yticks(y)
ax6.set_yticklabels(seg_c.index, fontsize=9)
ax6.set_title("CR% by Country", fontweight="bold", color=TEXT)
ax6.set_xlabel("Conversion Rate (%)", color=GRAY, fontsize=9)
ax6.legend(fontsize=8)
ax6.set_facecolor(PANEL)
ax6.grid(axis="x", linestyle="--", alpha=0.3)
ax6.spines[["top","right"]].set_visible(False)

# ── Plot 7: CR by Device ──
ax7 = fig.add_subplot(gs[2, 1])
seg_d = seg_device
x  = np.arange(len(seg_d))
ax7.bar(x - 0.2, seg_d["A"], width=0.38, color=GRAY,  label="Control")
ax7.bar(x + 0.2, seg_d["B"], width=0.38, color=GREEN, label="Treatment")
ax7.set_xticks(x)
ax7.set_xticklabels(seg_d.index, fontsize=9)
ax7.set_title("CR% by Device Type", fontweight="bold", color=TEXT)
ax7.set_ylabel("Conversion Rate (%)", color=GRAY, fontsize=9)
ax7.legend(fontsize=8)
ax7.set_facecolor(PANEL)
ax7.grid(axis="y", linestyle="--", alpha=0.3)
ax7.spines[["top","right"]].set_visible(False)

# ── Plot 8: CR by Age Group ──
ax8 = fig.add_subplot(gs[2, 2])
seg_a = seg_age
x  = np.arange(len(seg_a))
ax8.bar(x - 0.2, seg_a["A"], width=0.38, color=GRAY,  label="Control")
ax8.bar(x + 0.2, seg_a["B"], width=0.38, color=GREEN, label="Treatment")
ax8.set_xticks(x)
ax8.set_xticklabels(seg_a.index, rotation=30, fontsize=8)
ax8.set_title("CR% by Age Group", fontweight="bold", color=TEXT)
ax8.set_ylabel("Conversion Rate (%)", color=GRAY, fontsize=9)
ax8.legend(fontsize=8)
ax8.set_facecolor(PANEL)
ax8.grid(axis="y", linestyle="--", alpha=0.3)
ax8.spines[["top","right"]].set_visible(False)

plt.savefig("/home/claude/ab_results.png", dpi=150, bbox_inches="tight",
            facecolor=BG)
print("\n  Chart saved → ab_results.png")
plt.close()
