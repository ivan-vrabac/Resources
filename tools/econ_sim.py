"""Calibrate the level curve (server/economy.py LEVEL_XP) with a simple steady-player model.

The player collects mine output every hour (average quality QUALITY, condition CONDITION, no tech,
no HQ, no factories — those only make real players faster), keeps REINVEST of the income for new
mines, always buys the most valuable mine its level unlocks and can afford, and gains XP for the
build cost minus the demolish refund. The target is a smooth pace: level L is reached on day
30 × (L / 50)^1.5, i.e. level 50 (all resources) on day 30 and level 60 (all factories) on day ~39.
The curve and the model are iterated until they agree. Prints the table for economy.py.

    python tools/econ_sim.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server"))
import economy as e  # noqa: E402

START = 250_000
QUALITY = 0.55
CONDITION = 0.85
REINVEST = 0.7
DAYS = 45
MAX_MINES = 10_000


def target_day(level: int) -> float:
    return 30.0 * (level / 50.0) ** 1.5


def simulate(table):
    def lvl_of(xp):
        lv = 1
        while lv < len(table) and table[lv] <= xp:
            lv += 1
        return lv

    credits, xp, n = float(START), 0.0, 0
    income_h = 0.0
    spent_at_hour = []
    by_unlock = sorted(e.MINES.items(), key=lambda kv: -kv[1][1])
    for hour in range(DAYS * 24):
        credits += income_h
        level = lvl_of(xp)
        budget = credits if hour == 0 else min(credits, income_h * REINVEST + max(0.0, credits - income_h * 4))
        while n < MAX_MINES:
            pick = next(((mid, m) for mid, m in by_unlock if m[1] <= level and e.mine_cost(mid, n) <= budget), None)
            if not pick:
                break
            mid, m = pick
            cost = e.mine_cost(mid, n)
            credits -= cost
            budget -= cost
            xp += cost * (1 - e.DEMOLISH_REFUND) * e.XP_PER_CREDIT
            income_h += m[2] * QUALITY * CONDITION * e.PRICES[m[0]]
            n += 1
            level = lvl_of(xp)
        spent_at_hour.append(xp)
    return spent_at_hour, n, income_h


def calibrate():
    table = [0] + [int(1000 * l ** 2.2) for l in range(2, 61)]
    for _ in range(40):
        xp_at, n, inc = simulate(table)
        new = [0]
        for lv in range(2, 61):
            h = min(len(xp_at) - 1, int(target_day(lv) * 24))
            new.append(max(new[-1] + 50 * lv, int(xp_at[h])))
        # damp to converge
        table = [int(0.5 * a + 0.5 * b) for a, b in zip(table, new)]
    return table, n, inc


if __name__ == "__main__":
    table, n, inc = calibrate()
    xp_at, n, inc = simulate(table)

    def day_of(lv):
        x = table[lv - 1]
        return next((h / 24 for h, v in enumerate(xp_at) if v >= x), None)
    for lv in (2, 5, 10, 15, 20, 30, 40, 50, 60):
        print(f"level {lv:2}: needs {table[lv - 1]:>14,} XP, reached on day {day_of(lv)}, target {target_day(lv):.1f}")
    print(f"after {DAYS} days: {n} mines, income {inc:,.0f}/h")
    rounded = [0] + [int(float(f"{x:.3g}")) for x in table[1:]]
    for i in range(1, len(rounded)):
        rounded[i] = max(rounded[i], rounded[i - 1] + 1)
    print("LEVEL_TABLE_60 =", rounded)
