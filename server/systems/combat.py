"""Phase 6 — mafia attacks, mine defence, and Service Center external maintenance.

Source: eva.txt "COMBAT SYSTEM" + "External maintenance"; next.txt PHASE 6. eva.txt calls its own
numbers approximate; the calibration below reproduces its worked example exactly.

Units (warehouse items): attack — 102 Attack Dogs, 103 Gangster, 104 Private Army;
defence — 95 Watch Dogs, 97 Security Staff, 98 Elite Force.
- Attack value = ATTACK_BASE × (1 + 0.111 × (Mafia HQ level − 1)) → Mafia HQ 5: 7.2 / 72.2 / 144.4.
- Defence value = DEFENCE_BASE × (1 + 0.1 × Training Camp level) → TC 10: 10 / 100 / 200.
  The game defines no Training Camp building yet → level 0 for everyone (BLOCKED, see report).
- Battle: one-on-one, attacker roll U(1, atk) × level bonus vs defender roll U(1, def) × HQ bonus;
  the loser dies, the winner fights the next. Order: dogs → gangsters → army vs dogs → staff → elite.
  Lower-level attacker bonus: +0.5 % per level below the defender (max +50 %). Defender inside its
  HQ boost radius: ×1.25. RNG is seeded per attack (reproducible, stored in the audit log).
- Every mine has free default defence 200 / 5 / 1 (eva.txt), lost when defeated, restored on repair.
  Extra units can be stationed (permanently) on own mines.
- Damage (owner's rule): every attack damages the mine by 10–70 condition points, growing with
  the attack strength sent (Σ units × attack value, log scale, full at STRENGTH_FULL); a won attack
  does 10–70, a lost one 10–30. ×0.7 inside the HQ area, ×(1 − 0.2 × tech share). ≤ 20 % → demolished.
- Loot (won attacks only) is NEW resources (owner's rule: created, not taken from the defender):
  Mafia HQ level × 10 h of the mine's effective output, halved for every successful attack the
  attacker made in the last 24 h (anti-spam), capped by the attacker's warehouse space.
- Failure: 10 % of the attacker's lost units desert to the defending mine.
- Intel: below Mafia HQ 10 the target's defence is an estimate (±10 % per missing level, stable per
  attacker/mine/day); at Mafia HQ 10 it is exact.
- Limits: attack range 100 m (Mafia HQ 1) … 500 m (level 10); a mine can be attacked once per 24 h.
- External maintenance (Service Center 121): repair another player's mine for free when it is
  within the helper's range (100 m + 10 m × Haulage Firm level, max 200 m), at ≤ 96 % condition, and
  its owner was active within 120 days. Helper reward: Service Center level × 1 h of the mine's
  output (system-generated) + 0–4 Cargo Rain crates by SC level. Anti-farming: each mine once per
  24 h, each helper at most 20 rewarded repairs per UTC day, never your own mines.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import math
import random
import uuid

import econ
from . import cargo, int_arg

MAFIA_HQ = 86
TRAINING_CAMP = 96          # "Army Camp" — not a defined building yet (level 0)
SERVICE_CENTER = 121
HAULAGE_FIRM = 123
ATTACK_UNITS = (102, 103, 104)      # dogs, gangsters, private army
DEFENCE_UNITS = (95, 97, 98)        # watch dogs, security staff, elite force
ATTACK_BASE = (5.0, 50.0, 100.0)
DEFENCE_BASE = (5.0, 50.0, 100.0)
DEFAULT_DEFENCE = (200, 5, 1)
MAX_UNITS = 100_000
ATTACK_COOLDOWN_S = 24 * 3600
WA_ATTACK_WON, WA_ATTACK_LOST = -0.1, -10.0
STRENGTH_FULL = 100_000.0       # attack strength for maximum damage
# owner 2026-10-20: a won attack can also bring special items: (item, chance, min, max)
SPECIAL_LOOT = ((43, 0.30, 1, 3), (44, 0.10, 1, 2), (45, 0.05, 1, 2), (46, 0.02, 1, 1), (48, 0.005, 1, 1))
LOOT_HOURS_PER_LEVEL = 10
REPAIR_COOLDOWN_S = 24 * 3600
REPAIR_DAILY_LIMIT = 20


def attack_values(mafia_level: int):
    f = 1 + 0.111 * (max(1, mafia_level) - 1)
    return tuple(round(b * f, 1) for b in ATTACK_BASE)


def attack_strength(counts, values) -> float:
    return sum(c * v for c, v in zip(counts, values))


def attack_damage(strength: float, won: bool) -> float:
    """10–70 points when won, 10–30 when lost, growing with the strength sent (log scale)."""
    s = max(0.0, min(1.0, math.log10(1 + max(0.0, strength)) / math.log10(1 + STRENGTH_FULL)))
    return 10 + (60 if won else 20) * s


def estimate(counts, mafia_level, seed_key):
    """Defence as seen by an attacker: exact at Mafia HQ 10, otherwise ±10 % per missing level."""
    if mafia_level >= 10:
        return list(counts), True
    err = 0.1 * (10 - max(0, mafia_level))
    rng = random.Random(int(hashlib.sha256(seed_key.encode()).hexdigest()[:12], 16))
    return [max(0, round(c * (1 + rng.uniform(-err, err)))) for c in counts], False


def defence_values(camp_level: int):
    g = 1 + 0.1 * max(0, min(10, camp_level))
    return tuple(round(b * g, 1) for b in DEFENCE_BASE)


def attack_range(mafia_level: int) -> float:
    """100 m at Mafia HQ level 1 … 500 m at level 10 (owner 2026-10-20)."""
    if mafia_level < 1:
        return 0.0
    return round(100.0 + (min(10, mafia_level) - 1) * 400.0 / 9, 1)


def helper_range(haulage_level: int) -> float:
    return min(200.0, 100.0 + 10.0 * max(0, haulage_level))


def battle(att_counts, att_vals, def_counts, def_vals, att_bonus: float, def_bonus: float, rng: random.Random):
    """eva.txt one-on-one dice. Returns (att_left, def_left) lists."""
    a, d = list(att_counts), list(def_counts)
    ai = next((i for i in range(3) if a[i] > 0), 3)
    di = next((i for i in range(3) if d[i] > 0), 3)
    while ai < 3 and di < 3:
        ar = rng.uniform(1, max(1.0, att_vals[ai])) * att_bonus
        dr = rng.uniform(1, max(1.0, def_vals[di])) * def_bonus
        if ar > dr:
            d[di] -= 1
            while di < 3 and d[di] == 0:
                di += 1
        else:
            a[ai] -= 1
            while ai < 3 and a[ai] == 0:
                ai += 1
    return a, d


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS mine_defence (
            mine_id      TEXT PRIMARY KEY,
            dogs         INTEGER NOT NULL DEFAULT 0,
            staff        INTEGER NOT NULL DEFAULT 0,
            elite        INTEGER NOT NULL DEFAULT 0,
            default_down INTEGER NOT NULL DEFAULT 0   -- default 200/5/1 defeated until next repair
        );
        CREATE TABLE IF NOT EXISTS attacks (
            id           TEXT PRIMARY KEY,
            ts           TEXT NOT NULL,
            attacker_hid TEXT NOT NULL,
            defender_hid TEXT NOT NULL,
            mine_id      TEXT NOT NULL,
            success      INTEGER NOT NULL,
            detail       TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_attacks_mine ON attacks(mine_id, ts);
        CREATE TABLE IF NOT EXISTS external_repairs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            ts          TEXT NOT NULL,
            helper_hid  TEXT NOT NULL,
            owner_hid   TEXT NOT NULL,
            mine_id     TEXT NOT NULL,
            reward_item INTEGER,
            reward_qty  REAL,
            crates      INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_extrep_mine ON external_repairs(mine_id, ts);
        CREATE INDEX IF NOT EXISTS idx_extrep_helper ON external_repairs(helper_hid, ts);
    """)
    conn.commit()


