"""Special building information: for every level, what it costs and what it gives — taken from
the same formulas the game uses, so the table can't drift from the rules."""
from __future__ import annotations

import protection
from . import archaeology, cargo, combat, market

MUSEUM, ARCH_CENTER, MAFIA_HQ, SERVICE_CENTER, HAULAGE = 65, 164, 86, 121, 123


def effects(h, item_id: int, lvl: int) -> list:
    """[(label, value)] for one building at one level."""
    if item_id == 116:                                              # Tech Center
        c = h.TC_CONFIG[min(lvl, len(h.TC_CONFIG) - 1)]
        return [("Scan radius", f"{c['radius']} m"), ("Max quality shown", f"{c['max_quality']}%"),
                ("Scan accuracy", f"{c['accuracy']}%")]
    if item_id == 119:                                              # Drone Research
        rng = h.DRONE_SCAN_RANGES[max(0, min(lvl, len(h.DRONE_SCAN_RANGES)) - 1)] if lvl else 0
        return [("Drone range", f"{rng / 1000:g} km" if rng else "—"),
                ("Remote construction", "yes" if lvl >= 10 else "no")]
    if item_id == MUSEUM:
        return [("Pick-up range (cargo, artifacts)", f"{archaeology.pickup_range(lvl):.0f} m"),
                ("Crate quantity bonus", f"+{round(cargo.MUSEUM_QTY_BONUS * lvl * 100)}%"),
                ("Objects that can be found",
                 ", ".join(n for _, (n, _, m) in sorted(cargo.BOX_LOOT.items(), key=lambda x: x[1][2]) if m <= lvl))]
    if item_id == 71:                                               # Hospital
        return [("Disease chance", f"−{round((1 - protection.disease_factor(lvl)) * 100)}%"),
                ("Disease spread", f"−{round((1 - protection.spread_factor(lvl)) * 100)}%")]
    if item_id == 58:                                               # Recycling Plant
        return [("Recycling yield", f"{round((0.5 + 0.05 * lvl) * 100)}%")]
    if item_id == protection.SEISMOLOGY:
        return [("Earthquake damage", f"−{round((1 - protection.quake_factor(lvl)) * 100)}%")]
    if item_id == protection.FIRE_STATION:
        return [("Factory fire chance", f"−{round((1 - protection.fire_factor(lvl)) * 100)}%"),
                ("Fire duration", f"−{round((1 - protection.fire_duration_factor(lvl)) * 100)}%")]
    if item_id == HAULAGE:
        return [("Transport tax", f"{round(market.tax_rate(lvl) * 100)}%"),
                ("Boss / truck range", f"{min(200, 100 + 10 * lvl)} m"),
                ("Stacked Cargo Rain + trucks", "yes" if lvl >= cargo.STACK_HF_LEVEL else f"level {cargo.STACK_HF_LEVEL}")]
    if item_id == MAFIA_HQ:
        a = combat.attack_values(lvl)
        return [("Attack range", f"{combat.attack_range(lvl):.0f} m" if lvl else "—"),
                ("Attack values (dogs / gangsters / army)", f"{a[0]} / {a[1]} / {a[2]}" if lvl else "—"),
                ("Loot", f"{lvl * combat.LOOT_HOURS_PER_LEVEL} h of output" if lvl else "—")]
    if item_id == 72:                                               # Law Firm
        return [("Claims", f"−{round((1 - protection.law_firm_factor(lvl)) * 100)}% (no claims in the game yet)")]
    if item_id == SERVICE_CENTER:
        return [("Reward per repair of others' mines", f"{lvl} h of the mine's output"),
                ("Bonus crates", f"0–{min(4, (lvl + 2) // 3)}")]
    if item_id == 122:                                              # HR Department
        return [("Strikes and claims", "no strike mechanic in the game yet")]
    if item_id == ARCH_CENTER:
        return [("Detection range", f"{archaeology.detect_range(lvl):.0f} m"),
                ("Reveal range", f"{archaeology.reveal_range(lvl):.0f} m"),
                ("Archaeologists per recovery", f"{archaeology.archaeologists_needed(lvl)}")]
    if item_id == 61:                                               # Casino
        return [("Maximum bet", f"{lvl * 1_000_000:,} credits"), ("Free spins per day", "500")]
    return []


def install(api) -> None:
    h = api.h

    @api.endpoint("/api/v1/hq/info")
    def hq_info(conn, hid, form):
        """Headquarters levels: boost and range per level, and what each upgrade needs."""
        cur = conn.execute("SELECT level FROM hq WHERE hid=?", (hid,)).fetchone()
        levels = []
        for lvl in range(1, 11):
            levels.append({"level": lvl, "res": {str(k): v for k, v in h.HQ_UPGRADE_REQS.get(lvl, {}).items()},
                           "effects": [{"label": "Mine boost", "value": f"+{round((h.HQ_BOOST_FACTORS[lvl] - 1) * 100)}%"},
                                       {"label": "Boost range", "value": f"{h.HQ_BOOST_RADIUS[lvl]} m"}]})
        return {"err": 0, "level": cur[0] if cur else 0, "levels": levels,
                "bonusLevels": "HQ level 10 bonus levels 1–6: one per 10 000 luxury points"}

    @api.endpoint("/api/v1/buildings/info")
    def info(conn, hid, form):
        out = []
        for item_id, sb in h.SPECIAL_BUILDINGS.items():
            cur = h.building_level(conn, hid, item_id)
            levels = []
            for lvl in range(1, sb["max_level"] + 1):
                cost = sb["costs"][lvl - 1] if lvl - 1 < len(sb["costs"]) else {}
                levels.append({"level": lvl, "credits": cost.get("credits", 0),
                               "res": {str(k): v for k, v in cost.get("res", {}).items()},
                               "effects": [{"label": a, "value": b} for a, b in effects(h, item_id, lvl)]})
            out.append({"itemID": item_id, "name": sb["name"], "desc": sb["desc"], "level": cur,
                        "current": [{"label": a, "value": b} for a, b in effects(h, item_id, cur)] if cur else [],
                        "levels": levels})
        return {"err": 0, "buildings": out}
