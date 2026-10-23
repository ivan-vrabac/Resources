"""Achievements: tiers computed from real data, recorded once."""
from helpers import call, new_player, set_building


def test_tiers_unlock_once_and_progress():
    hid, sid, _ = new_player("ach", credits=2_000_000_000, level=12)
    set_building(hid, 25, 12)                                    # 12 factory levels
    r = call("/api/v1/achievements", sid)
    by = {a["key"]: a for a in r["achievements"]}
    assert by["balance"]["stars"] == 1 and by["balance"]["next"] == 100_000_000_000
    assert by["level"]["stars"] == 1 and by["factories"]["stars"] == 1
    assert by["hoarder"]["stars"] == 0 and by["hoarder"]["value"] == 0
    assert {(n["key"], n["tier"]) for n in r["new"]} >= {("balance", 1), ("level", 1), ("factories", 1)}
    again = call("/api/v1/achievements", sid)
    assert again["new"] == [] and again["stars"] == r["stars"]
    assert len(r["achievements"]) == 18 and r["maxStars"] == 54