def defence_of(conn, mine_id):
    """(dogs, staff, elite) currently defending the mine, including the default unless defeated."""
    r = conn.execute("SELECT dogs, staff, elite, default_down FROM mine_defence WHERE mine_id=?", (mine_id,)).fetchone()
    stationed = (r[0], r[1], r[2]) if r else (0, 0, 0)
    down = bool(r[3]) if r else False
    base = (0, 0, 0) if down else DEFAULT_DEFENCE
    return tuple(s + b for s, b in zip(stationed, base)), stationed, down


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    def mine_or_fail(conn, mine_id):
        m = conn.execute("SELECT * FROM mines WHERE mine_id=?", (mine_id,)).fetchone()
        if not m:
            raise econ.GameError("gone", "This mine no longer exists")
        return m

    def recent_wins(conn, hid, now) -> int:
        return conn.execute("SELECT COUNT(*) FROM attacks WHERE attacker_hid=? AND success=1 AND ts>=?",
                            (hid, (now - datetime.timedelta(hours=24)).isoformat())).fetchone()[0]

    def in_hq_area(conn, m) -> bool:
        hq = conn.execute("SELECT lat,lng,level FROM hq WHERE hid=?", (m["owner_hid"],)).fetchone()
        return bool(hq) and econ.dist_m(m["lat"], m["lng"], hq["lat"], hq["lng"]) <= h.HQ_BOOST_RADIUS.get(hq["level"], 115)

    @api.endpoint("/api/v1/combat/info", feature="COMBAT")
    def info(conn, hid, form):
        mafia = h.building_level(conn, hid, MAFIA_HQ)
        out = {"err": 0, "mafiaLevel": mafia, "attackRange": attack_range(mafia),
               "attackValues": attack_values(mafia),
               "units": {str(u): econ.qty_of(conn, hid, u) for u in ATTACK_UNITS + DEFENCE_UNITS},
               "trainingCampDefined": False}
        mine_id = (form.get("mineID") or "").strip()
        if mine_id:
            m = mine_or_fail(conn, mine_id)
            total, stationed, down = defence_of(conn, mine_id)
            camp = h.building_level(conn, m["owner_hid"], TRAINING_CAMP)
            last = conn.execute("SELECT MAX(ts) FROM attacks WHERE mine_id=?", (mine_id,)).fetchone()[0]
            own = m["owner_hid"] == hid
            shown, exact = (list(total), True) if own else estimate(
                total, mafia, f"{hid}:{mine_id}:{econ.utcnow().strftime('%Y-%m-%d')}")
            next_at = (datetime.datetime.fromisoformat(last) + datetime.timedelta(seconds=ATTACK_COOLDOWN_S)
                       ).isoformat() if last else None
            out["target"] = {"mineID": mine_id, "isMine": own, "defence": shown, "defenceExact": exact,
                             "nextAttackAt": next_at if next_at and next_at > econ.utcnow_iso() else None,
                             "lootItem": h.MINE_TYPES.get(m["item_id"], {}).get("res"),
                             "stationed": stationed if own else None, "defenceValues": defence_values(camp),
                             "inHqArea": in_hq_area(conn, m), "condition": h.current_condition(m),
                             "lastAttack": last,
                             "lootEstimate": round(h.mine_rate_hr(conn, m["owner_hid"], m) * LOOT_HOURS_PER_LEVEL * mafia
                                                   * 0.5 ** recent_wins(conn, hid, econ.utcnow()))}
        return out

    @api.endpoint("/api/v1/combat/station", feature="COMBAT")
    def station(conn, hid, form):
        """Permanently station defence units (watch dogs, staff, elite) on one of your mines."""
        mine_id = (form.get("mineID") or "").strip()
        n = [int_arg(form, k, 0, 0, MAX_UNITS) for k in ("dogs", "staff", "elite")]
        if sum(n) == 0:
            raise econ.GameError("bad_input", "Choose some units")
        with econ.tx(conn):
            m = mine_or_fail(conn, mine_id)
            if m["owner_hid"] != hid:
                raise econ.GameError("not_yours", "You can only station units on your own mines")
            for unit, q in zip(DEFENCE_UNITS, n):
                if q:
                    econ.take(conn, hid, unit, q, "station_defence", mine_id)
            conn.execute("INSERT INTO mine_defence(mine_id, dogs, staff, elite) VALUES(?,?,?,?) ON CONFLICT(mine_id) "
                         "DO UPDATE SET dogs=dogs+excluded.dogs, staff=staff+excluded.staff, elite=elite+excluded.elite",
                         (mine_id, *n))
            total, stationed, _ = defence_of(conn, mine_id)
        return {"err": 0, "defence": total, "stationed": stationed}

    @api.endpoint("/api/v1/combat/attack", feature="COMBAT")
    def attack(conn, hid, form):
        mine_id = (form.get("mineID") or "").strip()
        lat, lng = econ.parse_pos(form)
        att = [int_arg(form, k, 0, 0, MAX_UNITS) for k in ("dogs", "gangsters", "army")]
        if sum(att) == 0:
            raise econ.GameError("bad_input", "Send at least one unit")
        rid = (form.get("rid") or "").strip()[:64]
        with econ.tx(conn):
            if rid:
                prev = econ.once_get(conn, "attack", hid, rid)
                if prev is not None:
                    return prev
            h.check_travel(conn, hid, lat, lng)
            m = mine_or_fail(conn, mine_id)
            if m["owner_hid"] == hid:
                raise econ.GameError("own_mine", "You can't attack your own mine")
            mafia = h.building_level(conn, hid, MAFIA_HQ)
            if mafia < 1:
                raise econ.GameError("locked", "Build a Mafia HQ first")
            econ.require_within(lat, lng, m["lat"], m["lng"], attack_range(mafia), "mine")
            now = econ.utcnow()
            last = conn.execute("SELECT MAX(ts) FROM attacks WHERE mine_id=?", (mine_id,)).fetchone()[0]
            if last and (now - datetime.datetime.fromisoformat(last)).total_seconds() < ATTACK_COOLDOWN_S:
                raise econ.GameError("cooldown", "This mine can only be attacked once every 24 hours")
            for unit, q in zip(ATTACK_UNITS, att):
                if q:
                    econ.take(conn, hid, unit, q, "attack_units", mine_id)
            defender = m["owner_hid"]
            levels = {r[0]: r[1] for r in conn.execute("SELECT hID, level FROM players WHERE hID IN (?,?)", (hid, defender))}
            att_bonus = 1 + min(0.5, 0.005 * max(0, (levels.get(defender) or 1) - (levels.get(hid) or 1)))
            hq_area = in_hq_area(conn, m)
            def_bonus = 1.25 if hq_area else 1.0
            total, stationed, down = defence_of(conn, mine_id)
            attack_id = uuid.uuid4().hex
            seed = int(hashlib.sha256(attack_id.encode()).hexdigest()[:12], 16)
            a_left, d_left = battle(att, attack_values(mafia), total,
                                    defence_values(h.building_level(conn, defender, TRAINING_CAMP)),
                                    att_bonus, def_bonus, random.Random(seed))
            success = sum(d_left) == 0
            # surviving attackers go home
            for unit, q in zip(ATTACK_UNITS, a_left):
                if q:
                    econ.give(conn, hid, unit, q, "attack_return", attack_id, ignore_capacity=True)
            # defender's stationed units: losses come from the default first, then stationed units
            # stationed units fall only after the default defence is gone
            new_stationed = [min(s, left) for s, left in zip(stationed, d_left)]
            result = {"err": 0, "attackID": attack_id, "success": success,
                      "attackersLeft": a_left, "defendersLeft": d_left, "sent": att, "defence": total}
            # settle the owner's production at the old condition before the damage
            h.collect_mine(conn, m)
            cur = conn.execute("SELECT condition FROM mines WHERE mine_id=?", (mine_id,)).fetchone()
            dmg = attack_damage(attack_strength(att, attack_values(mafia)), success)
            if hq_area:
                dmg *= 0.7
            tech = ((m["tu1"] or 0) + (m["tu2"] or 0) + (m["tu3"] or 0) + (m["tu4"] or 0)) / 400.0
            dmg *= 1 - 0.2 * tech
            destroyed = True
            cond = 0.0
            if cur:
                cond = round(max(0.0, float(cur[0]) - dmg), 2)
                destroyed = cond <= 20.0
            if destroyed:
                conn.execute("DELETE FROM mines WHERE mine_id=?", (mine_id,))
                conn.execute("DELETE FROM mine_defence WHERE mine_id=?", (mine_id,))
            else:
                conn.execute("UPDATE mines SET condition=? WHERE mine_id=?", (cond, mine_id))
            result.update(damage=round(dmg, 1), condition=cond, destroyed=destroyed)
            # owner 2026-10-23: attacking hurts your own working atmosphere (won −0.1, lost −10) and the
            # units that didn't come back are a permanent sink (XP)
            result["wa"] = h.change_wa(conn, hid, WA_ATTACK_WON if success else WA_ATTACK_LOST, "attack")
            h.award_sink(conn, hid, res={u: s - l for u, s, l in zip(ATTACK_UNITS, att, a_left) if s > l})
            if success:
                res = h.MINE_TYPES.get(m["item_id"], {}).get("res")
                wins = recent_wins(conn, hid, now)
                loot_target = h.mine_rate_hr(conn, defender, m) * LOOT_HOURS_PER_LEVEL * mafia * (0.5 ** wins)
                # new resources (system-generated), capped by the attacker's warehouse space
                loot = econ.give(conn, hid, res, round(loot_target, 2), "attack_loot", attack_id, strict=False) if res else 0
                if not destroyed:
                    conn.execute("INSERT INTO mine_defence(mine_id, default_down) VALUES(?,1) ON CONFLICT(mine_id) "
                                 "DO UPDATE SET dogs=0, staff=0, elite=0, default_down=1", (mine_id,))
                specials = []
                srng = random.Random(seed + 7)
                for item, chance, lo, hi in SPECIAL_LOOT:
                    if srng.random() < chance:
                        got = econ.give(conn, hid, item, srng.randint(lo, hi), "attack_special", attack_id,
                                        strict=False)
                        if got:
                            specials.append({"itemID": item, "qty": int(got)})
                result.update(lootItem=res, loot=loot, lootHalvings=wins, specials=specials)
            elif not destroyed:
                lost = [s - l for s, l in zip(att, a_left)]
                deserters = [int(x * 0.10) for x in lost]
                conn.execute("INSERT INTO mine_defence(mine_id, dogs, staff, elite) VALUES(?,?,?,?) ON CONFLICT(mine_id) "
                             "DO UPDATE SET dogs=?, staff=?, elite=?",
                             (mine_id, new_stationed[0] + deserters[0], new_stationed[1] + deserters[1],
                              new_stationed[2] + deserters[2], new_stationed[0] + deserters[0],
                              new_stationed[1] + deserters[1], new_stationed[2] + deserters[2]))
                result.update(deserters=deserters)
            conn.execute("INSERT INTO attacks(id, ts, attacker_hid, defender_hid, mine_id, success, detail) "
                         "VALUES(?,?,?,?,?,?,?)", (attack_id, now.isoformat(), hid, defender, mine_id,
                                                   1 if success else 0, json.dumps({**result, "seed": seed})))
            h.add_proto(conn, hid, "attack", {"mID": mine_id, "success": success, "defenderHID": defender})
            h.add_proto(conn, defender, "attacked", {"mID": mine_id, "success": success, "attackerHID": hid})
            econ.emit(conn, "attack", hid, {"defender": defender, "success": success,
                                            "destroyed": result.get("destroyed", False),
                                            "sent": sum(att)}, lat=round(m["lat"], 2), lng=round(m["lng"], 2))
            if rid:
                econ.once_put(conn, "attack", hid, rid, result)
        try:
            with h.get_db() as c2:
                h.push(c2, defender, "Mine attacked", "One of your mines was attacked." if not success
                       else "One of your mines was damaged in an attack. Repair it soon.")
        except Exception:
            pass
        return result

    @api.endpoint("/api/v1/service/repair", feature="COMBAT")
    def external_repair(conn, hid, form):
        """External maintenance: repair another player's mine for free and earn the Service Center reward."""
        mine_id = (form.get("mineID") or "").strip()
        lat, lng = econ.parse_pos(form)
        with econ.tx(conn):
            h.check_travel(conn, hid, lat, lng)
            m = mine_or_fail(conn, mine_id)
            owner = m["owner_hid"]
            if owner == hid:
                raise econ.GameError("own_mine", "External maintenance is for other players' mines")
            econ.require_within(lat, lng, m["lat"], m["lng"],
                                helper_range(h.building_level(conn, hid, HAULAGE_FIRM)), "mine")
            if h.current_condition(m) > 96.0:
                raise econ.GameError("not_needed", "This mine doesn't need maintenance (above 96%)")
            now = econ.utcnow()
            active = conn.execute("SELECT MAX(day) FROM player_activity WHERE hid=?", (owner,)).fetchone()[0]
            if not active or active < (now - datetime.timedelta(days=120)).strftime("%Y-%m-%d"):
                raise econ.GameError("inactive_owner", "The owner hasn't played for 120 days")
            last = conn.execute("SELECT MAX(ts) FROM external_repairs WHERE mine_id=?", (mine_id,)).fetchone()[0]
            if last and (now - datetime.datetime.fromisoformat(last)).total_seconds() < REPAIR_COOLDOWN_S:
                raise econ.GameError("cooldown", "This mine was already maintained in the last 24 h")
            # settle production at the old condition, then repair (owner pays nothing)
            h.collect_mine(conn, m)
            if not conn.execute("SELECT 1 FROM mines WHERE mine_id=?", (mine_id,)).fetchone():
                raise econ.GameError("gone", "This mine was destroyed")
            m = mine_or_fail(conn, mine_id)
            conn.execute("UPDATE mines SET condition=100, last_coll=? WHERE mine_id=?", (now.isoformat(), mine_id))
            conn.execute("UPDATE mine_defence SET default_down=0 WHERE mine_id=?", (mine_id,))
            sc = h.building_level(conn, hid, SERVICE_CENTER)
            today = now.strftime("%Y-%m-%d")
            rewarded_today = conn.execute("SELECT COUNT(*) FROM external_repairs WHERE helper_hid=? AND ts>=? "
                                          "AND (reward_qty > 0 OR crates > 0)", (hid, today)).fetchone()[0]
            res, qty, crates = None, 0.0, 0
            if True:                              # owner 2026-10-23: no daily maximum
                res = h.MINE_TYPES.get(m["item_id"], {}).get("res")
                if sc > 0 and res:
                    qty = econ.give(conn, hid, res, round(h.mine_rate_hr(conn, owner, m) * sc, 2),
                                    "external_repair_reward", mine_id, strict=False)
                crates = random.Random().randint(0, min(4, (sc + 2) // 3)) if sc > 0 else 0
                cargo.grant(conn, hid, crates, "external_repair")
            conn.execute("INSERT INTO external_repairs(ts, helper_hid, owner_hid, mine_id, reward_item, reward_qty, crates) "
                         "VALUES(?,?,?,?,?,?,?)", (now.isoformat(), hid, owner, mine_id, res, qty, crates))
            econ.emit(conn, "mine_repaired", hid, {"mID": mine_id, "how": "external"}, public=False)
            h.add_proto(conn, owner, "externalrepair", {"mID": mine_id})
        return {"err": 0, "rewardItem": res, "rewardQty": qty, "crates": crates,
                "dailyLeft": None}
