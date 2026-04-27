# 🛒 Product Recommendation Engine — A/B Experiment Analysis

> **Did adding a recommendation engine increase conversions?**  
> A full experiment lifecycle: schema design → data simulation → SQL analysis → statistical testing → business decision.

---

## Results Summary

| Metric | Control (A) | Treatment (B) | Δ |
|---|---|---|---|
| Conversion Rate | 32.6% | 52.4% | **+19.8 pp** |
| ARPU | $232 | $363 | **+$130** |
| Confidence Interval | [28.6%, 36.8%] | [48.0%, 56.7%] | No overlap |
| P-value | — | — | **< 0.0001** ✅ |

**Decision: Roll out the recommendation engine.** The result is statistically significant (z = −6.33, p < 0.0001) and consistent across all countries, devices, and age segments.

---

## Project Structure

```
├── ab_experiment.sql   # Schema, data generation, all analytical queries
├── ab_analysis.py      # Statistical testing + visualisations (Python)
└── README.md
```

---

## Experiment Design

**Hypothesis:** Exposing users to a product recommendation engine increases purchase conversion rate.

- **Unit of randomisation:** Customer (user-level, not session-level)
- **Assignment:** 50/50 random split — Group A (control) vs Group B (treatment)
- **Experiment window:** 2025-01-01 to 2025-03-31 (90 days)
- **Sample size:** 1,000 users (500 per group)
- **Primary metric:** Conversion rate (≥1 order placed during window)
- **Secondary metric:** Average Revenue Per User (ARPU)

---

## Schema

```sql
customers            -- profile: country, device_type, age_group, is_premium
products             -- catalogue with categories
orders               -- fact table with order_ts timestamps
experiment_assignment -- customer → group mapping with audit trail
user_events          -- click-stream: page_view, rec_click, add_to_cart, checkout
```

Key design choices:
- `order_ts DATETIME` enables hour-of-day and weekly trend analysis
- `is_premium TINYINT` allows tier-based segment splits
- `device_type` captures mobile vs desktop behaviour differences
- Foreign keys + indexes on all join columns for query performance

---

## SQL Analysis

The `.sql` file covers the full analytical workflow:

1. **Data generation** — Stored procedure creating 1,000 users with realistic conversion probabilities (premium users +10 pp boost, mobile users skew to lower-price products)
2. **Conversion view** — `customer_conversion`: per-user 0/1 flag + revenue within experiment window
3. **Core metrics** — conversion rate, ARPU, avg order value per group
4. **Uplift analysis** — absolute uplift, relative uplift, projected annual revenue impact
5. **Statistical prep** — aggregated output ready to pipe into Python
6. **Segment analysis** — country × group, device × group, age group, premium tier
7. **Time-series** — weekly trends, cumulative CR over time, hour-of-day distribution
8. **Data quality** — duplicate assignment check, group balance check, null profile filter

---

## Statistical Testing (Python)

```python
from statsmodels.stats.proportion import proportions_ztest, proportion_confint

n    = [500, 500]   # sample sizes
conv = [163, 262]   # conversions

z_stat, p_value = proportions_ztest(conv, n, alternative="smaller")
ci_a = proportion_confint(conv[0], n[0], alpha=0.05, method="wilson")
ci_b = proportion_confint(conv[1], n[1], alpha=0.05, method="wilson")

# Z = -6.3330  |  p = 0.000000
# Control CI:   [28.6%, 36.8%]
# Treatment CI: [48.0%, 56.7%]
```

**Test:** Two-proportion z-test, one-tailed (H₁: CR_B > CR_A), α = 0.05  
**Result:** p < 0.0001 — reject null hypothesis. The confidence intervals do not overlap.

---

## Segment Findings

**By device:**
| Device | Control CR | Treatment CR | Uplift |
|---|---|---|---|
| Desktop | 29.9% | 57.2% | +27.3 pp |
| Mobile | 32.9% | 48.5% | +15.6 pp |
| Tablet | 34.9% | 51.5% | +16.6 pp |

Desktop users showed the largest lift — likely because the recommendation UI is richer on larger screens.

**By user tier:**
| Tier | Control CR | Treatment CR | Uplift |
|---|---|---|---|
| Standard | 29.0% | 50.2% | +21.2 pp |
| Premium | 47.0% | 61.0% | +14.0 pp |

Premium users already had a higher baseline conversion; the recommendation engine still added meaningful uplift.

**No novelty effect detected** — conversion rates were stable across all 13 weeks of the experiment rather than spiking only in week 1.

---

## How to Run

**SQL** — run in MySQL 8.0+ (requires CTE and window function support):
```bash
mysql -u root -p < ab_experiment.sql
```

**Python**:
```bash
pip install pandas numpy scipy statsmodels matplotlib
python ab_analysis.py
```

Outputs: console summary table + `ab_results.png` with 8 analysis charts.

---

## Business Conclusion

The recommendation engine is a clear win on every dimension:

- **Statistical confidence** — p < 0.0001 with non-overlapping 95% CIs leaves no ambiguity
- **Practical significance** — +19.8 pp absolute uplift is large by e-commerce standards (industry average for recommendation lift is typically 5–15 pp)
- **Revenue impact** — +$130 ARPU projects to **+$1.3M additional annual revenue** at 10,000 users/year
- **Generalisability** — consistent positive effect across all 6 countries, 3 device types, 5 age groups, and both user tiers

**Recommended actions:**
1. **Immediately:** Full rollout to 100% of users
2. **30 days post-launch:** Monitor weekly CR to confirm effect holds outside experiment conditions
3. **Next experiment:** Test personalisation depth — collaborative filtering vs. content-based — focused on desktop users where the largest uplift was observed

---

## Tech Stack

- **MySQL 8.0** — schema design, stored procedures, CTEs, window functions
- **Python 3.10+** — pandas, numpy, statsmodels, matplotlib
- **Statistics** — two-proportion z-test, Wilson confidence intervals

---

*Portfolio project demonstrating end-to-end A/B testing methodology by Aiyan: experiment design, data engineering, SQL analysis, statistical inference, and business communication.*
