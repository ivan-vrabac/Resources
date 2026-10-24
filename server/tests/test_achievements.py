"""Achievements: tiers computed from real data, recorded once."""
from helpers import call, new_player, set_building


def test_tiers_unlock_once_and_progress():
    hid, sid, _ = new_player("ach", credits=2_000_000_000, level=25)
    set_building(hid, 25, 12)                                    # 12 factory levels
    r = call("/api/v1/achievements", sid)
    by = {a["key"]: a for a in r["achievements"]}
    assert by["balance"]["stars"] == 1 and by["balance"]["next"] == 10_000_000_000
    assert by["level"]["stars"] == 1 and by["factories"]["stars"] == 1
    assert by["hoarder"]["stars"] == 0 and by["hoarder"]["value"] == 0
    assert {(n["key"], n["tier"]) for n in r["new"]} >= {("balance", 1), ("level", 1), ("factories", 1)}
    again = call("/api/v1/achievements", sid)
    assert again["new"] == [] and again["stars"] == r["stars"]
    assert len(r["achievements"]) == 18 and r["maxStars"] == 54



def test_special_building_info_table():
    hid, sid, _ = new_player("binfo")
    set_building(hid, 65, 4)
    r = call("/api/v1/buildings/info", sid)
    museum = next(b for b in r["buildings"] if b["itemID"] == 65)
    assert museum["level"] == 4 and len(museum["levels"]) == 10
    eff = {e["label"]: e["value"] for e in museum["levels"][9]["effects"]}
    assert eff["Pick-up range (cargo, artifacts)"] == "300 m"
    assert "Giant Diamond" in eff["Objects that can be found"] and "Fossils" in eff["Objects that can be found"]
    lvl1 = {e["label"]: e["value"] for e in museum["levels"][0]["effects"]}
    assert "Giant Diamond" not in lvl1["Objects that can be found"]
    hq = call("/api/v1/hq/info", sid)
    assert len(hq["levels"]) == 10 and hq["levels"][9]["effects"][0]["value"] == "×10"
    assert any(e["label"] == "Pick-up range (cargo, artifacts)" and e["value"] == "150 m" for e in museum["current"])
