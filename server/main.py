from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool
import auth
import re
import httpx, json, datetime, os, zlib, sqlite3, hashlib, uuid, base64, random, math, struct, threading, time

app = FastAPI()
# All deployment settings come from the environment; see deploy/.env.example.
DB_PATH = os.environ.get("DB_PATH", "/data/game.db")
LOG_FILE = os.environ.get("LOG_FILE", "/logs/requests.log")
# Optional legacy pass-through for requests this server does not implement.
# Disabled unless both are set: the incoming host suffix FROM is rewritten to TO.
UPSTREAM_PROXY_FROM = os.environ.get("UPSTREAM_PROXY_FROM", "")
UPSTREAM_PROXY_TO = os.environ.get("UPSTREAM_PROXY_TO", "")
SERVER_MID = os.environ.get("SERVER_MID", "resources0000000000000000000001")
os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
os.makedirs(os.path.dirname(LOG_FILE) or ".", exist_ok=True)

# ── Constants ───────────────────────────────────────────────────────────────────

# mine_item_id → {resource_id, units_per_hour, build_cost, xp, min_level}
MINE_TYPES = {
    # mine_id: res=resource produced, rate=units/hr at lvl1 100%/100% no tech (= official max_rate / 5)
    # cost=build credits, lvl=min player level (per official reference)
    4:  {"res": 2,   "rate": 306, "cost": 2000,  "xp": 5,   "lvl": 1},   # Clay Pit        1530/h max
    5:  {"res": 3,   "rate": 108, "cost": 2000,  "xp": 5,   "lvl": 3},   # Gravel Pit       542/h max
    9:  {"res": 8,   "rate": 102, "cost": 3000,  "xp": 10,  "lvl": 4},   # Coal Mine         510/h max
    11: {"res": 10,  "rate": 61,  "cost": 8000,  "xp": 20,  "lvl": 1},   # Oil Derrick       306/h max
    16: {"res": 12,  "rate": 61,  "cost": 4000,  "xp": 15,  "lvl": 11},  # Bauxite Mine      306/h max
    17: {"res": 13,  "rate": 77,  "cost": 5000,  "xp": 15,  "lvl": 4},   # Iron Ore Mine    382/h max
    18: {"res": 14,  "rate": 408, "cost": 15000, "xp": 50,  "lvl": 38},  # Gold Mine        2040/h max
    19: {"res": 15,  "rate": 128, "cost": 10000, "xp": 30,  "lvl": 33},  # Silver Mine       638/h max
    21: {"res": 20,  "rate": 102, "cost": 2500,  "xp": 8,   "lvl": 2},   # Limestone Quarry  510/h max
    27: {"res": 26,  "rate": 82,  "cost": 6000,  "xp": 20,  "lvl": 9},   # Copper Mine       408/h max
    50: {"res": 49,  "rate": 56,  "cost": 7000,  "xp": 25,  "lvl": 20},  # Ilmenite Mine     280/h max
    54: {"res": 53,  "rate": 153, "cost": 2500,  "xp": 8,   "lvl": 7},   # Sand Mine         765/h max
    82: {"res": 81,  "rate": 255, "cost": 50000, "xp": 100, "lvl": 48},  # Diamond Mine     1275/h max
    89: {"res": 90,  "rate": 408, "cost": 20000, "xp": 60,  "lvl": 15},  # Lithium Ore Mine 2040/h max
    168:{"res": 169, "rate": 102, "cost": 25000, "xp": 70,  "lvl": 50},  # Wolframite Mine   510/h max
}

# item_id → {produces, needs:{item_id:qty}, output_amount_per_batch, batch_hours, cost}
# Factories (srx.txt list). The first 8 keep their original numbers; the others follow the same
# cheap pattern (owner 2026-10-19: keep costs low): per batch the srx.txt recipe inputs, output ≈
# srx base rate / 20 per hour, build cost 5 000 + 2 500 × unlock level. Unlock levels follow
# srx.txt, which never unlocks a factory before the resources it needs.
FACTORY_TYPES = {
    6:  {"name":"Concrete Factory",  "produces":7,  "needs":{20:2,3:1},  "out":50,  "hrs":2, "cost":10000, "lvl":3},
    25: {"name":"Brick Factory",     "produces":24, "needs":{2:3},       "out":80,  "hrs":2, "cost":8000,  "lvl":1},
    31: {"name":"Ironworks",         "produces":30, "needs":{13:3,8:1},  "out":40,  "hrs":4, "cost":20000, "lvl":5},
    33: {"name":"Aluminium Factory", "produces":32, "needs":{12:4},      "out":30,  "hrs":3, "cost":15000, "lvl":12},
    34: {"name":"Silver Refinery",   "produces":35, "needs":{15:5},      "out":20,  "hrs":5, "cost":25000, "lvl":40},
    37: {"name":"Copper Refinery",   "produces":36, "needs":{26:4},      "out":25,  "hrs":4, "cost":20000, "lvl":10},
    39: {"name":"Oil Refinery",      "produces":38, "needs":{10:5},      "out":15,  "hrs":6, "cost":30000, "lvl":6},
    80: {"name":"Gold Refinery",     "produces":79, "needs":{14:8},      "out":10,  "hrs":8, "cost":40000, "lvl":45},
    23: {"name":"Fertilizer Factory", "produces":22, "needs":{20:8}, "out":182, "hrs":3, "cost":15000, "lvl":4},
    60: {"name":"Glazier's Workshop", "produces":59, "needs":{53:6,38:8,20:4}, "out":128, "hrs":4, "cost":25000, "lvl":8},
    29: {"name":"Insecticide Factory", "produces":28, "needs":{36:1,20:3}, "out":525, "hrs":3, "cost":32500, "lvl":11},
    62: {"name":"Plastic Factory", "produces":57, "needs":{10:1}, "out":270, "hrs":3, "cost":40000, "lvl":14},
    91: {"name":"Lithium Refinery", "produces":92, "needs":{90:115}, "out":150, "hrs":4, "cost":45000, "lvl":16},
    94: {"name":"Battery Factory", "produces":93, "needs":{92:20,57:40,32:10}, "out":120, "hrs":4, "cost":50000, "lvl":18},
    99: {"name":"Arms Factory", "produces":87, "needs":{30:1,32:1,93:1}, "out":25, "hrs":4, "cost":57500, "lvl":21},
    68: {"name":"Silicon Refinery", "produces":67, "needs":{53:20,2:1,38:5}, "out":30, "hrs":5, "cost":65000, "lvl":24},
    69: {"name":"Electronics Factory", "produces":66, "needs":{57:4,36:3,67:1}, "out":96, "hrs":4, "cost":72500, "lvl":27},
    52: {"name":"Titanium Refinery", "produces":51, "needs":{49:8}, "out":64, "hrs":4, "cost":80000, "lvl":30},
    76: {"name":"Medical Technology Inc.", "produces":75, "needs":{51:4,57:2,66:2}, "out":80, "hrs":4, "cost":92500, "lvl":35},
    85: {"name":"Goldsmith", "produces":84, "needs":{81:1000,79:1,35:1}, "out":20, "hrs":4, "cost":130000, "lvl":50},
    170: {"name":"Tungsten Smelter", "produces":171, "needs":{169:40,38:5,20:20}, "out":40, "hrs":4, "cost":130000, "lvl":50},
    125: {"name":"Truck Plant", "produces":124, "needs":{30:100,93:25,35:50}, "out":20, "hrs":4, "cost":142500, "lvl":55},
    118: {"name":"Drone Shipyard", "produces":117, "needs":{66:25,51:50,93:250}, "out":1, "hrs":20, "cost":155000, "lvl":60},
    165: {"name":"Detector Factory", "produces":166, "needs":{93:50,66:30,171:50}, "out":1, "hrs":4, "cost":155000, "lvl":60},
}

# Resources required to BUILD each factory (in addition to credits)
FACTORY_BUILD_RESOURCES = {
    6:  {20: 100, 3: 50},    # Concrete Factory: Limestone + Gravel
    25: {2: 200, 3: 100},    # Brick Factory: Clay + Gravel
    31: {13: 150, 20: 100},  # Ironworks: Iron Ore + Limestone
    33: {12: 200, 13: 50},   # Aluminium Factory: Bauxite + Iron Ore
    34: {15: 100, 13: 50},   # Silver Refinery: Silver Ore + Iron Ore
    37: {26: 150, 13: 50},   # Copper Refinery: Chalcopyrite + Iron Ore
    39: {10: 100, 8: 50},    # Oil Refinery: Crude Oil + Coal
    80: {14: 50, 13: 100},   # Gold Refinery: Gold Ore + Iron Ore
    23: {7: 50, 24: 25, 20: 10},   # srx.txt materials / 100
    60: {7: 250, 24: 30, 20: 10},   # srx.txt materials / 100
    29: {7: 250, 30: 20, 36: 10},   # srx.txt materials / 100
    62: {7: 160, 30: 10, 32: 10},   # srx.txt materials / 100
    91: {7: 250, 30: 100, 59: 10},   # srx.txt materials / 100
    94: {7: 200, 32: 100, 59: 60},   # srx.txt materials / 100
    99: {24: 5000, 7: 500, 59: 100},   # srx.txt materials / 100
    68: {7: 200, 30: 12, 59: 15},   # srx.txt materials / 100
    69: {7: 200, 32: 10, 59: 80},   # srx.txt materials / 100
    52: {7: 300, 30: 100, 59: 25},   # srx.txt materials / 100
    76: {7: 400, 30: 95, 57: 160},   # srx.txt materials / 100
    85: {7: 200, 24: 900, 59: 200},   # srx.txt materials / 100
    170: {7: 300, 30: 100, 51: 100},   # srx.txt materials / 100
    125: {24: 5000, 66: 900, 35: 500},   # srx.txt materials / 100
    118: {7: 800, 57: 1200, 59: 400},   # srx.txt materials / 100
    165: {7: 400, 93: 10, 59: 400},   # srx.txt materials / 100
}

# ── Economy revamp (owner 2026-10-23): every number comes from economy.py ─────────
# (srs.txt mine rates at 100 % quality, costs.txt mine costs, srx.txt factories, derived prices).
# The tables above are the pre-revamp values, kept for reference only.
import economy
import names
MINE_TYPES = {mid: {"res": m[0], "rate": m[2], "cost": economy.mine_base_cost(mid), "lvl": m[1]}
              for mid, m in economy.MINES.items()}
FACTORY_TYPES = {fid: {"name": f[0], "produces": f[1], "lvl": f[2], **economy.batch(fid),
                       "cost": economy.factory_build(fid)["credits"]}
                 for fid, f in economy.FACTORIES.items()}
FACTORY_BUILD_RESOURCES = {fid: economy.factory_build(fid)["res"] for fid in economy.FACTORIES}

# Rarity tiers for scanner
_SCAN_COMMON   = [4, 5, 9, 21, 54]
_SCAN_UNCOMMON = [16, 17, 19, 27]
_SCAN_RARE     = [11, 50, 89, 18]
_SCAN_VERYRARE = [82, 168]
_SCAN_ALL      = _SCAN_COMMON + _SCAN_UNCOMMON + _SCAN_RARE + _SCAN_VERYRARE
_SCAN_WEIGHTS  = [10]*5 + [5]*4 + [2]*4 + [1]*2

WAREHOUSE_BASE_CAPACITY = 5000


MINE_UPGRADE_COSTS = {2: 5000, 3: 15000, 4: 40000, 5: 100000}
MAX_MINE_LEVEL = 5

# Special buildings: item_id → name, max_level, and per-level upgrade costs
# costs[i] = cost to upgrade to level i+1 (so index 0 = build level 1)
# Each cost entry: {"credits": N, "res": {item_id: qty, ...}}
SPECIAL_BUILDINGS = {
    116: {
        "name": "Tech Center",
        "max_level": 10,
        "desc": "Your scanning base. It decides how far your scans reach and how good the resources are that they can reveal.",
        "costs": [
            {"credits": 200000,      "res": {24: 100}},
            {"credits": 500000,      "res": {24: 500,  7: 100}},
            {"credits": 1500000,     "res": {30: 500}},
            {"credits": 4000000,     "res": {30: 1000, 32: 100}},
            {"credits": 10000000,    "res": {30: 2000, 32: 500}},
            {"credits": 25000000,    "res": {30: 5000, 32: 1000, 79: 100}},
            {"credits": 60000000,    "res": {30: 10000, 79: 5000}},
            {"credits": 150000000,   "res": {79: 20000, 81: 100}},
            {"credits": 350000000,   "res": {79: 50000, 81: 500}},
            {"credits": 800000000,   "res": {79: 100000, 81: 1000}},
        ],
    },
    119: {
        "name": "Drone Research",
        "max_level": 10,
        "desc": "Lets you scan and collect cargo with drones far from where you are, and at the top level build mines remotely.",
        "costs": [
            {"credits": 1000000,     "res": {66: 500,    117: 2}},
            {"credits": 5000000,     "res": {66: 2000,   117: 8}},
            {"credits": 20000000,    "res": {66: 8000,   117: 25}},
            {"credits": 80000000,    "res": {66: 30000,  117: 75}},
            {"credits": 300000000,   "res": {66: 100000, 117: 200}},
            {"credits": 1000000000,  "res": {66: 300000, 117: 500,  79: 1000}},
            {"credits": 3000000000,  "res": {66: 800000, 117: 1200, 79: 4000}},
            {"credits": 8000000000,  "res": {81: 500,    117: 2500, 79: 15000}},
            {"credits": 20000000000, "res": {81: 2000,   117: 5000, 79: 50000}},
            {"credits": 50000000000, "res": {81: 5000,   117: 10000,79: 150000}},
        ],
    },
    65: {
        "name": "Museum",
        "max_level": 10,
        "desc": "Studies the objects you find. It lets you pick up cargo and artifacts from further away, adds to every crate you open and unlocks rarer objects.",
        "costs": [
            {"credits": 500000,    "res": {41: 200,   40: 100}},
            {"credits": 2000000,   "res": {41: 800,   40: 400,  55: 200}},
            {"credits": 8000000,   "res": {41: 2000,  40: 1000, 55: 500}},
            {"credits": 30000000,  "res": {41: 6000,  40: 3000, 55: 1500}},
            {"credits": 100000000, "res": {41: 15000, 40: 7000, 55: 4000}},
            {"credits": 300000000, "res": {41: 40000, 40: 18000, 55: 10000}},
            {"credits": 800000000, "res": {41: 100000, 40: 45000, 55: 25000, 79: 500}},
            {"credits": 2000000000,"res": {41: 250000, 40: 110000, 55: 60000, 79: 2000}},
            {"credits": 5000000000,"res": {41: 600000, 40: 270000, 55: 150000, 79: 6000}},
            {"credits": 12000000000,"res":{41: 1500000, 40: 650000, 55: 350000, 79: 15000}},
        ],
    },
    71: {
        "name": "Hospital",
        "max_level": 10,
        "desc": "Keeps your miners healthy, so diseases break out less often and spread less between your mines.",
        "costs": [
            {"credits": 500000,    "res": {24: 2000,   75: 50}},
            {"credits": 2000000,   "res": {24: 8000,   75: 200,  35: 500}},
            {"credits": 8000000,   "res": {24: 25000,  75: 500,  35: 2000}},
            {"credits": 30000000,  "res": {24: 60000,  75: 1500, 35: 8000}},
            {"credits": 100000000, "res": {24: 150000, 75: 5000, 35: 30000}},
            {"credits": 300000000, "res": {24: 400000, 75: 12000, 35: 75000}},
            {"credits": 800000000, "res": {24: 1000000, 75: 30000, 35: 180000, 79: 500}},
            {"credits": 2000000000,"res": {24: 2500000, 75: 75000, 35: 450000, 79: 2000}},
            {"credits": 5000000000,"res": {24: 6000000, 75: 180000, 35: 1000000, 79: 6000}},
            {"credits": 12000000000,"res":{24: 15000000, 75: 450000, 35: 2500000, 79: 15000}},
        ],
    },
    58: {
        "name": "Recycling Plant",
        "max_level": 10,
        "desc": "Turns found objects you don't need into useful resources.",
        "costs": [
            {"credits": 300000,    "res": {70: 1000,   77: 500,   115: 500}},
            {"credits": 1500000,   "res": {70: 5000,   77: 2000,  115: 2000}},
            {"credits": 6000000,   "res": {70: 15000,  77: 6000,  115: 6000}},
            {"credits": 20000000,  "res": {70: 40000,  77: 15000, 115: 15000}},
            {"credits": 60000000,  "res": {70: 100000, 77: 40000, 115: 40000}},
            {"credits": 180000000, "res": {70: 250000, 77: 100000, 115: 100000}},
            {"credits": 500000000, "res": {70: 600000, 77: 240000, 115: 240000, 79: 200}},
            {"credits": 1300000000,"res": {70: 1500000, 77: 600000, 115: 600000, 79: 800}},
            {"credits": 3500000000,"res": {70: 3500000, 77: 1400000, 115: 1400000, 79: 2500}},
            {"credits": 9000000000,"res": {70: 8000000, 77: 3200000, 115: 3200000, 79: 7000}},
        ],
    },
    127: {
        "name": "Seismology Centre",
        "max_level": 10,
        "desc": "Monitors earthquakes and reinforces your mines, so quakes damage them less.",
        "costs": [
            {"credits": 1000000,    "res": {66: 1000,   93: 500,   79: 100}},
            {"credits": 5000000,    "res": {66: 5000,   93: 2000,  79: 500}},
            {"credits": 20000000,   "res": {66: 15000,  93: 6000,  79: 2000}},
            {"credits": 80000000,   "res": {66: 40000,  93: 15000, 79: 6000}},
            {"credits": 300000000,  "res": {66: 100000, 93: 40000, 79: 20000}},
            {"credits": 1000000000, "res": {66: 250000, 93: 100000, 79: 50000}},
            {"credits": 3000000000, "res": {66: 600000, 93: 250000, 79: 125000, 81: 200}},
            {"credits": 8000000000, "res": {66: 1500000, 93: 600000, 79: 300000, 81: 800}},
            {"credits": 20000000000,"res": {66: 3500000, 93: 1400000, 79: 700000, 81: 2500}},
            {"credits": 50000000000,"res": {66: 8000000, 93: 3200000, 79: 1600000, 81: 6000}},
        ],
    },
    126: {
        "name": "Fire Station",
        "max_level": 10,
        "desc": "Protects your factories: fires break out less often and are put out sooner.",
        "costs": [
            {"credits": 1000000,    "res": {124: 500,   117: 50,   97: 500}},
            {"credits": 5000000,    "res": {124: 2000,  117: 100,  97: 2000}},
            {"credits": 20000000,   "res": {124: 6000,  117: 250,  97: 5000}},
            {"credits": 80000000,   "res": {124: 15000, 117: 500,  97: 10000}},
            {"credits": 300000000,  "res": {124: 40000, 117: 1000, 97: 25000}},
            {"credits": 1000000000, "res": {124: 100000, 117: 2500, 97: 60000}},
            {"credits": 3000000000, "res": {124: 250000, 117: 6000, 97: 150000, 32: 500}},
            {"credits": 8000000000, "res": {124: 600000, 117: 14000, 97: 350000, 32: 2000}},
            {"credits": 20000000000,"res": {124: 1400000, 117: 33000, 97: 800000, 32: 6000}},
            {"credits": 50000000000,"res": {124: 3200000, 117: 75000, 97: 1800000, 32: 15000}},
        ],
    },
    123: {
        "name": "Haulage Firm",
        "max_level": 10,
        "desc": "Your transport company. It lowers the market transport tax, extends the range of your trucks and unlocks Stacked Cargo Rain and truck collection.",
        "costs": [
            {"credits": 200000,      "res": {7: 500,   2: 1000}},
            {"credits": 600000,      "res": {7: 2000,  2: 4000}},
            {"credits": 2000000,     "res": {7: 5000,  20: 2000}},
            {"credits": 5000000,     "res": {7: 10000, 20: 5000,  24: 500}},
            {"credits": 12000000,    "res": {7: 20000, 20: 10000, 24: 2000}},
            {"credits": 30000000,    "res": {30: 5000, 24: 5000,  36: 1000}},
            {"credits": 70000000,    "res": {30: 12000, 36: 3000, 32: 500}},
            {"credits": 160000000,   "res": {30: 25000, 36: 8000, 32: 2000}},
            {"credits": 350000000,   "res": {30: 50000, 79: 5000, 32: 5000}},
            {"credits": 750000000,   "res": {30: 100000, 79: 15000, 81: 500}},
        ],
    },
    86: {
        "name": "Mafia HQ",
        "max_level": 10,
        "desc": "Hires criminals to attack other players' mines. A won attack brings you part of the mine's output.",
        "costs": [
            {"credits": 2000000,    "res": {24: 500,   20: 500,   70: 500}},
            {"credits": 8000000,    "res": {24: 2000,  20: 2000,  70: 2000}},
            {"credits": 25000000,   "res": {24: 6000,  70: 6000,  87: 50}},
            {"credits": 70000000,   "res": {70: 15000, 87: 200,   79: 100}},
            {"credits": 150000000,  "res": {70: 30000, 87: 500,   79: 500}},
            {"credits": 400000000,  "res": {70: 75000, 87: 1200,  79: 1500}},
            {"credits": 1000000000, "res": {70: 180000, 87: 3000, 79: 4000, 81: 50}},
            {"credits": 2500000000, "res": {70: 430000, 87: 7000, 79: 10000, 81: 200}},
            {"credits": 6000000000, "res": {70: 1000000, 87: 16000, 79: 24000, 81: 600}},
            {"credits": 15000000000,"res": {70: 2400000, 87: 38000, 79: 55000, 81: 1500}},
        ],
    },
    72: {
        "name": "Law Firm",
        "max_level": 10,
        "desc": "Your lawyers soften the consequences of incidents: mine diseases, earthquake damage and factory fires.",
        "costs": [
            {"credits": 500000,    "res": {59: 200,   32: 100,  57: 50}},
            {"credits": 2000000,   "res": {59: 800,   32: 300,  57: 200}},
            {"credits": 6000000,   "res": {59: 2000,  32: 800,  57: 500}},
            {"credits": 15000000,  "res": {59: 4000,  32: 2000, 57: 1200}},
            {"credits": 30000000,  "res": {59: 8000,  32: 4000, 57: 2500}},
            {"credits": 70000000,  "res": {59: 20000, 32: 10000, 57: 6000}},
            {"credits": 160000000, "res": {59: 50000, 32: 25000, 57: 15000, 79: 100}},
            {"credits": 360000000, "res": {59: 120000, 32: 60000, 57: 36000, 79: 400}},
            {"credits": 800000000, "res": {59: 280000, 32: 140000, 57: 84000, 79: 1200}},
            {"credits": 1800000000,"res": {59: 650000, 32: 325000, 57: 195000, 79: 3500}},
        ],
    },
    121: {
        "name": "Service Center",
        "max_level": 10,
        "desc": "Rewards you for maintaining other players' mines and can add bonus crates to the reward.",
        "costs": [
            {"credits": 1000000,   "res": {93: 20,   35: 50,   36: 15}},
            {"credits": 4000000,   "res": {93: 80,   35: 200,  36: 60}},
            {"credits": 10000000,  "res": {93: 200,  35: 500,  36: 150}},
            {"credits": 20000000,  "res": {93: 400,  35: 1000, 36: 300}},
            {"credits": 40000000,  "res": {93: 800,  35: 2000, 36: 600}},
            {"credits": 90000000,  "res": {93: 1800, 35: 4500, 36: 1350}},
            {"credits": 200000000, "res": {93: 4000, 35: 10000, 36: 3000, 79: 50}},
            {"credits": 450000000, "res": {93: 9000, 35: 22500, 36: 6750, 79: 200}},
            {"credits": 1000000000,"res": {93: 20000, 35: 50000, 36: 15000, 79: 600}},
            {"credits": 2200000000,"res": {93: 44000, 35: 110000, 36: 33000, 79: 1800}},
        ],
    },
    122: {
        "name": "HR Department",
        "max_level": 10,
        "desc": "Keeps your workforce content, so strikes break out less often and cost you less.",
        "costs": [
            {"credits": 1000000,   "res": {36: 50,    98: 1,   66: 50}},
            {"credits": 4000000,   "res": {36: 200,   98: 2,   66: 200}},
            {"credits": 10000000,  "res": {36: 500,   98: 5,   66: 500}},
            {"credits": 20000000,  "res": {36: 1000,  98: 15,  66: 1000}},
            {"credits": 40000000,  "res": {36: 2000,  98: 40,  66: 2000}},
            {"credits": 90000000,  "res": {36: 4500,  98: 90,  66: 4500}},
            {"credits": 200000000, "res": {36: 10000, 98: 200, 66: 10000, 79: 50}},
            {"credits": 450000000, "res": {36: 22000, 98: 450, 66: 22000, 79: 200}},
            {"credits": 1000000000,"res": {36: 48000, 98: 1000, 66: 48000, 79: 600}},
            {"credits": 2200000000,"res": {36: 105000, 98: 2200, 66: 105000, 79: 1800}},
        ],
    },
    164: {
        "name": "Archaeological Center",
        "max_level": 10,
        "desc": "Unlocks the artifact detector and the recovery of ancient artifacts by your archaeologists.",
        "costs": [
            {"credits": 2000000,    "res": {166: 1,   124: 10,   79: 40}},
            {"credits": 8000000,    "res": {166: 2,   124: 30,   79: 150}},
            {"credits": 20000000,   "res": {166: 3,   124: 80,   79: 400}},
            {"credits": 50000000,   "res": {166: 5,   124: 200,  79: 1000}},
            {"credits": 100000000,  "res": {166: 10,  124: 500,  79: 2500}},
            {"credits": 250000000,  "res": {166: 20,  124: 1200, 79: 6000}},
            {"credits": 600000000,  "res": {166: 40,  124: 2800, 79: 14000, 81: 20}},
            {"credits": 1500000000, "res": {166: 80,  124: 6500, 79: 32000, 81: 80}},
            {"credits": 3500000000, "res": {166: 160, 124: 15000, 79: 75000, 81: 250}},
            {"credits": 8000000000, "res": {166: 320, 124: 35000, 79: 175000, 81: 750}},
        ],
    },
    61: {
        "name": "Casino",
        "max_level": 10,
        "desc": "Your own slot machine with free daily spins and a jackpot that grows with every spin.",
        "costs": [
            {"credits": 2500000,    "res": {7: 2000,    40: 1000,   55: 500}},
            {"credits": 7500000,    "res": {7: 5000,    40: 3000,   55: 1500}},
            {"credits": 20000000,   "res": {7: 10000,   40: 6000,   55: 3000}},
            {"credits": 50000000,   "res": {7: 20000,   40: 12000,  55: 6000}},
            {"credits": 120000000,  "res": {7: 40000,   40: 25000,  55: 12000}},
            {"credits": 300000000,  "res": {7: 80000,   40: 50000,  55: 25000}},
            {"credits": 700000000,  "res": {7: 150000,  40: 100000, 55: 50000}},
            {"credits": 1500000000, "res": {7: 300000,  40: 200000, 55: 100000}},
            {"credits": 3500000000, "res": {7: 600000,  40: 400000, 55: 200000}},
            {"credits": 8000000000, "res": {7: 1000000, 40: 800000, 55: 400000}},
        ],
    },
}

# rebalance 2026-10-23: special building costs come from economy.special_costs (the tables above are
# the original values, kept for reference)
for _sid in SPECIAL_BUILDINGS:
    SPECIAL_BUILDINGS[_sid]["costs"] = economy.special_costs(_sid)

# Drone scan range in metres per Drone Research level (levels 1–10)
# Drone scan / remote build range by Drone Research level (owner 2026-10-20: at most 10 km)
DRONE_SCAN_RANGES = [500, 1000, 1500, 2000, 3000, 4000, 5000, 6500, 8000, 10000]

# ── Tech Center configuration (single source of truth) ─────────────────────────
# radius = scan area radius metres; accuracy = prediction fidelity %;
# max_quality = hard cap on displayed quality at this level.
TC_CONFIG = [
    {"radius": 150,  "accuracy":   9, "max_quality":  27},  # 0
    {"radius": 200,  "accuracy":  18, "max_quality":  34},  # 1
    {"radius": 250,  "accuracy":  27, "max_quality":  42},  # 2
    {"radius": 300,  "accuracy":  36, "max_quality":  49},  # 3
    {"radius": 350,  "accuracy":  45, "max_quality":  56},  # 4
    {"radius": 400,  "accuracy":  54, "max_quality":  63},  # 5
    {"radius": 500,  "accuracy":  63, "max_quality":  71},  # 6
    {"radius": 600,  "accuracy":  72, "max_quality":  79},  # 7
    {"radius": 750,  "accuracy":  81, "max_quality":  85},  # 8
    {"radius": 900,  "accuracy":  90, "max_quality":  93},  # 9
    {"radius": 1125, "accuracy": 100, "max_quality": 100},  # 10
]
TC_SCAN_RADIUS = [c["radius"] for c in TC_CONFIG]  # backward-compat alias

# Fixed drone scan range (uses one Scan Drone item from inventory)
DRONE_SCAN_RANGE_M = 5000
DRONE_OVERRIDE = False

# Prospect tokens: one token per scan (single-use). keyed by token UUID.
# One construction consumes the token; the next mine requires a fresh scan.
_scan_tokens: dict = {}       # tok_uuid → {hid, lat, lng, item_ids, expires}
_player_tokens: dict = {}     # hid → current tok_uuid (replaced on each new scan)

# ── Multi-scale noise resource fields (server-side only, never sent to client) ──
# Per-resource noise configuration.
# broad_wl/med_wl/fine_wl = noise wavelength in km (larger = smoother, wider blobs).
# w_broad/w_med/w_fine    = blend weights (must sum to 1).
# warp                    = domain-warp strength in km (higher = more organic shapes).
# coverage                = approx fraction of map area that has quality > 0.
# richness                = skew toward high quality (0 = linear, 1 = more highs).
# rich_chance             = probability that a region gets an exceptional core.
# rich_wl                 = spatial wavelength of rich cores in km.
# q_min/q_max             = quality range 0–1 (multiplied by 100 for final value).
# bg                      = background quality present everywhere (common resources only).
_NOISE_RES_CONFIG: dict = {
    # coverage: exact fraction of map with quality > 0 (percentile-based threshold).
    # richness: ease-out exponent (1+R); higher = more pixels pushed to 95-100%.
    # pct_sat: percentile of active pixels that maps to q_max=100% (default 98.0).
    # env_*: optional large-scale envelope that redistributes quality into large contiguous
    #        deposits without changing the total coverage fraction (percentile threshold
    #        ensures coverage stays the same; only the spatial arrangement changes).
    #        alpha=1.0 = gentle modulation (preserves scatter); 2.0 = strongly isolated deposits.

    # Common — large patches; gentle envelopes create broad high-quality regions (11–15 km).
    4:   {"seed":  0, "broad_wl": 4.0, "med_wl": 0.80, "fine_wl": 0.12, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.30, "coverage": 0.65, "richness": 1.0, "rich_chance": 0.30, "rich_wl": 0.10, "q_min": 0.10, "q_max": 1.00, "bg":  8,
          "env_seed": 128,  "env_broad_wl": 15.0, "env_med_wl": 6.0, "env_fine_wl": 1.5, "env_w_broad": 0.70, "env_w_med": 0.25, "env_w_fine": 0.05, "env_alpha": 1.0},   # Clay      unlock 1
    54:  {"seed":  1, "broad_wl": 3.5, "med_wl": 0.70, "fine_wl": 0.10, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.30, "coverage": 0.55, "richness": 1.0, "rich_chance": 0.25, "rich_wl": 0.10, "q_min": 0.10, "q_max": 1.00, "bg":  5,
          "env_seed": 478,  "env_broad_wl": 14.0, "env_med_wl": 5.5, "env_fine_wl": 1.4, "env_w_broad": 0.70, "env_w_med": 0.25, "env_w_fine": 0.05, "env_alpha": 1.0},   # Sand      unlock 7
    5:   {"seed":  2, "broad_wl": 3.0, "med_wl": 0.60, "fine_wl": 0.09, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.30, "coverage": 0.50, "richness": 1.0, "rich_chance": 0.25, "rich_wl": 0.09, "q_min": 0.10, "q_max": 1.00, "bg":  5,
          "env_seed": 135,  "env_broad_wl": 13.0, "env_med_wl": 5.0, "env_fine_wl": 1.3, "env_w_broad": 0.70, "env_w_med": 0.25, "env_w_fine": 0.05, "env_alpha": 1.0},   # Gravel    unlock 3
    21:  {"seed":  3, "broad_wl": 2.5, "med_wl": 0.50, "fine_wl": 0.08, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.40, "coverage": 0.45, "richness": 1.0, "rich_chance": 0.22, "rich_wl": 0.09, "q_min": 0.10, "q_max": 1.00, "bg":  3,
          "env_seed": 247,  "env_broad_wl": 12.0, "env_med_wl": 5.0, "env_fine_wl": 1.2, "env_w_broad": 0.72, "env_w_med": 0.23, "env_w_fine": 0.05, "env_alpha": 1.0},   # Limestone unlock 2
    9:   {"seed":  4, "broad_wl": 2.2, "med_wl": 0.50, "fine_wl": 0.07, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.40, "coverage": 0.40, "richness": 1.0, "rich_chance": 0.22, "rich_wl": 0.08, "q_min": 0.10, "q_max": 1.00, "bg":  2,
          "env_seed": 163,  "env_broad_wl": 11.0, "env_med_wl": 4.5, "env_fine_wl": 1.1, "env_w_broad": 0.72, "env_w_med": 0.23, "env_w_fine": 0.05, "env_alpha": 1.0},   # Coal      unlock 4
    # Uncommon — moderate coverage; envelopes create clear 1–2 km deposit regions.
    17:  {"seed":  5, "broad_wl": 2.0, "med_wl": 0.50, "fine_wl": 0.07, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.33, "richness": 1.0, "rich_chance": 0.20, "rich_wl": 0.08, "q_min": 0.10, "q_max": 1.00, "bg":  0,
          "env_seed": 219,  "env_broad_wl": 10.0, "env_med_wl": 4.0, "env_fine_wl": 1.0, "env_w_broad": 0.78, "env_w_med": 0.18, "env_w_fine": 0.04, "env_alpha": 1.3},   # Iron      unlock 4
    11:  {"seed":  6, "broad_wl": 1.8, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.35, "richness": 1.0, "rich_chance": 0.20, "rich_wl": 0.07, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 177,  "env_broad_wl": 10.0, "env_med_wl": 4.0, "env_fine_wl": 1.0, "env_w_broad": 0.78, "env_w_med": 0.18, "env_w_fine": 0.04, "env_alpha": 1.3},   # Oil       unlock 1
    16:  {"seed":  7, "broad_wl": 1.8, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.24, "richness": 1.0, "rich_chance": 0.18, "rich_wl": 0.07, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 212,  "env_broad_wl":  9.0, "env_med_wl": 3.5, "env_fine_wl": 0.9, "env_w_broad": 0.80, "env_w_med": 0.17, "env_w_fine": 0.03, "env_alpha": 1.3},   # Bauxite   unlock 11
    19:  {"seed":  8, "broad_wl": 1.6, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.14, "richness": 1.0, "rich_chance": 0.18, "rich_wl": 0.07, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 233,  "env_broad_wl":  9.0, "env_med_wl": 3.5, "env_fine_wl": 0.9, "env_w_broad": 0.80, "env_w_med": 0.17, "env_w_fine": 0.03, "env_alpha": 1.3},   # Silver    unlock 33
    27:  {"seed":  9, "broad_wl": 1.4, "med_wl": 0.30, "fine_wl": 0.05, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.60, "coverage": 0.25, "richness": 1.0, "rich_chance": 0.16, "rich_wl": 0.06, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 289,  "env_broad_wl":  9.5, "env_med_wl": 3.8, "env_fine_wl": 1.0, "env_w_broad": 0.78, "env_w_med": 0.18, "env_w_fine": 0.04, "env_alpha": 1.3},   # Copper    unlock 9
    # Rare — smaller pockets; envelopes create few, isolated high-quality deposits (750–1500 m).
    18:  {"seed": 10, "broad_wl": 1.2, "med_wl": 0.30, "fine_wl": 0.05, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.60, "coverage": 0.11, "richness": 1.2, "rich_chance": 0.14, "rich_wl": 0.06, "q_min": 0.20, "q_max": 1.00, "bg":  0,
          "env_seed": 226,  "env_broad_wl":  8.0, "env_med_wl": 3.2, "env_fine_wl": 0.8, "env_w_broad": 0.85, "env_w_med": 0.12, "env_w_fine": 0.03, "env_alpha": 1.7},   # Gold      unlock 38
    89:  {"seed": 11, "broad_wl": 1.2, "med_wl": 0.30, "fine_wl": 0.05, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.60, "coverage": 0.20, "richness": 1.2, "rich_chance": 0.14, "rich_wl": 0.06, "q_min": 0.20, "q_max": 1.00, "bg":  0,
          "env_seed": 723,  "env_broad_wl":  8.0, "env_med_wl": 3.2, "env_fine_wl": 0.8, "env_w_broad": 0.85, "env_w_med": 0.12, "env_w_fine": 0.03, "env_alpha": 1.7},   # Lithium   unlock 15
    168: {"seed": 12, "broad_wl": 2.0, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.60, "w_med": 0.30, "w_fine": 0.10, "warp": 0.70, "coverage": 0.03, "richness": 1.0, "rich_chance": 0.12, "rich_wl": 0.06, "q_min": 0.10, "q_max": 1.00, "pct_sat": 99.5, "bg":  0,
          "env_seed": 1276, "env_broad_wl":  8.5, "env_med_wl": 3.5, "env_fine_wl": 0.8, "env_w_broad": 0.87, "env_w_med": 0.11, "env_w_fine": 0.02, "env_alpha": 1.7},   # Wolframite unlock 50
    50:  {"seed": 13, "broad_wl": 1.0, "med_wl": 0.25, "fine_wl": 0.04, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.70, "coverage": 0.17, "richness": 1.2, "rich_chance": 0.12, "rich_wl": 0.06, "q_min": 0.20, "q_max": 1.00, "bg":  0,
          "env_seed": 450,  "env_broad_wl":  8.0, "env_med_wl": 3.2, "env_fine_wl": 0.8, "env_w_broad": 0.85, "env_w_med": 0.12, "env_w_fine": 0.03, "env_alpha": 1.7},   # Ilmenite  unlock 20
    # Extremely rare — primary×envelope² produces a few large (500-1500m) deposits among small scattered ones.
    # env_seed generates a separate large-scale (8km) envelope; multiplying concentrates deposits.
    82:  {"seed": 14, "broad_wl": 6.0, "med_wl": 1.5, "fine_wl": 0.3, "w_broad": 0.85, "w_med": 0.12, "w_fine": 0.03,
          "warp": 0.80, "coverage": 0.03, "richness": 0.8, "rich_chance": 0.10, "rich_wl": 0.05,
          "q_min": 0.08, "q_max": 1.00, "pct_sat": 99.5, "bg": 0,
          "env_seed": 888, "env_broad_wl": 8.0, "env_med_wl": 4.0, "env_fine_wl": 1.0,
          "env_w_broad": 0.92, "env_w_med": 0.07, "env_w_fine": 0.01, "env_alpha": 2.0},  # Diamond unlock 48
}
_RES_ORDER = list(_NOISE_RES_CONFIG.keys())

# ── Master resource field (server-side, tileable, 4m scan resolution) ────────────
# Coordinate system: equirectangular
#   world_x_m = lng * 111320.0
#   world_y_m = lat * 111320.0
# Wrapping uses a tilted geographic lattice so resources repeat at the same
# period as the original RESOURCES GPS MMO.  See _LATTICE_* constants.
MASTER_N = 5000         # samples per dimension (one unit-cell of the lattice)
MASTER_M = 20000.0      # kept for reference; wrapping now uses lattice, not this
MASTER_SAMPLE_M = 4.0   # metres per sample (scan resolution; field pixel ≈28 m)

# ── Geographic repetition lattice ────────────────────────────────────────────────
# Resource clouds repeat at integer combinations of A and B (in degrees).
# Vectors measured from RESOURCES GPS MMO spatial analysis.
_LATTICE_A_LAT =  1.09813   # Δlat° per step along A
_LATTICE_A_LNG =  0.58704   # Δlng° per step along A
_LATTICE_B_LAT = -0.58703   # Δlat° per step along B
_LATTICE_B_LNG =  1.21451   # Δlng° per step along B
# det(M) where M columns are A and B: det = A_lat*B_lng - B_lat*A_lng
_LATTICE_DET = _LATTICE_A_LAT * _LATTICE_B_LNG - _LATTICE_B_LAT * _LATTICE_A_LNG
# Inverse coefficients scaled to world_x_m / world_y_m (÷111320 absorbed here)
# u = IU_Y*world_y_m + IU_X*world_x_m ;  v = IV_Y*world_y_m + IV_X*world_x_m
_LATTICE_IU_Y = ( _LATTICE_B_LNG) / (_LATTICE_DET * 111320.0)
_LATTICE_IU_X = (-_LATTICE_B_LAT) / (_LATTICE_DET * 111320.0)
_LATTICE_IV_Y = (-_LATTICE_A_LNG) / (_LATTICE_DET * 111320.0)
_LATTICE_IV_X = ( _LATTICE_A_LAT) / (_LATTICE_DET * 111320.0)

_master_fields: dict = {}        # mine_id → uint8 ndarray 5000×5000
_master_lock = threading.Lock()  # one field generated at a time

# Heatmap result cache: (cx_snap, cy_snap, tc_level) → (timestamp, result_dict)
# Quality fields are deterministic — cache for 30 min, evict oldest when full.
_HEATMAP_CACHE: dict = {}
_HEATMAP_CACHE_TTL = 1800.0   # seconds
_HEATMAP_CACHE_MAX = 50       # max entries to bound memory

# Heatmap colour stops: [q_threshold, R, G, B] — default thermal scheme
_HEAT_STOPS = [
    (0,   0,   0,  80),
    (10,  0,  40, 180),
    (25,  0, 180, 200),
    (45,  0, 220,  80),
    (62, 220, 220,   0),
    (78, 230,  90,   0),
    (90, 200,  20,   0),
    (100,120,   0,   0),
]

def _heat_pixel(q: int):
    """Return (R,G,B,A) for quality q 0-100 using thermal scheme."""
    if q <= 0:
        return (0, 0, 0, 0)
    alpha = min(255, round(q * 2.55))  # q=0→0, q=100→255, no floor
    stops = _HEAT_STOPS
    for i in range(1, len(stops)):
        if q <= stops[i][0] or i == len(stops) - 1:
            q0, r0, g0, b0 = stops[i-1]
            q1, r1, g1, b1 = stops[i]
            t = (q - q0) / (q1 - q0) if q1 > q0 else 1.0
            return (
                max(0, min(255, round(r0 + (r1-r0)*t))),
                max(0, min(255, round(g0 + (g1-g0)*t))),
                max(0, min(255, round(b0 + (b1-b0)*t))),
                alpha,
            )
    q0, r0, g0, b0 = stops[-1]
    return (r0, g0, b0, alpha)

def _encode_png_rgba(rgba_bytes: bytes, width: int, height: int) -> bytes:
    """Encode raw RGBA bytes as PNG using stdlib only."""
    def _chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    row_sz = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba_bytes[y*row_sz:(y+1)*row_sz]
    return (b'\x89PNG\r\n\x1a\n'
            + _chunk(b'IHDR', ihdr)
            + _chunk(b'IDAT', zlib.compress(bytes(raw), 1))
            + _chunk(b'IEND', b''))

def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlng/2)**2
    return 6371000.0 * 2.0 * math.asin(math.sqrt(min(1.0, a)))

# ── Vectorised gradient noise (numpy, no C extensions required) ─────────────────

try:
    import numpy as np
    _HAS_NP = True
except ImportError:
    _HAS_NP = False

def _int_hash(ix, iy, seed: int):
    """Deterministic integer hash for gradient noise."""
    h = ((ix * 73856093) ^ (iy * 19349663) ^ (seed * 83492791)) & 0x7FFFFFFF
    h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0x7FFFFFFF
    h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0x7FFFFFFF
    return h

def _grad(h, dx, dy):
    """8-direction gradient."""
    h8 = h & 7
    gx = 1.0 if h8 in (0, 1, 2, 3) else -1.0
    gy = 1.0 if h8 in (0, 1, 4, 5) else -1.0
    return gx * dx + gy * dy

def _fade_s(t): return t * t * t * (t * (t * 6 - 15) + 10)

def _smooth_noise(x: float, y: float, seed: int) -> float:
    """Single-point gradient noise → [-1, 1]."""
    ix, iy = int(math.floor(x)), int(math.floor(y))
    fx, fy = x - ix, y - iy
    u, v = _fade_s(fx), _fade_s(fy)
    n00 = _grad(_int_hash(ix,   iy,   seed), fx,   fy)
    n10 = _grad(_int_hash(ix+1, iy,   seed), fx-1, fy)
    n01 = _grad(_int_hash(ix,   iy+1, seed), fx,   fy-1)
    n11 = _grad(_int_hash(ix+1, iy+1, seed), fx-1, fy-1)
    return (n00*(1-u) + n10*u)*(1-v) + (n01*(1-u) + n11*u)*v

def _fbm(x: float, y: float, seed: int, octaves: int = 4,
         persistence: float = 0.5, lacunarity: float = 2.0) -> float:
    val, amp, freq, mx = 0.0, 1.0, 1.0, 0.0
    for i in range(octaves):
        val += _smooth_noise(x * freq, y * freq, seed + i * 31337) * amp
        mx  += amp; amp *= persistence; freq *= lacunarity
    return val / mx

if _HAS_NP:
    def _smooth_noise_arr(xs, ys, seed: int):
        ix = np.floor(xs).astype(np.int64)
        iy = np.floor(ys).astype(np.int64)
        fx, fy = xs - ix, ys - iy
        def _h(bx, by):
            h = ((bx * 73856093) ^ (by * 19349663) ^ int(seed) * 83492791) & 0x7FFFFFFF
            h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0x7FFFFFFF
            return ((h ^ (h >> 16)) * 0x45d9f3b) & 0x7FFFFFFF
        def _g(h, dx, dy):
            gx = np.where((h & 4) == 0, 1.0, -1.0)  # matches scalar: h8 in {0,1,2,3}
            gy = np.where((h & 2) == 0, 1.0, -1.0)  # matches scalar: h8 in {0,1,4,5}
            return gx * dx + gy * dy
        def _f(t): return t*t*t*(t*(t*6-15)+10)
        u, v = _f(fx), _f(fy)
        n00 = _g(_h(ix,   iy  ), fx,   fy  )
        n10 = _g(_h(ix+1, iy  ), fx-1, fy  )
        n01 = _g(_h(ix,   iy+1), fx,   fy-1)
        n11 = _g(_h(ix+1, iy+1), fx-1, fy-1)
        return (n00*(1-u)+n10*u)*(1-v)+(n01*(1-u)+n11*u)*v

    def _fbm_arr(xs, ys, seed: int, octaves: int = 4,
                 persistence: float = 0.5, lacunarity: float = 2.0):
        val = np.zeros_like(xs, dtype=float)
        amp, freq, mx = 1.0, 1.0, 0.0
        for i in range(octaves):
            val += _smooth_noise_arr(xs*freq, ys*freq, seed + i*31337) * amp
            mx += amp; amp *= persistence; freq *= lacunarity
        return val / mx

    def _generate_master_field(mine_id: int) -> np.ndarray:
        """Generate 5000×5000 seamlessly-tileable master quality field (uint8 0-100).
        Uses FFT spectral synthesis — inherently periodic, so left/right and top/bottom
        edges connect without seams.  One deterministic field per resource."""
        cfg = _NOISE_RES_CONFIG[mine_id]
        N   = MASTER_N
        rng = np.random.default_rng(int(cfg["seed"]) * 104729 + mine_id * 31337 + 99991)

        # Frequency arrays for rfft2 output shape (N, N//2+1)
        fy  = np.fft.fftfreq(N)[:, None].astype(np.float32)
        fx  = np.fft.rfftfreq(N)[None, :].astype(np.float32)
        fr  = np.sqrt(fx*fx + fy*fy).astype(np.float32)   # cycles/sample

        # Gaussian band-pass peaks at each wavelength scale (log-frequency space)
        def _band(wl_km: float, w: float = 0.7) -> np.ndarray:
            f_pk = float(MASTER_SAMPLE_M) / (wl_km * 1000.0)
            safe = np.where(fr > 0.0, fr, f_pk)
            return np.exp(-0.5 * ((np.log(safe / f_pk)) / w) ** 2).astype(np.float32)

        power = (float(cfg["w_broad"]) * _band(cfg["broad_wl"]) +
                 float(cfg["w_med"])   * _band(cfg["med_wl"])   +
                 float(cfg["w_fine"])  * _band(cfg["fine_wl"]))
        power[0, 0] = 0.0  # zero mean

        # Random phase → complex spectrum → inverse FFT
        phase    = rng.uniform(-math.pi, math.pi, (N, N//2+1)).astype(np.float32)
        spectrum = (np.sqrt(power) * (np.cos(phase) + 1j*np.sin(phase))).astype(np.complex64)
        del phase, power, fr, fx, fy  # free before large IFFT output

        field = np.fft.irfft2(spectrum, s=(N, N)).astype(np.float32)
        del spectrum

        # Normalise to [0, 1]
        mn, mx = float(field.min()), float(field.max())
        if mx > mn:
            field -= mn
            field /= (mx - mn)

        # Optional large-scale envelope: multiplied with primary field to create large
        # deposits that are globally very sparse. Activated by "env_seed" in config.
        # Without this, low-coverage spectral fields only produce tiny isolated tips.
        if "env_seed" in cfg:
            env_seed  = int(cfg["env_seed"]) * 104729 + mine_id * 31337 + 99991
            env_rng   = np.random.default_rng(env_seed)
            env_fy    = np.fft.fftfreq(N)[:, None].astype(np.float32)
            env_fx    = np.fft.rfftfreq(N)[None, :].astype(np.float32)
            env_fr    = np.sqrt(env_fx*env_fx + env_fy*env_fy).astype(np.float32)
            def _env_band(wl_km: float, w: float = 0.5) -> np.ndarray:
                f_pk = float(MASTER_SAMPLE_M) / (wl_km * 1000.0)
                safe = np.where(env_fr > 0.0, env_fr, f_pk)
                return np.exp(-0.5 * ((np.log(safe / f_pk)) / w) ** 2).astype(np.float32)
            env_power = (float(cfg["env_w_broad"]) * _env_band(cfg["env_broad_wl"]) +
                         float(cfg["env_w_med"])   * _env_band(cfg["env_med_wl"])   +
                         float(cfg["env_w_fine"])  * _env_band(cfg["env_fine_wl"]))
            env_power[0, 0] = 0.0
            env_ph   = env_rng.uniform(-math.pi, math.pi, (N, N//2+1)).astype(np.float32)
            env_spec = (np.sqrt(env_power) * (np.cos(env_ph) + 1j*np.sin(env_ph))).astype(np.complex64)
            del env_ph, env_power, env_fy, env_fx, env_fr
            env_f    = np.fft.irfft2(env_spec, s=(N, N)).astype(np.float32)
            del env_spec
            e_mn, e_mx = float(env_f.min()), float(env_f.max())
            if e_mx > e_mn:
                env_f -= e_mn; env_f /= (e_mx - e_mn)
            field = field * np.power(env_f, float(cfg.get("env_alpha", 2.0)))
            del env_f, env_rng
            mn, mx = float(field.min()), float(field.max())
            if mx > mn:
                field -= mn; field /= (mx - mn)

        # Percentile-based threshold: guarantees exactly `coverage` fraction of pixels
        # are in the active (quality > 0) zone, regardless of the noise distribution.
        coverage  = float(cfg["coverage"])
        threshold = float(np.percentile(field.ravel(), (1.0 - coverage) * 100.0))

        # Smoothstep transition zone (anti-aliased deposit edges)
        active_span = float(field.max()) - threshold
        zone      = max(0.005, active_span * 0.08)
        bg        = float(cfg.get("bg", 0))
        blend_raw = np.clip((field - (threshold - zone)) / (2.0 * zone), 0.0, 1.0)
        blend     = blend_raw * blend_raw * (3.0 - 2.0 * blend_raw)

        # Quality scale: bottom of active range → q_min; pct_sat-th percentile → q_max.
        # pct_sat=98 (default) means top 2% reach 100%; higher values keep more pixels below max.
        flat     = field.ravel()
        active_v = flat[flat > threshold]
        pct_sat  = float(cfg.get("pct_sat", 98.0))
        p_high   = float(np.percentile(active_v, pct_sat)) if len(active_v) > 100 else float(field.max())
        scale    = max(p_high - threshold, 1e-6)
        t2       = np.clip((field - threshold) / scale, 0.0, 1.0)

        # Ease-out richness: 1-(1-t2)^(1+richness)
        # richness=0 → identity; richness=1 → quadratic; richness=2 → cubic push to 100.
        richness = float(cfg.get("richness", 0.0))
        if richness > 0.0:
            t2 = 1.0 - np.power(np.clip(1.0 - t2, 1e-9, 1.0), 1.0 + richness)

        active_q = float(cfg["q_min"])*100.0 + t2*(float(cfg["q_max"]) - float(cfg["q_min"]))*100.0
        q        = bg + blend * (active_q - bg)
        q        = np.clip(q, 0.0, 100.0)
        result   = np.clip(np.round(q), 0, 100).astype(np.uint8)
        del field, blend_raw, blend, t2, active_q, q, flat, active_v
        return result

    def get_master_field(mine_id: int) -> np.ndarray:
        """Return cached master field, generating it if needed (thread-safe)."""
        if mine_id in _master_fields:
            return _master_fields[mine_id]
        with _master_lock:
            if mine_id not in _master_fields:
                _master_fields[mine_id] = _generate_master_field(mine_id)
        return _master_fields[mine_id]

    def _sample_master_bilinear(field: np.ndarray,
                                world_x_m: np.ndarray,
                                world_y_m: np.ndarray) -> np.ndarray:
        """Bilinear sample of master field at arrays of world coordinates (metres).
        Wraps via the geographic lattice so resources repeat at the original game's period."""
        u = _LATTICE_IU_Y * world_y_m + _LATTICE_IU_X * world_x_m
        v = _LATTICE_IV_Y * world_y_m + _LATTICE_IV_X * world_x_m
        u_frac = u - np.floor(u)
        v_frac = v - np.floor(v)

        fi = u_frac * MASTER_N      # float column index in [0, MASTER_N)
        fj = v_frac * MASTER_N      # float row index
        i0 = np.floor(fi).astype(np.int32) % MASTER_N
        j0 = np.floor(fj).astype(np.int32) % MASTER_N
        i1 = (i0 + 1) % MASTER_N
        j1 = (j0 + 1) % MASTER_N
        tx = (fi - np.floor(fi)).astype(np.float32)
        ty = (fj - np.floor(fj)).astype(np.float32)

        v00 = field[j0, i0].astype(np.float32)
        v10 = field[j0, i1].astype(np.float32)
        v01 = field[j1, i0].astype(np.float32)
        v11 = field[j1, i1].astype(np.float32)
        return (v00*(1-tx)*(1-ty) + v10*tx*(1-ty)
              + v01*(1-tx)*ty    + v11*tx*ty)

    def _grid_to_png_b64(q_flat: np.ndarray, grid_n: int) -> str:
        """Render flat float32 quality array (0-100) as GRAYSCALE RGBA PNG.
        R=G=B=A=quality_byte (0-255). Client applies colour palette from this source.
        Grid row 0 = southernmost; image row 0 = northernmost (flipped)."""
        q_2d   = np.clip(np.round(q_flat.reshape(grid_n, grid_n)).astype(np.int32), 0, 100)
        q_2d   = q_2d[::-1, :]                           # flip: south→north
        q_byte = (q_2d * 255 // 100).astype(np.uint8)    # 0-100 → 0-255
        # q=0 pixels must be fully transparent
        alpha  = np.where(q_2d > 0, q_byte, np.uint8(0))
        rgba   = np.stack([q_byte, q_byte, q_byte, alpha], axis=2)
        png    = _encode_png_rgba(rgba.tobytes(), grid_n, grid_n)
        return base64.b64encode(png).decode()

def _lat_lng_to_km(lat: float, lng: float):
    x = lng * 111.320 * math.cos(math.radians(lat))
    y = lat * 111.320
    return x, y

def resource_quality_noise(lat: float, lng: float, mine_id: int) -> float:
    """True quality 0-100 sampled from the pre-generated master field.
    Uses the same bilinear interpolation as the heatmap so prospecting
    and scanner quality are always consistent."""
    if not _HAS_NP or mine_id not in _NOISE_RES_CONFIG:
        return 0.0
    field = get_master_field(mine_id)
    wx = np.array([lng * 111320.0])
    wy = np.array([lat * 111320.0])
    return float(_sample_master_bilinear(field, wx, wy)[0])

# Backward-compat alias used by mine_new
def resource_quality_at(lat: float, lng: float, mine_id: int) -> float:
    return resource_quality_noise(lat, lng, mine_id)

def predicted_quality(lat: float, lng: float, mine_id: int, tc_level: int) -> float:
    """Predicted quality: true quality + spatially-coherent accuracy error + max cap."""
    true_q = resource_quality_noise(lat, lng, mine_id)
    if true_q < 3.0: return 0.0
    tc       = TC_CONFIG[min(tc_level, 10)]
    accuracy = tc["accuracy"] / 100.0
    max_q    = tc["max_quality"]
    if accuracy < 1.0:
        x, y = _lat_lng_to_km(lat, lng)
        err_n = _smooth_noise(x/0.4, y/0.4, mine_id*17 + 50)  # spatial error field
        err_scale = (1.0 - accuracy) * 0.8
        predicted = true_q * (1.0 + err_n * err_scale)
    else:
        predicted = true_q
    return max(0.0, min(float(max_q), predicted))

def _scan_heatmap(lat: float, lng: float, tc_level: int) -> dict:
    """Sample pre-generated master fields on a physically-square 4 m raster.

    Each pixel is step_m × step_m physical metres in both E-W and N-S, so the
    circle mask is always a true circle in the PNG and the full scan radius is
    covered at any latitude.  The scan centre is snapped to the global 4 m
    physical grid so that overlapping scans share the same world-aligned sample
    points and reveal identical resource patterns."""
    if not _HAS_NP:
        return {}
    tc     = TC_CONFIG[min(tc_level, 10)]
    radius = tc["radius"]
    step_m = 4.0
    # half pixels from centre; ceil ensures half*step_m >= radius
    half   = math.ceil(radius / step_m)
    grid_n = 2 * half + 1          # always odd — centre pixel aligns with snap

    cos_lat = math.cos(math.radians(lat))
    safe_c  = max(abs(cos_lat), 0.001)

    # Physical (cos-corrected) coordinates in metres
    cx_phys = lng * 111320.0 * safe_c
    cy_phys = lat * 111320.0

    # Snap to global 4 m physical grid — defines scan identity for deduplication
    cx_snap = round(cx_phys / step_m) * step_m
    cy_snap = round(cy_phys / step_m) * step_m

    # ── Cache check — heatmap is deterministic for (cx_snap, cy_snap, tc_level) ──
    _cache_key = (cx_snap, cy_snap, tc_level)
    _now = time.time()
    _cached = _HEATMAP_CACHE.get(_cache_key)
    if _cached and _now - _cached[0] < _HEATMAP_CACHE_TTL:
        return _cached[1]

    # Pixel centres in physical metres, symmetric around snapped centre
    idx     = np.arange(grid_n, dtype=np.float64) - half   # offsets: -half … +half
    phys_x  = cx_snap + idx * step_m   # physical E-W metres for each column
    phys_y  = cy_snap + idx * step_m   # physical N-S metres for each row

    # World coordinates for master field lookup
    # world_x_m = lng * 111320 (NOT cos-corrected) → divide physical x by safe_c
    # world_y_m = lat * 111320 = physical y
    world_x_grid, world_y_grid = np.meshgrid(phys_x / safe_c, phys_y)
    world_x_m = world_x_grid.ravel()
    world_y_m = world_y_grid.ravel()

    # Physicalcoordinate grids for circle mask and noise (step_m × step_m metres)
    phys_x_grid, phys_y_grid = np.meshgrid(phys_x - cx_snap, phys_y - cy_snap)
    dist2  = (phys_x_grid * phys_x_grid + phys_y_grid * phys_y_grid).ravel()
    in_r   = dist2 <= (radius * radius)

    accuracy = tc["accuracy"] / 100.0
    max_q    = float(tc["max_quality"])
    pngs: dict = {}

    # Flatten physical coords once for the noise function
    phys_x_flat = (cx_snap + (np.arange(grid_n * grid_n) % grid_n - half) * step_m)
    phys_y_flat = (cy_snap + (np.arange(grid_n * grid_n) // grid_n - half) * step_m)

    for mine_id in _NOISE_RES_CONFIG:
        field = get_master_field(mine_id)
        q_in  = _sample_master_bilinear(field, world_x_m[in_r], world_y_m[in_r])

        if accuracy < 1.0:
            err_n = _smooth_noise_arr(phys_x_flat[in_r] / 400.0,
                                      phys_y_flat[in_r] / 400.0, mine_id * 17 + 50)
            q_in  = q_in * (1.0 + err_n * (1.0 - accuracy) * 0.8)

        q_in = np.clip(q_in, 0.0, max_q)

        q_full       = np.zeros(grid_n * grid_n, dtype=np.float32)
        q_full[in_r] = q_in

        if np.any(q_full > 0.5):
            pngs[str(mine_id)] = _grid_to_png_b64(q_full, grid_n)

    # Convert snapped physical centre back to lat/lng
    center_lat = cy_snap / 111320.0
    center_lng = cx_snap / (111320.0 * safe_c)

    result = {"grid": grid_n, "step_m": step_m,
              "center_lat": center_lat, "center_lng": center_lng,
              "radius_m": radius, "pngs": pngs}

    # ── Store in cache; evict oldest entry if at capacity ──
    if len(_HEATMAP_CACHE) >= _HEATMAP_CACHE_MAX:
        oldest = min(_HEATMAP_CACHE, key=lambda k: _HEATMAP_CACHE[k][0])
        del _HEATMAP_CACHE[oldest]
    _HEATMAP_CACHE[_cache_key] = (_now, result)

    return result

# Working atmosphere booster items
# boost = production multiplier when active, wa_delta = WA change on use, hours = duration
WA_BOOSTERS = {
    158: {"name": "Night Shift",   "boost": 1.30, "wa_delta": -20, "hours": 8},
    159: {"name": "Overtime",      "boost": 1.10, "wa_delta": -5,  "hours": 8},
    160: {"name": "Guest Workers", "boost": 1.20, "wa_delta": -15, "hours": 8},
    161: {"name": "Wage Subsidy",  "boost": 1.50, "wa_delta": +10, "hours": 8},
}

DISEASE_SPREAD_RADIUS_M = 60
DISEASE_DURATION_DAYS   = 14  # sick mine is debuffed for 2 weeks
FIRE_DURATION_DAYS      = 5

# HQ production boost: level → (boost_multiplier, radius_m)
# Multiplier: level 1=1.9x, each subsequent level +0.9; Radius: 115m at level 1, +15m per level
HQ_BOOST_FACTORS = {lvl: round(0.9 * lvl + 1.0, 1) for lvl in range(1, 11)}
HQ_BOOST_FACTORS[1] = 1.9
HQ_BOOST_RADIUS = {lvl: 100 + lvl * 15 for lvl in range(1, 11)}  # 115m..250m

# HQ upgrade resource requirements: target_level → {item_id: qty}
HQ_UPGRADE_REQS = {
    2:  {2: 750000,  3: 750000,  8: 750000,  20: 750000},
    3:  {7: 1500000, 13: 1500000, 22: 1500000, 24: 1500000},
    4:  {10: 2000000, 12: 2000000, 26: 2000000, 53: 2000000},
    5:  {28: 3000000, 30: 3000000, 36: 3000000, 38: 3000000},
    6:  {32: 4000000, 49: 4000000, 90: 4000000, 92: 4000000},
    7:  {57: 5000000, 59: 5000000, 67: 5000000, 93: 5000000},
    8:  {14: 10000000, 15: 10000000, 51: 10000000, 81: 10000000},
    9:  {35: 25000000, 66: 25000000, 75: 25000000, 79: 25000000},
    10: {30: 50000000, 59: 50000000, 84: 50000000, 87: 50000000},
}

# ── DB ─────────────────────────────────────────────────────────────────────────

def get_db() -> sqlite3.Connection:
    # Requests run concurrently in threads; wait for a busy writer instead of failing fast.
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn

def award_xp(conn, hid: str, credits_spent: int):
    """XP for credits spent permanently (1 XP per 100 credits, economy.XP_PER_CREDIT)."""
    if credits_spent <= 0:
        return
    add_xp(conn, hid, max(1, int(credits_spent * economy.XP_PER_CREDIT)))

def award_sink(conn, hid: str, credits: float = 0, res: dict | None = None):
    """XP for a permanent sink: credits plus resources at the system price (owner 2026-10-23:
    XP only from permanent sinks — never from market trades)."""
    add_xp(conn, hid, economy.sink_xp(credits, res))

def add_xp(conn, hid: str, xp_gain: int):
    if xp_gain <= 0:
        return
    conn.execute("UPDATE players SET xp=xp+? WHERE hID=?", (xp_gain, hid))
    row = conn.execute("SELECT xp, level FROM players WHERE hID=?", (hid,)).fetchone()
    if row:
        new_level = level_from_xp(row["xp"])
        if new_level > row["level"]:
            conn.execute("UPDATE players SET level=? WHERE hID=?", (new_level, hid))
            add_proto(conn, hid, "levelup", {"from": row["level"], "to": new_level})
            for hook in LEVEL_UP_HOOKS:   # e.g. Cargo Rain rewards (systems/cargo.py)
                hook(conn, hid, row["level"], new_level)

def legacy_error(e, err: int = 5):
    """econ.GameError → the legacy reply shape."""
    return zlib_resp({"err": err, "code": e.code, "msg": e.message})

def change_wa(conn, hid: str, delta: float, reason: str = "") -> float:
    """Change the working atmosphere by `delta` points (0..100, one decimal). Returns the new WA."""
    r = conn.execute("SELECT wa FROM players WHERE hID=?", (hid,)).fetchone()
    wa = float(r[0]) if r and r[0] is not None else 80.0
    new = round(max(0.0, min(100.0, wa + delta)), 1)
    if new != wa:
        conn.execute("UPDATE players SET wa=? WHERE hID=?", (new, hid))
    return new

# ── Travel check (GPS spoofing) ─────────────────────────────────────────────────
# Positions come from the phone. Teleporting is refused: between two positioned actions the player
# can't have travelled faster than TRAVEL_MAX_KMH (allowing GPS jitter). Long gaps are always fine.
TRAVEL_MAX_KMH = 300
TRAVEL_FREE_M = 5000          # jumps up to this distance are always accepted (GPS fixes switching)

def check_travel(conn, hid: str, lat: float, lng: float) -> None:
    """Raise GameError('teleport') when the position implies impossible travel; else remember it."""
    r = conn.execute("SELECT pos_lat, pos_lng, pos_at FROM players WHERE hID=?", (hid,)).fetchone()
    now = datetime.datetime.utcnow()
    if r and r["pos_lat"] is not None and r["pos_at"]:
        try:
            dt_h = max(1e-6, (now - datetime.datetime.fromisoformat(r["pos_at"])).total_seconds() / 3600)
        except ValueError:
            dt_h = 1e9
        d = haversine_m(r["pos_lat"], r["pos_lng"], lat, lng)
        if d > TRAVEL_FREE_M and d / 1000 / dt_h > TRAVEL_MAX_KMH:
            raise econ.GameError("teleport", "Your position jumped too far too fast. Wait a moment and try again.")
    conn.execute("UPDATE players SET pos_lat=?, pos_lng=?, pos_at=? WHERE hID=?", (lat, lng, now.isoformat(), hid))

EVENT_HOOKS = []         # fn(conn, hid) -> [(title, body)]: daily incidents (systems/incidents.py), in a tx
PENALTY = None           # set by systems/incidents.py: fn(conn, hid, kind, target, data) -> credits charged

# Called as hook(conn, hid, old_level, new_level) inside the transaction that levelled up.
LEVEL_UP_HOOKS = []
OUTPUT_HOOKS = []        # fn(conn, hid, item_id, qty) -> qty kept; mining + factory output (loan garnishment)

def apply_output_hooks(conn, hid, item_id, qty):
    for hook in OUTPUT_HOOKS:
        qty = hook(conn, hid, item_id, qty)
    return qty

CASINO_FIVE_HOOKS = []   # fn(conn, symbol, spinner_hid) -> dict | None, inside the roll transaction

SCAN_COST_DIVISOR = 10      # (pre-revamp scan formula, unused)
# Owner 2026-10-23: start with enough for about six clay pits; scans are free below level 5
# (economy.FREE_SCAN_LEVEL), so a new company can always get going.
STARTING_CREDITS = 250000

def record_daily_activity(conn, hid: str):
    today = datetime.datetime.utcnow().strftime("%Y-%m-%d")
    conn.execute(
        "INSERT OR IGNORE INTO player_activity (hid, day) VALUES (?,?)", (hid, today))

def init_db():
    with get_db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS players (
                hID           TEXT PRIMARY KEY,
                company_name  TEXT UNIQUE NOT NULL,
                credits       INTEGER DEFAULT 50000,
                xp            INTEGER DEFAULT 0,
                level         INTEGER DEFAULT 1,
                team_id       INTEGER DEFAULT 0,
                wh_level      INTEGER DEFAULT 1,
                created_at    TEXT DEFAULT (datetime('now'))
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS mines (
                mine_id     TEXT PRIMARY KEY,
                owner_hid   TEXT NOT NULL,
                lat         REAL NOT NULL,
                lng         REAL NOT NULL,
                item_id     INTEGER NOT NULL,
                quality     INTEGER DEFAULT 70,
                condition   INTEGER DEFAULT 100,
                level       INTEGER DEFAULT 1,
                tech_up     INTEGER DEFAULT 0,
                defence     INTEGER DEFAULT 0,
                last_coll   TEXT DEFAULT (datetime('now')),
                created_at  TEXT DEFAULT (datetime('now')),
                FOREIGN KEY(owner_hid) REFERENCES players(hID)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS warehouse (
                hid     TEXT NOT NULL,
                item_id INTEGER NOT NULL,
                qty     REAL DEFAULT 0,
                PRIMARY KEY(hid, item_id)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS hq (
                hid     TEXT PRIMARY KEY,
                lat     REAL NOT NULL,
                lng     REAL NOT NULL,
                level   INTEGER DEFAULT 1,
                FOREIGN KEY(hid) REFERENCES players(hID)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS factories (
                factory_id  TEXT PRIMARY KEY,
                hid         TEXT NOT NULL,
                item_id     INTEGER NOT NULL,
                level       INTEGER DEFAULT 1,
                prod_item   INTEGER,
                prod_amount REAL,
                prod_end    TEXT,
                created_at  TEXT DEFAULT (datetime('now')),
                FOREIGN KEY(hid) REFERENCES players(hID)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS market_req (
                req_id      TEXT PRIMARY KEY,
                seller_hid  TEXT NOT NULL,
                item_id     INTEGER NOT NULL,
                qty         REAL NOT NULL,
                price_unit  REAL NOT NULL,
                created_at  TEXT DEFAULT (datetime('now')),
                expires_at  TEXT NOT NULL,
                active      INTEGER DEFAULT 1
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS proto_log (
                log_id     TEXT PRIMARY KEY,
                hid        TEXT NOT NULL,
                log_type   TEXT NOT NULL,
                data_json  TEXT,
                created_at TEXT DEFAULT (datetime('now'))
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS player_activity (
                hid  TEXT NOT NULL,
                day  TEXT NOT NULL,
                PRIMARY KEY (hid, day)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS hq_deposits (
                hid          TEXT NOT NULL,
                target_level INTEGER NOT NULL,
                item_id      INTEGER NOT NULL,
                amount       REAL DEFAULT 0,
                PRIMARY KEY (hid, target_level, item_id)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS chat_messages (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                hid  TEXT NOT NULL,
                name TEXT NOT NULL,
                msg  TEXT NOT NULL,
                ts   TEXT NOT NULL
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS casino_state (
                hid           TEXT PRIMARY KEY,
                spins_left    INTEGER DEFAULT 500,
                gd_packs_used INTEGER DEFAULT 0,
                reset_at      TEXT DEFAULT NULL
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS jackpot (
                id     INTEGER PRIMARY KEY DEFAULT 1,
                amount INTEGER DEFAULT 100000000000
            )""")
        # Seed jackpot row if missing
        conn.execute("INSERT OR IGNORE INTO jackpot(id, amount) VALUES(1, 100000000000)")
        # FCM push tokens
        conn.execute("""
            CREATE TABLE IF NOT EXISTS fcm_tokens (
                hid         TEXT NOT NULL,
                token       TEXT NOT NULL,
                platform    TEXT DEFAULT 'android',
                updated_at  TEXT DEFAULT (datetime('now')),
                PRIMARY KEY (hid, token)
            )""")
        # Server-side notification preferences and cooldowns
        conn.execute("""
            CREATE TABLE IF NOT EXISTS notif_prefs (
                hid                TEXT PRIMARY KEY,
                enabled             INTEGER DEFAULT 1,
                mine_warning        INTEGER DEFAULT 1,
                mine_destroyed      INTEGER DEFAULT 1,
                wh_almost_full      INTEGER DEFAULT 1,
                wh_full             INTEGER DEFAULT 1,
                last_warn_at        TEXT,
                last_destr_at       TEXT,
                last_wh_almost_at   TEXT,
                last_wh_full_at     TEXT
            )""")
        conn.commit()
        # Migrations: add columns if not present
        for col_def in [
            ("factories", "boost_until", "TEXT"),
            ("factories", "boost_cooldown_until", "TEXT"),
            ("factories", "fire_until", "TEXT"),
            ("factories", "booster_item", "INTEGER"),
            ("factories", "booster_until", "TEXT"),
            ("factories", "prod_start", "TEXT"),
            ("mines",     "sick_until", "TEXT"),
            ("mines",     "tu1", "INTEGER DEFAULT 0"),
            ("mines",     "tu2", "INTEGER DEFAULT 0"),
            ("mines",     "tu3", "INTEGER DEFAULT 0"),
            ("mines",     "tu4", "INTEGER DEFAULT 0"),
            ("players",   "wa", "INTEGER DEFAULT 80"),
            ("players",   "last_event_check", "TEXT"),
            ("players",   "country_code", "TEXT"),
            # economy revamp 2026-10-23
            ("mines",     "paid", "INTEGER"),               # credits paid for the mine (refund, XP)
            ("players",   "pos_lat", "REAL"),               # last reported position (travel check)
            ("players",   "pos_lng", "REAL"),
            ("players",   "pos_at", "TEXT"),
            ("players",   "hq_moved_at", "TEXT"),
            ("players",   "name_changes", "INTEGER DEFAULT 0"),
            ("players",   "delete_at", "TEXT"),             # GDPR deletion scheduled for
            ("factories", "last_active", "TEXT"),           # last production start/collect (idle WA)
            ("factories", "strike_at", "TEXT"),             # on strike since (frozen)
            ("factories", "strike_cost", "INTEGER"),
        ]:
            try:
                conn.execute(f"ALTER TABLE {col_def[0]} ADD COLUMN {col_def[1]} {col_def[2]}")
                conn.commit()
            except Exception:
                pass

        # Ensure spatial index on mines for fast bounding-box queries
        conn.execute("CREATE INDEX IF NOT EXISTS idx_mines_lat_lng ON mines(lat, lng)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_hq_lat_lng ON hq(lat, lng)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_mines_owner ON mines(owner_hid)")
        # names keep their capitals but are unique without regard to case (owner 2026-10-24)
        try:
            conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_players_name_ci ON players(lower(company_name))")
        except sqlite3.IntegrityError:
            conn.execute("CREATE INDEX IF NOT EXISTS idx_players_name_ci2 ON players(lower(company_name))")
        # also created by systems/combat.py; needed here because mine_rows() joins it
        conn.execute("""CREATE TABLE IF NOT EXISTS mine_defence (
            mine_id TEXT PRIMARY KEY, dogs INTEGER NOT NULL DEFAULT 0, staff INTEGER NOT NULL DEFAULT 0,
            elite INTEGER NOT NULL DEFAULT 0, default_down INTEGER NOT NULL DEFAULT 0)""")
        conn.commit()

init_db()
with get_db() as _conn:
    auth.init(_conn, db_connect=get_db)

# ── Helpers ────────────────────────────────────────────────────────────────────

def zlib_bytes(data) -> bytes:
    return zlib.compress(json.dumps(data, ensure_ascii=False).encode("utf-8"), 9)

def zlib_resp(data) -> Response:
    return Response(content=zlib_bytes(data),
                    headers={"content-type": "application/octet-stream"})

def plain_resp(text: str) -> Response:
    return Response(content=text.encode(), media_type="text/plain")

def json_resp(data) -> Response:
    return Response(content=json.dumps(data, ensure_ascii=False).encode(),
                    media_type="application/json")

def new_hid() -> str:
    return hashlib.md5(uuid.uuid4().bytes).hexdigest()

def new_id() -> str:
    return uuid.uuid4().hex

def norm_name(name: str) -> str:
    """Lookup key of a company name: names are case-insensitive (owner 2026-10-24) but stored and
    shown exactly as the player typed them; compare with lower(company_name) = norm_name(...)."""
    return name.strip().lower()

async def read_form(request: Request) -> tuple[bytes, dict]:
    body = await request.body()
    form = await request.form()
    return body, {k: v for k, v in form.items()}

def hid_from_sid(sid: str) -> str:
    return auth.hid_from_sid(sid)

def make_sid(hid: str) -> str:
    return auth.make_session(hid)

def log_entry(data: dict):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
    except Exception:
        pass

def add_proto(conn, hid: str, log_type: str, data: dict):
    conn.execute(
        "INSERT INTO proto_log(log_id,hid,log_type,data_json,created_at) VALUES(?,?,?,?,?)",
        (new_id(), hid, log_type, json.dumps(data, ensure_ascii=False),
         datetime.datetime.utcnow().isoformat()))

def utcnow_iso() -> str:
    return datetime.datetime.utcnow().isoformat()

def wh_capacity(wh_level: int) -> float:
    return WAREHOUSE_BASE_CAPACITY * (wh_level ** 2)

def level_from_xp(xp: int) -> int:
    """Level curve from economy.py (calibrated: level 50 ≈ day 30, 60 ≈ day 40, then +6 %/level)."""
    return economy.level_from_xp(xp or 0)

def level_progress(xp: int, level: int) -> float:
    """0..1 progress inside the current level."""
    return economy.level_progress(xp or 0, level or 1)

def get_player(conn, hid: str):
    return conn.execute("SELECT * FROM players WHERE hID=?", (hid,)).fetchone()

def require_player(conn, sid: str):
    hid = hid_from_sid(sid)
    if not hid:
        return None, None
    row = get_player(conn, hid)
    return hid, row

def haversine_m(lat1, lng1, lat2, lng2) -> float:
    R = 6371000
    p = math.pi / 180
    a = (math.sin((lat2-lat1)*p/2)**2 +
         math.cos(lat1*p)*math.cos(lat2*p)*math.sin((lng2-lng1)*p/2)**2)
    return 2 * R * math.asin(math.sqrt(a))

def hex_min_dist(lat1, lng1, lat2, lng2) -> float:
    """Direction-aware minimum center distance for flat-top hex tiles (circumradius 15m).
    At edge-normal directions = sqrt(3)*15 ≈ 25.98m; at vertex directions = 2*15 = 30m."""
    dlat = (lat2 - lat1) * 111320.0
    dlng = (lng2 - lng1) * 111320.0 * math.cos(math.radians((lat1 + lat2) / 2))
    bearing = math.atan2(dlng, dlat) % (2 * math.pi)
    nearest = round(bearing / (math.pi / 3)) * (math.pi / 3)
    phi = abs(bearing - nearest)
    phi = min(phi, math.pi / 6 - 0.001)
    return 15.0 * math.sqrt(3) / math.cos(phi)

def wh_total(conn, hid: str) -> float:
    """Return total stored quantity across ALL items for this player."""
    row = conn.execute(
        "SELECT COALESCE(SUM(qty), 0.0) FROM warehouse WHERE hid=?", (hid,)).fetchone()
    return float(row[0])

def wh_add(conn, hid: str, item_id: int, qty: float, cap: float) -> float:
    """Add qty to warehouse, capped by the GLOBAL shared capacity. Returns actual added amount."""
    # Special buildings are never warehouse items — they live in the factories table.
    if item_id in SPECIAL_BUILDINGS:
        return 0.0
    total = wh_total(conn, hid)
    space = max(0.0, cap - total)
    added = econ.to_whole(conn, hid, item_id, min(qty, space), cap=space)   # whole units only
    if added <= 0:
        return 0.0
    conn.execute(
        "INSERT INTO warehouse(hid,item_id,qty) VALUES(?,?,?) "
        "ON CONFLICT(hid,item_id) DO UPDATE SET qty=qty+?",
        (hid, item_id, added, added))
    return added

def wh_remove(conn, hid: str, item_id: int, qty: float) -> bool:
    """Remove qty from the warehouse (conditional UPDATE: never below zero). False if insufficient."""
    try:
        econ.take(conn, hid, item_id, qty, "wh_remove")
        return True
    except econ.GameError:
        return False

def hq_boost_for_mine(conn, mine) -> float:
    """Return HQ boost multiplier if mine is within HQ radius (level-dependent), else 1.0."""
    hq = conn.execute("SELECT lat,lng,level FROM hq WHERE hid=?", (mine["owner_hid"],)).fetchone()
    if not hq:
        return 1.0
    radius = HQ_BOOST_RADIUS.get(hq["level"], 115)
    dist = haversine_m(mine["lat"], mine["lng"], hq["lat"], hq["lng"])
    if dist > radius:
        return 1.0
    return HQ_BOOST_FACTORS.get(hq["level"], 1.0)

# ── Repair cost (owner's rule, 2026-10-19) ───────────────────────────────────────
# The better a mine produces, the cheaper it is to repair: cost = 5 % of the build cost
# ÷ output factor, where output factor = quality × tech × condition × HQ boost (a plain mine at
# 100 % quality, no tech, 100 % condition, outside the HQ area = 1.0 → 5 % as before). The best
# possible mine (100 % Q, +500 % tech, 100 % cond, HQ level 10 ×10) = 60 → 1/60 of that. Losing
# condition makes it dearer; leaving the HQ area makes it up to 10× dearer (HQ level 10).
# Stationed defence units raise the cost: +1 % per 100 defence points stationed.
REPAIR_BASE_SHARE = 0.05
REPAIR_MIN = 100
REPAIR_DEFENCE_PER_PCT = 100.0
REPAIR_DEFENCE_VALUES = (5.0, 50.0, 100.0)   # watch dogs, security staff, elite (= combat DEFENCE_BASE)

def repair_cost_of(item_id, quality, condition, tu1, tu2, tu3, tu4, hq_f, dogs=0, staff=0, elite=0) -> int:
    base = MINE_TYPES.get(item_id, {}).get("cost", 1000) * REPAIR_BASE_SHARE
    tech = 1.0 + ((tu1 or 0) * 1.0 + (tu2 or 0) * 1.0 + (tu3 or 0) * 1.5 + (tu4 or 0) * 1.5) / 100.0
    out = (quality or 1) / 100.0 * tech * max(0.05, float(condition) / 100.0) * (hq_f or 1.0)
    defence = (dogs or 0) * REPAIR_DEFENCE_VALUES[0] + (staff or 0) * REPAIR_DEFENCE_VALUES[1] \
        + (elite or 0) * REPAIR_DEFENCE_VALUES[2]
    return max(REPAIR_MIN, round(base / max(0.01, out) * (1 + defence / REPAIR_DEFENCE_PER_PCT / 100.0)))

def repair_discount(conn, hid) -> float:
    """Dwarven Pick: repairs paid with credits cost 25/35/50 % less."""
    return 1 - artifact_effect(conn, hid, 177) / 100

def compute_repair_cost(conn, mine) -> int:
    d = conn.execute("SELECT dogs, staff, elite FROM mine_defence WHERE mine_id=?", (mine["mine_id"],)).fetchone()
    cost = repair_cost_of(mine["item_id"], mine["quality"], mine["condition"], mine["tu1"], mine["tu2"],
                          mine["tu3"], mine["tu4"], hq_boost_for_mine(conn, mine), *(tuple(d) if d else ()))
    return max(REPAIR_MIN, round(cost * repair_discount(conn, mine["owner_hid"])))

def collect_mine(conn, mine) -> tuple:
    """Calculate pending production, add to warehouse. Returns (amount_added, mine_destroyed)."""
    player = get_player(conn, mine["owner_hid"])
    if not player:
        return 0.0, False
    mt = MINE_TYPES.get(mine["item_id"])
    if not mt:
        return 0.0, False

    last = datetime.datetime.fromisoformat(mine["last_coll"])
    hours_real = max(0.0, (datetime.datetime.utcnow() - last).total_seconds() / 3600)
    hours = min(hours_real, 24.0)  # production: 24h buffer

    # Condition uses float: 4%/day = 1/6 per hour, over the REAL time since the last collection
    # (owner 2026-10-23: mines of inactive players keep decaying on the server, so they show
    # their real condition and can be attacked). Production stays capped at the 24 h buffer.
    # Round to 2 decimal places so that a mine freshly set to 100 never stores
    # a value like 99.9999... that Flutter's int truncation would display as 99.
    cond_start = float(mine["condition"])
    cond_end = round(cond_start - hours_real / 6.0, 2)

    # Destruction at condition < 20.0 (exactly 20.00 is still valid)
    destroyed = cond_end < 20.0
    if destroyed:
        if cond_start <= 20.0:
            # Already at/past threshold — no production, destroy immediately
            effective_hours = 0.0
            avg_cond = cond_start
        else:
            # Condition hits 20.0 partway through: t = (cond_start - 20.0) * 6
            effective_hours = min((cond_start - 20.0) * 6.0, hours)
            avg_cond = (cond_start + 20.0) / 2.0
    else:
        effective_hours = hours
        avg_cond = (cond_start + cond_end) / 2.0

    quality_factor = mine["quality"] / 100.0
    condition_factor = max(0.0, avg_cond / 100.0)
    tu1 = (mine["tu1"] or 0) if "tu1" in mine.keys() else 0
    tu2 = (mine["tu2"] or 0) if "tu2" in mine.keys() else 0
    tu3 = (mine["tu3"] or 0) if "tu3" in mine.keys() else 0
    tu4 = (mine["tu4"] or 0) if "tu4" in mine.keys() else 0
    tech_boost = (tu1 * 1.0 + tu2 * 1.0 + tu3 * 1.5 + tu4 * 1.5) / 100.0
    tech_factor = 1.0 + tech_boost
    level_factor = float(mine["level"])
    hq_factor = hq_boost_for_mine(conn, mine)
    sick_factor = 1.0
    if mine["sick_until"]:
        try:
            su = datetime.datetime.fromisoformat(mine["sick_until"])
            if datetime.datetime.utcnow() < su:
                sick_factor = 0.5
        except Exception:
            pass

    amount = (mt["rate"] * effective_hours * quality_factor * condition_factor
              * tech_factor * level_factor * hq_factor * sick_factor)

    old_last_coll = mine["last_coll"]
    new_ts = utcnow_iso()

    if destroyed:
        r = conn.execute(
            "DELETE FROM mines WHERE mine_id=? AND last_coll=?",
            (mine["mine_id"], old_last_coll))
    else:
        r = conn.execute(
            "UPDATE mines SET last_coll=?, condition=? WHERE mine_id=? AND last_coll=?",
            (new_ts, cond_end, mine["mine_id"], old_last_coll))

    if r.rowcount == 0:
        return 0.0, False

    added = 0.0
    if amount >= 0.01:
        amount = apply_output_hooks(conn, mine["owner_hid"], mt["res"], amount)
        cap = wh_capacity(player["wh_level"])
        added = wh_add(conn, mine["owner_hid"], mt["res"], amount, cap)

    return added, destroyed

def current_condition(mine) -> float:
    """Condition right now (stored value minus the decay since the last collection), 0–100."""
    try:
        hours = max(0.0, (datetime.datetime.utcnow() - datetime.datetime.fromisoformat(mine["last_coll"])
                          ).total_seconds() / 3600)
    except (TypeError, ValueError):
        hours = 0.0
    return round(max(0.0, float(mine["condition"]) - hours / 6.0), 2)

def _hq_boost_from(hq, mine) -> float:
    """hq_boost_for_mine() with the HQ row already loaded."""
    if not hq:
        return 1.0
    if haversine_m(mine["lat"], mine["lng"], hq["lat"], hq["lng"]) > HQ_BOOST_RADIUS.get(hq["level"], 115):
        return 1.0
    return HQ_BOOST_FACTORS.get(hq["level"], 1.0)

# ── Set-based mine maths (scales to very large mine counts) ────────────────────
# The per-mine formulas of collect_mine() / rateHr, expressed in SQL so the database
# does the work in a few statements instead of Python touching every row.

def _prepare_mine_temp(conn, hid: str, hq) -> None:
    """Per-connection TEMP tables: mine type constants and the player's HQ-boosted mines."""
    conn.execute("CREATE TEMP TABLE IF NOT EXISTS _mt("
                 "item_id INTEGER PRIMARY KEY, rate REAL, res INTEGER, special INTEGER)")
    conn.execute("DELETE FROM _mt")
    conn.executemany("INSERT INTO _mt VALUES(?,?,?,?)",
                     [(k, v["rate"], v["res"], 1 if v["res"] in SPECIAL_BUILDINGS else 0)
                      for k, v in MINE_TYPES.items()])
    conn.execute("CREATE TEMP TABLE IF NOT EXISTS _boost(mine_id TEXT PRIMARY KEY, f REAL)")
    conn.execute("DELETE FROM _boost")
    if hq:
        factor = HQ_BOOST_FACTORS.get(hq["level"], 1.0)
        radius = HQ_BOOST_RADIUS.get(hq["level"], 115)
        if factor != 1.0:
            dlat = radius / 111320.0 * 1.05
            dlng = dlat / max(0.01, math.cos(math.radians(hq["lat"])))
            near = conn.execute(
                "SELECT mine_id, lat, lng FROM mines WHERE owner_hid=? AND lat BETWEEN ? AND ? "
                "AND lng BETWEEN ? AND ?",
                (hid, hq["lat"] - dlat, hq["lat"] + dlat, hq["lng"] - dlng, hq["lng"] + dlng)).fetchall()
            conn.executemany("INSERT INTO _boost VALUES(?,?)",
                             [(m[0], factor) for m in near
                              if haversine_m(m[1], m[2], hq["lat"], hq["lng"]) <= radius])

# SQL fragment: hours since last collection, capped like collect_mine() (needs :now).
_SQL_HOURS = "MIN(MAX(0.0, (julianday(:now) - julianday(m.last_coll)) * 24.0), 24.0)"
# uncapped hours: condition decays with real time
_SQL_HOURS_RAW = "MAX(0.0, (julianday(:now) - julianday(m.last_coll)) * 24.0)"
_SQL_TECH = ("(1.0 + (COALESCE(m.tu1,0)*1.0 + COALESCE(m.tu2,0)*1.0 + "
             "COALESCE(m.tu3,0)*1.5 + COALESCE(m.tu4,0)*1.5) / 100.0)")
# rateHr exactly as build_player_data() reports it (no sickness factor, condition floor 0.1).
_SQL_RATE_HR = (f"(t.rate * m.quality / 100.0 * MAX(0.1, m.condition / 100.0) * {_SQL_TECH} "
                f"* m.level * COALESCE(b.f, 1.0))")

def collect_mines_bulk(conn, hid: str, only_ids=None) -> int:
    """Same result as calling collect_mine() on each of the player's mines in turn (same
    formulas, same warehouse fill order), done in a handful of SQL statements.
    Commits. Returns the number of mines destroyed.

    Runs under BEGIN IMMEDIATE so no other writer can collect the same mines concurrently
    (which collect_mine guards against with its last_coll check)."""
    conn.commit()
    conn.execute("BEGIN IMMEDIATE")
    try:
        player = get_player(conn, hid)
        if not player:
            conn.rollback()
            return 0
        hq = conn.execute("SELECT lat,lng,level FROM hq WHERE hid=?", (hid,)).fetchone()
        _prepare_mine_temp(conn, hid, hq)
        conn.execute("CREATE TEMP TABLE IF NOT EXISTS _only(mine_id TEXT PRIMARY KEY)")
        conn.execute("DELETE FROM _only")
        flt = ""
        if only_ids is not None:
            conn.executemany("INSERT OR IGNORE INTO _only VALUES(?)", [(i,) for i in only_ids])
            flt = " AND m.mine_id IN (SELECT mine_id FROM _only)"
        space = max(0.0, wh_capacity(player["wh_level"]) - wh_total(conn, hid))
        p = {"hid": hid, "now": datetime.datetime.utcnow().isoformat(), "space": space}

        cond_end = f"ROUND(m.condition - {_SQL_HOURS_RAW} / 6.0, 2)"
        # 1. warehouse additions, capped per mine in rowid order like sequential wh_add()
        adds = conn.execute(f"""
            WITH c AS (
              SELECT m.rowid AS rid, t.res, t.special, t.rate, m.quality, m.level,
                     {_SQL_HOURS} AS hours, CAST(m.condition AS REAL) AS c0, {cond_end} AS c1,
                     {_SQL_TECH} AS tech, COALESCE(b.f, 1.0) AS hqf,
                     CASE WHEN m.sick_until IS NOT NULL AND m.sick_until > :now THEN 0.5 ELSE 1.0 END AS sick
              FROM mines m JOIN _mt t ON t.item_id = m.item_id
                           LEFT JOIN _boost b ON b.mine_id = m.mine_id
              WHERE m.owner_hid = :hid{flt}
            ), a AS (
              SELECT rid, res, special,
                     rate * (CASE WHEN c1 < 20.0 THEN (CASE WHEN c0 <= 20.0 THEN 0.0
                                                            ELSE MIN((c0 - 20.0) * 6.0, hours) END)
                                  ELSE hours END)
                          * quality / 100.0
                          * MAX(0.0, (CASE WHEN c1 < 20.0 THEN (CASE WHEN c0 <= 20.0 THEN c0
                                                                     ELSE (c0 + 20.0) / 2.0 END)
                                           ELSE (c0 + c1) / 2.0 END) / 100.0)
                          * tech * level * hqf * sick AS amount
              FROM c
            ), w AS (
              SELECT res, amount,
                     SUM(amount) OVER (ORDER BY rid ROWS UNBOUNDED PRECEDING) - amount AS before
              FROM a WHERE amount >= 0.01 AND special = 0
            )
            SELECT res, SUM(MAX(0.0, MIN(amount, :space - before))) FROM w GROUP BY res
        """, p).fetchall()

        # 2. destroyed mines, 3. surviving mines (same expressions, before last_coll changes)
        own = "owner_hid = :hid AND item_id IN (SELECT item_id FROM _mt)" + (
            " AND mine_id IN (SELECT mine_id FROM _only)" if only_ids is not None else "")
        hours_u = _SQL_HOURS_RAW.replace("m.last_coll", "last_coll")
        cond_u = f"ROUND(condition - {hours_u} / 6.0, 2)"
        destroyed = conn.execute(f"DELETE FROM mines WHERE {own} AND {cond_u} < 20.0", p).rowcount
        conn.execute(f"UPDATE mines SET condition = {cond_u}, last_coll = :now WHERE {own}", p)

        conn.executemany(
            "INSERT INTO warehouse(hid,item_id,qty) VALUES(?,?,?) "
            "ON CONFLICT(hid,item_id) DO UPDATE SET qty=qty+excluded.qty",
            [(hid, res, q) for res, q in ((r, econ.to_whole(conn, hid, r, apply_output_hooks(conn, hid, r, qty))
                                           if qty and qty > 0 else 0) for r, qty in adds) if q and q > 0])
        conn.commit()
        return destroyed
    except Exception:
        conn.rollback()
        raise

def mine_stats(conn, hid: str) -> dict:
    """Aggregates the app needs instead of the full mine list (counts, notification
    timings, output). Call after collect_mines_bulk() so conditions are current."""
    hq = conn.execute("SELECT lat,lng,level FROM hq WHERE hid=?", (hid,)).fetchone()
    _prepare_mine_temp(conn, hid, hq)
    r = conn.execute(f"""
        SELECT COUNT(*),
               SUM(CASE WHEN m.condition > 20 AND m.condition <= 100 AND (m.condition - 24) * 6 <= 72 THEN 1 ELSE 0 END),
               MIN(CASE WHEN m.condition > 20 AND m.condition <= 100 AND (m.condition - 24) * 6 <= 72
                        THEN (m.condition - 24) * 6 END),
               SUM(CASE WHEN m.condition > 20 AND m.condition <= 100 AND (m.condition - 20) * 6 <= 336 THEN 1 ELSE 0 END),
               MIN(CASE WHEN m.condition > 20 AND m.condition <= 100 AND (m.condition - 20) * 6 <= 336
                        THEN (m.condition - 20) * 6 END),
               MAX({_SQL_RATE_HR}), SUM({_SQL_RATE_HR})
        FROM mines m LEFT JOIN _mt t ON t.item_id = m.item_id
                     LEFT JOIN _boost b ON b.mine_id = m.mine_id
        WHERE m.owner_hid = ?""", (hid,)).fetchone()
    return {"count": r[0] or 0,
            "warnCount": r[1] or 0, "warnInH": r[2],
            "destrCount": r[3] or 0, "destrInH": r[4],
            "maxRateHr": round(r[5] or 0.0, 2), "totalRateHr": round(r[6] or 0.0, 1)}

def mine_rows(conn, hid: str, where: str = "", args: tuple = (), order: str = "m.rowid",
              limit: int = -1, offset: int = 0) -> list:
    """The player's mines in the same JSON shape as build_player_data()['mines']."""
    hq = conn.execute("SELECT lat,lng,level FROM hq WHERE hid=?", (hid,)).fetchone()
    _prepare_mine_temp(conn, hid, hq)
    now_iso = datetime.datetime.utcnow().isoformat()
    disc = repair_discount(conn, hid)
    rows = conn.execute(f"""
        SELECT m.mine_id, m.lat, m.lng, m.item_id, COALESCE(t.res, 0), m.quality, m.condition,
               m.level, COALESCE(m.tu1,0), COALESCE(m.tu2,0), COALESCE(m.tu3,0), COALESCE(m.tu4,0),
               m.defence, m.last_coll, COALESCE({_SQL_RATE_HR}, 0), b.f,
               CASE WHEN m.sick_until > ? THEN m.sick_until END,
               COALESCE(d.dogs,0), COALESCE(d.staff,0), COALESCE(d.elite,0)
        FROM mines m LEFT JOIN _mt t ON t.item_id = m.item_id
                     LEFT JOIN _boost b ON b.mine_id = m.mine_id
                     LEFT JOIN mine_defence d ON d.mine_id = m.mine_id
        WHERE m.owner_hid = ? {where}
        ORDER BY {order} LIMIT ? OFFSET ?""", (now_iso, hid) + args + (limit, offset)).fetchall()
    return [{"mID": r[0], "lat": r[1], "lng": r[2], "itemID": r[3], "resID": r[4], "qual": r[5],
             "cond": r[6], "lvl": r[7], "tu1": r[8], "tu2": r[9], "tu3": r[10], "tu4": r[11],
             "def": r[12], "lastColl": r[13], "rateHr": round(r[14], 1),
             "hqBoost": r[15] if r[15] and r[15] > 1.0 else None, "sickUntil": r[16],
             "repairCost": max(REPAIR_MIN, round(repair_cost_of(r[3], r[5], r[6], r[8], r[9], r[10], r[11],
                                                                r[15] or 1.0, r[17], r[18], r[19]) * disc))}
            for r in rows]

def maybe_run_events(conn, hid: str, wa: int):
    """Daily incidents (WA, accidents, strikes: systems/incidents.py); once per hour: disease spreading."""
    pushes = []
    with econ.tx(conn):
        for hook in EVENT_HOOKS:
            pushes += hook(conn, hid) or []
    for title, body in pushes:
        try:
            _push_to_player(conn, hid, title, body)
        except Exception:
            pass
    row = conn.execute("SELECT last_event_check FROM players WHERE hID=?", (hid,)).fetchone()
    now = datetime.datetime.utcnow()
    if row and row["last_event_check"]:
        try:
            last = datetime.datetime.fromisoformat(row["last_event_check"])
            if (now - last).total_seconds() < 3600:
                return
        except Exception:
            pass
    conn.execute("UPDATE players SET last_event_check=? WHERE hID=?", (now.isoformat(), hid))

    mines = conn.execute("SELECT mine_id, lat, lng, sick_until FROM mines WHERE owner_hid=?",
                         (hid,)).fetchall()

    def is_sick(m):
        try:
            return bool(m["sick_until"]) and datetime.datetime.fromisoformat(m["sick_until"]) > now
        except Exception:
            return False

    sick_mines = [m for m in mines if is_sick(m)]
    healthy = [m for m in mines if not is_sick(m)]
    law = protection.law_firm_factor(building_level(conn, hid, protection.LAW_FIRM))
    sick_until_str = (now + datetime.timedelta(days=DISEASE_DURATION_DAYS * law)).isoformat()
    rng = random.Random()
    hospital = building_level(conn, hid, protection.HOSPITAL)
    spread_f = protection.spread_factor(hospital)
    infect = set()

    # Spread disease from sick mines to healthy mines within DISEASE_SPREAD_RADIUS_M.
    # Spatial grid: each sick mine only looks at the 3x3 neighbouring cells instead of every
    # mine; every (sick, healthy-neighbour) pair still gets its own 30% roll as before.
    if sick_mines and healthy:
        cell_m = float(DISEASE_SPREAD_RADIUS_M)
        def cell(m):
            y = m["lat"] * 111320.0
            x = m["lng"] * 111320.0 * math.cos(math.radians(m["lat"]))
            return int(math.floor(x / cell_m)), int(math.floor(y / cell_m))
        grid = {}
        for m in healthy:
            grid.setdefault(cell(m), []).append(m)
        for sm in sick_mines:
            cx, cy = cell(sm)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for m in grid.get((cx + dx, cy + dy), ()):
                        if (haversine_m(sm["lat"], sm["lng"], m["lat"], m["lng"]) <= DISEASE_SPREAD_RADIUS_M
                                and rng.random() < 0.30 * spread_f):
                            infect.add(m["mine_id"])

    # (new outbreaks: daily accidents in systems/incidents.py, chance from the working atmosphere)

    if infect:
        conn.executemany("UPDATE mines SET sick_until=? WHERE mine_id=?",
                         [(sick_until_str, mid) for mid in infect])

# ── Scanner ────────────────────────────────────────────────────────────────────

MAX_MINES_PER_PLAYER = 10000
REMOTE_BUILD_COOLDOWN_H = 12   # owner's rule: one drone (remote) construction per 12 hours (Astrolabium: 11/10/8)

HQ_SUB_LEVEL_POINTS = 10_000   # owner: HQ 10_1 … 10_6 unlock with every 10 000 luxury points
HQ_SUB_LEVEL_MAX = 6

def luxury_points_of(conn, hid: str) -> int:
    try:
        r = conn.execute("SELECT points FROM luxury_points WHERE hid=?", (hid,)).fetchone()
    except Exception:
        return 0
    return int(r[0]) if r else 0

def hq_sub_level(conn, hid: str, level: int) -> int:
    """HQ level 10 sub-level from luxury points (0 below level 10)."""
    if level < 10:
        return 0
    return min(HQ_SUB_LEVEL_MAX, luxury_points_of(conn, hid) // HQ_SUB_LEVEL_POINTS)

def artifact_effect(conn, hid: str, item_id: int) -> float:
    """Effect of an invested artifact kind (systems/archaeology.py ARTIFACT_EFFECTS)."""
    from systems import archaeology
    return archaeology.effect(conn, hid, item_id)

def remote_build_hours(conn, hid: str) -> float:
    return artifact_effect(conn, hid, 172)

def remote_build_next(conn, hid: str):
    """When the next drone (remote) construction is allowed (ISO, UTC), or None if it is now.
    The wait is 12 h, 11/10/8 h with the Astrolabium (owner's rule)."""
    r = conn.execute("SELECT MAX(ts) FROM game_events WHERE hid=? AND type='remote_build'", (hid,)).fetchone()
    if not r or not r[0]:
        return None
    nxt = datetime.datetime.fromisoformat(r[0]) + datetime.timedelta(hours=remote_build_hours(conn, hid))
    return nxt.isoformat() if nxt > datetime.datetime.utcnow() else None

def _remote_build_wait(hid: str):
    """'3 h 20 min' until the next remote build is allowed, or None."""
    with get_db() as c:
        r = c.execute("SELECT MAX(ts) FROM game_events WHERE hid=? AND type='remote_build'", (hid,)).fetchone()
        hours = remote_build_hours(c, hid)
    if not r or not r[0]:
        return None
    left = datetime.datetime.fromisoformat(r[0]) + datetime.timedelta(hours=hours) - datetime.datetime.utcnow()
    if left.total_seconds() <= 0:
        return None
    m = int(left.total_seconds() // 60)
    return f"{m // 60} h {m % 60} min"

def mine_scaled_cost(base_cost: int, mine_count: int) -> int:
    """costs.txt: base × (1 + mines owned / 50), rounded to 100."""
    scaled = base_cost * (1 + mine_count / economy.MINE_COST_GROWTH)
    return max(100, int(round(scaled / 100.0)) * 100)

def scan_location(lat: float, lng: float, scanner_level: int = 0, mine_count: int = 0) -> list:
    found = []
    for mine_id in _RES_ORDER:
        true_quality = resource_quality_noise(lat, lng, mine_id)
        if true_quality < 1.0:
            continue
        found.append((mine_id, true_quality))

    if not found:
        return []

    found.sort(key=lambda x: -x[1])
    results = []
    for mine_id, true_q in found:
        base_cost = MINE_TYPES[mine_id]["cost"]
        results.append({
            "mine_item_id": mine_id,
            "res_item_id":  MINE_TYPES[mine_id]["res"],
            "quality":      round(true_q),
            "true_quality": round(true_q),
            "build_cost":   mine_scaled_cost(base_cost, mine_count),
            "min_level":    MINE_TYPES[mine_id]["lvl"],
        })
    return results

# ── Locale / Config cache ───────────────────────────────────────────────────────

LOCALE_OVERRIDES: dict = {
    "Key_login_email":              "Company name",
    "Key_email":                    "Company name",
    "Key_login_alreadyregisteredinfo": "Enter your company name:",
    "Key_login_info":               "Register your company:",
    "Key_login_welcome":            "Sign in / register:",
    "Key_login_loginfailed":        "Company not found. Register first.",
    "Key_login_emailalreadyexists": "Company name already taken.",
    "Key_Registrationwithemailpassword": "Register",
    "Key_Signinregisterwithemailpassword": "Sign in / register",
    "Key_login_emailbest":          " ",
    "Key_Confirmemail":             " ",
    "Key_login_passwort":           " ",
    "Key_Password":                 " ",
    "Key_login_passwortbest":       " ",
    "Key_ConfirmPassword":          " ",
    "Key_ForgotPassword":           " ",
    "Key_loginscreen_pwdvergessen": " ",
    "Key_hint_passwordresettext":   " ",
    "Key_Passwordstrength":         " ",
    "Key_splash_but_resendconfemail": " ",
    "Key_ErrEmail":                 None,
    "Key_ErrEmailValid":            None,
    "Key_ErrEmailNotMatch":         None,
    "Key_ErrPassword":              None,
    "Key_ErrPasswordNotMatch":      None,
    "Key_ErrPasswordValid":         None,
    "Key_insertvalidemail":         None,
    "Key_login_emailnotvalid":      None,
    "Key_login_missingfields":      " ",
    "Key_login_passbestfailed":     None,
    "Key_keinaccountmitemail":      None,
    "Key_pleasetypeemailagain":     " ",
    "Key_pleasetypepasswordagain":  " ",
    "Key_login_companynamenotvalid": None,
    "Key_ErrCompanyName":           None,
    "Key_login_useralreadyexists":  None,
}

_config_cache: bytes | None = None
_locale_cache: dict[str, bytes] = {}

_FALLBACK_CONFIG = [
    {"key": "maintenance",           "value": "false"},
    {"key": "minversion",            "value": 8000},
    {"key": "attackRange",           "value": 200},
    {"key": "attackRangeSteps",      "value": 20},
    {"key": "attackPrimBeuteFaktor", "value": 5},
    {"key": "scannerRadius",         "value": 200},
    {"key": "scandroneRange",        "value": 400},
    {"key": "minimalBuildingSpace",  "value": 30},
    {"key": "randomPaketLootDistanceLimit", "value": 250},
    {"key": "idlelim",               "value": 60},
    {"key": "scmax",                 "value": 10000},
    {"key": "mID",                   "value": SERVER_MID},
    {"key": "rt",                    "value": 0},
]

def apply_locale_overrides(raw: bytes) -> bytes:
    locale = {}
    try:
        try:
            locale = json.loads(zlib.decompress(raw).decode("utf-8"))
        except Exception:
            locale = json.loads(raw.decode("utf-8", errors="replace"))
        if not isinstance(locale, dict):
            locale = {}
    except Exception:
        locale = {}
    for k, v in LOCALE_OVERRIDES.items():
        if v is None:
            locale.pop(k, None)
        else:
            locale[k] = v
    return zlib_bytes(locale)

# ── Proxy helper ───────────────────────────────────────────────────────────────

UPSTREAM_HEADERS_DROP = {"host","via","x-forwarded-for","x-forwarded-host",
                          "x-forwarded-proto","transfer-encoding","content-length"}

async def proxy_to_original(request: Request, body: bytes) -> Response:
    if not (UPSTREAM_PROXY_FROM and UPSTREAM_PROXY_TO):
        return Response(content=b'{"error": "not found"}', status_code=404,
                        media_type="application/json")
    forwarded_host = request.headers.get("x-forwarded-host",
                                          request.headers.get("host", ""))
    upstream_host = forwarded_host.replace(UPSTREAM_PROXY_FROM, UPSTREAM_PROXY_TO)
    path = request.url.path
    upstream_url = f"https://{upstream_host}{path}"
    if request.url.query:
        upstream_url += f"?{request.url.query}"
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in UPSTREAM_HEADERS_DROP}
    headers["host"] = upstream_host
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=10.0) as client:
            resp = await client.request(method=request.method, url=upstream_url,
                                        headers=headers, content=body)
            h = dict(resp.headers)
            h.pop("content-encoding", None)
            h.pop("transfer-encoding", None)
            return Response(content=resp.content, status_code=resp.status_code, headers=h)
    except Exception as e:
        return Response(content=json.dumps({"error": str(e)}).encode(), status_code=502)

# ── Auth ────────────────────────────────────────────────────────────────────────

_VALID_NAME = re.compile(r"^[a-zA-Z0-9 .,\[\]()\-]{1,20}$")

def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "?"

@app.post("/api/v1/auth/session")
async def auth_session(request: Request):
    """mode=login: sign in to an existing account. mode=register: create a new account
    (fails if the name is taken). No mode: sign in, or register if the name is free.
    Returns {hID, sid, created}."""
    _, form = await read_form(request)
    name = (form.get("name") or "").strip()
    password = form.get("password") or ""
    mode = form.get("mode", "")
    if not _VALID_NAME.match(name):
        return json_resp({"error": "invalid_name",
                          "message": "Name: 1-20 letters, digits, spaces and . , [ ] ( ) -"})
    canon = norm_name(name)
    ip_key, name_key = f"ip:{_client_ip(request)}", f"name:{canon}"
    if auth.limiter.blocked(ip_key, name_key):
        return Response(content=json.dumps({"error": "rate_limited",
                                            "message": "Too many attempts. Try again later."}).encode(),
                        status_code=429, media_type="application/json")
    problem = auth.password_problem(password)
    with get_db() as conn:
        row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (canon,)).fetchone()
        created = False
        if row and mode == "register":
            return json_resp({"error": "name_taken",
                              "message": "That company name is taken. Choose another, or log in."})
        if not row and mode == "login":
            return json_resp({"error": "not_found",
                              "message": "No company with that name. Check the name or register."})
        if not row:
            bad_name = names.name_problem(name)        # owner 2026-10-23: no rude or misleading names
            if bad_name:
                return json_resp({"error": "invalid_name", "message": bad_name})
            if problem:
                return json_resp({"error": "weak_password", "message": problem})
            hid = new_hid()
            conn.execute("INSERT INTO players(hID,company_name,credits,wa) VALUES(?,?,?,100)", (hid, name, STARTING_CREDITS))
            auth.set_password(conn, hid, password)
            created = True
        else:
            hid = row["hID"]
            stored = auth.get_hash(conn, hid)
            if stored is None:
                if not auth.LEGACY_CLAIM:
                    return json_resp({"error": "no_password",
                                      "message": "This account has no password yet. Ask the server admin."})
                if problem:
                    return json_resp({"error": "weak_password", "message": problem})
                auth.set_password(conn, hid, password)
            elif not auth.verify_password(password, stored):
                auth.limiter.fail(ip_key, name_key)
                return Response(content=json.dumps({"error": "wrong_password",
                                                    "message": "Wrong company name or password."}).encode(),
                                status_code=401, media_type="application/json")
        # signing in cancels a scheduled account deletion (GDPR delay, systems/account.py)
        deletion_cancelled = conn.execute("UPDATE players SET delete_at=NULL WHERE hID=? AND delete_at IS NOT NULL",
                                          (hid,)).rowcount == 1
        conn.commit()
        sweep = getattr(SYSTEM_HELPERS, "ACCOUNT_SWEEP", None)
        if sweep:
            with econ.tx(conn):
                sweep(conn)
    auth.limiter.reset(name_key)
    if created:
        log_entry({"ts": utcnow_iso(), "endpoint": "authSession", "created": True, "hID": hid})
    return json_resp({"hID": hid, "sid": make_sid(hid), "created": created, "deletionCancelled": deletion_cancelled})

@app.post("/api/v1/auth/password")
async def auth_change_password(request: Request):
    """Change the signed-in player's password. Requires the current password."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return Response(content=b'{"error": "unauthorized", "message": "Please sign in again."}',
                        status_code=401, media_type="application/json")
    ip_key, hid_key = f"ip:{_client_ip(request)}", f"pw:{hid}"
    if auth.limiter.blocked(ip_key, hid_key):
        return Response(content=json.dumps({"error": "rate_limited",
                                            "message": "Too many attempts. Try again later."}).encode(),
                        status_code=429, media_type="application/json")
    new = form.get("new_password") or ""
    problem = auth.password_problem(new)
    if problem:
        return json_resp({"error": "weak_password", "message": problem})
    with get_db() as conn:
        stored = auth.get_hash(conn, hid)
        if stored is not None and not auth.verify_password(form.get("old_password") or "", stored):
            auth.limiter.fail(ip_key, hid_key)
            return Response(content=b'{"error": "wrong_password", "message": "Current password is wrong."}',
                            status_code=401, media_type="application/json")
        auth.set_password(conn, hid, new)
        conn.commit()
    auth.limiter.reset(hid_key)
    return json_resp({"ok": True})

@app.post("/flut23/playerLogin.php")
async def player_login(request: Request):
    if not auth.legacy_allowed():
        return json_resp([])  # name-only login disabled; use /api/v1/auth/session
    _, form = await read_form(request)
    raw_name = (form.get("userEmail") or "").strip()
    key = norm_name(raw_name)
    with get_db() as conn:
        row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (key,)).fetchone()
        # Once a player has set a password, name-only login can't open the account.
        if row and auth.secure() and auth.get_hash(conn, row["hID"]) is not None:
            row = None
    if not row:
        return json_resp([])
    return json_resp([{"hID": row["hID"], "active": 1}])

@app.post("/flut23/playerNew.php")
async def player_new(request: Request):
    if not auth.legacy_allowed():
        return plain_resp("")  # passwordless registration disabled; use /api/v1/auth/session
    _, form = await read_form(request)
    display = (form.get("userName") or "").strip()
    email   = (form.get("userEmail") or "").strip()
    canon   = norm_name(display or email)
    if not canon:
        return plain_resp("")
    with get_db() as conn:
        ex = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (canon,)).fetchone()
        if ex:
            if auth.secure() and auth.get_hash(conn, ex["hID"]) is not None:
                return plain_resp("")  # password-protected account
            return plain_resp(ex["hID"])
        hid = new_hid()
        conn.execute("INSERT INTO players(hID,company_name,credits) VALUES(?,?,?)", (hid, display or email, STARTING_CREDITS))
        conn.commit()
    log_entry({"ts": utcnow_iso(), "endpoint": "playerNew", "name": canon, "hID": hid})
    return plain_resp(hid)

@app.post("/flut23/sendMailConfirmEmail.php")
async def send_mail_confirm(request: Request):
    return plain_resp("1")

@app.post("/flut23/fcmRegister.php")
async def fcm_register(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    token = form.get("token", "").strip()
    platform = form.get("platform", "android")
    if hid and token:
        with get_db() as conn:
            conn.execute(
                "INSERT INTO fcm_tokens(hid, token, platform, updated_at) VALUES(?,?,?,?) "
                "ON CONFLICT(hid, token) DO UPDATE SET updated_at=excluded.updated_at, platform=excluded.platform",
                (hid, token, platform, utcnow_iso()))
            conn.commit()
    return plain_resp("OK")

@app.post("/flut23/notifPrefs.php")
async def notif_prefs(request: Request):
    """Save or retrieve notification preferences server-side."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1})
    with get_db() as conn:
        if form.get("action") == "get":
            row = conn.execute("SELECT * FROM notif_prefs WHERE hid=?", (hid,)).fetchone()
            if not row:
                return zlib_resp({"err": 0, "enabled": 1, "mineWarning": 1,
                                  "mineDestroyed": 1, "whAlmostFull": 1, "whFull": 1})
            return zlib_resp({"err": 0,
                              "enabled": row["enabled"],
                              "mineWarning": row["mine_warning"],
                              "mineDestroyed": row["mine_destroyed"],
                              "whAlmostFull": row["wh_almost_full"],
                              "whFull": row["wh_full"]})
        # Save
        conn.execute(
            "INSERT INTO notif_prefs(hid, enabled, mine_warning, mine_destroyed, wh_almost_full, wh_full) "
            "VALUES(?,?,?,?,?,?) ON CONFLICT(hid) DO UPDATE SET "
            "enabled=excluded.enabled, mine_warning=excluded.mine_warning, "
            "mine_destroyed=excluded.mine_destroyed, wh_almost_full=excluded.wh_almost_full, "
            "wh_full=excluded.wh_full",
            (hid,
             int(form.get("enabled", 1)),
             int(form.get("mineWarning", 1)),
             int(form.get("mineDestroyed", 1)),
             int(form.get("whAlmostFull", 1)),
             int(form.get("whFull", 1))))
        conn.commit()
    return zlib_resp({"err": 0})

@app.post("/flut23/ping.php")
async def ping(request: Request):
    return plain_resp("1")

# ── Player data ─────────────────────────────────────────────────────────────────

def build_player_data(conn, row, include_mines: bool = True) -> dict:
    hid = row["hID"]
    wa = row["wa"] if row["wa"] is not None else 80
    # Run hourly events (disease spreading, random events)
    maybe_run_events(conn, hid, wa)
    # Collect all mine outputs first
    cap = wh_capacity(row["wh_level"])
    collect_mines_bulk(conn, hid)

    # Warehouse
    wh_rows = conn.execute("SELECT item_id,qty FROM warehouse WHERE hid=?", (hid,)).fetchall()
    lager = {str(r["item_id"]): round(r["qty"], 2) for r in wh_rows}

    # HQ
    hq_row = conn.execute("SELECT * FROM hq WHERE hid=?", (hid,)).fetchone()
    hq = None
    if hq_row:
        dep_rows = conn.execute(
            "SELECT item_id, amount FROM hq_deposits WHERE hid=? AND target_level=?",
            (hid, hq_row["level"] + 1)).fetchall()
        hq_deposits = {str(d["item_id"]): d["amount"] for d in dep_rows}
        hq = {"lat": hq_row["lat"], "lng": hq_row["lng"], "lvl": hq_row["level"],
              "deposits": hq_deposits, "sub_lvl": hq_sub_level(conn, hid, hq_row["level"]),
              "luxuryPoints": luxury_points_of(conn, hid)}

    # Factories
    now = datetime.datetime.utcnow()
    facts = []
    for f in conn.execute("SELECT * FROM factories WHERE hid=?", (hid,)).fetchall():
        fire_until = None
        if f["fire_until"]:
            fu = datetime.datetime.fromisoformat(f["fire_until"])
            if now < fu:
                fire_until = f["fire_until"]
        booster_until = None
        booster_item = None
        if f["booster_until"]:
            bu = datetime.datetime.fromisoformat(f["booster_until"])
            if now < bu:
                booster_until = f["booster_until"]
                booster_item = f["booster_item"]
        sb_entry = SPECIAL_BUILDINGS.get(f["item_id"])
        facts.append({
            "fID": f["factory_id"],
            "itemID": f["item_id"],
            "lvl": f["level"],
            "isSpecial": sb_entry is not None,
            "maxLvl": sb_entry["max_level"] if sb_entry else 5,
            "prodItem": f["prod_item"],
            "prodAmt": f["prod_amount"],
            "prodStart": f["prod_start"],
            "prodEnd": f["prod_end"],
            "fireUntil": fire_until,
            "boosterItem": booster_item,
            "boosterUntil": booster_until,
        })

    # Mines after collection. Lite clients (include_mines=False) get aggregates only and
    # load mine details on demand (mineList / minesNear) — keeps this call fast at any count.
    mine_list = mine_rows(conn, hid) if include_mines else []
    stats = mine_stats(conn, hid)

    # Tech center level and Haulage Firm level
    tc_level = 0
    haul_level = 0
    for f in facts:
        if f["itemID"] == 116:
            tc_level = f["lvl"]
        elif f["itemID"] == 123:
            haul_level = f["lvl"]
    _tc_quality_map = [26, 34, 42, 49, 56, 63, 71, 79, 85, 93, 100]
    tc_max_quality = _tc_quality_map[min(tc_level, 10)]

    wh_used = round(wh_total(conn, hid), 2)
    return {
        "hID":    hid,
        "pN":     row["company_name"],
        "crd":    row["credits"],
        # XP stays on the server (owner 2026-10-23); the app only gets the progress to the next level
        "lvlProgress": level_progress(row["xp"] or 0, row["level"] or 1),
        "lvl":    row["level"],
        "teamID": row["team_id"],
        "whLvl":  row["wh_level"],
        "whCap":  int(cap),
        "whUsed": wh_used,
        "wa":     wa,
        "tcLvl":  tc_level,
        "tcMaxQ": tc_max_quality,
        "haulLvl": haul_level,
        "remoteNext": remote_build_next(conn, hid),     # next drone construction (ISO UTC) or None
        "mines":  mine_list,
        "mineStats": stats,
        "minesOmitted": not include_mines,
        "hq":     hq,
        "lager":  lager,
        "facts":  facts,
        "contacts": [],
        "quests": [],
    }

@app.post("/flut23/playerGetData.php")
async def player_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    lite = form.get("lite", "") == "1"   # newer apps: no full mine list

    def work():
        with get_db() as conn:
            row = conn.execute("SELECT * FROM players WHERE hID=?", (hid,)).fetchone()
            if not row:
                return []
            record_daily_activity(conn, hid)
            data = build_player_data(conn, row, include_mines=not lite)
            conn.commit()
            return [data]
    # Off the event loop, so one big player doesn't stall everyone else.
    return zlib_resp(await run_in_threadpool(work))

# ── Scanner ─────────────────────────────────────────────────────────────────────

LOCAL_CONSTRUCTION_RANGE_M = 100   # metres from player position to hex center for local build
GPS_TOLERANCE_M = 15               # allowance for GPS jitter between the app's check and the request
DRONE_RANGE_M              = 5000  # maximum remote construction range

@app.post("/flut23/scannerPayscan.php")
async def scanner_payscan(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat = float(form.get("lat", 0))
        lng = float(form.get("lng", 0))
        # player_lat/player_lng: GPS position of the player (same as lat/lng for non-drone scans;
        # may differ for drone scans where the player aims at a distant location).
        player_lat = float(form.get("player_lat", lat))
        player_lng = float(form.get("player_lng", lng))
    except (ValueError, TypeError):
        return zlib_resp({"err": 1, "msg": "invalid coordinates"})
    is_drone = form.get("drone", "0") == "1"

    with get_db() as conn:
        row = get_player(conn, hid)
        if not row:
            return zlib_resp({"err": 2, "msg": "player not found"})
        try:
            with econ.tx(conn):
                tc_level = building_level(conn, hid, 116)
                mine_count = conn.execute("SELECT COUNT(*) FROM mines WHERE owner_hid=?", (hid,)).fetchone()[0]
                # owner 2026-10-23: free below level 5, then 25 × level² × (1 + 10 % per Tech Center level)
                scan_cost = economy.scan_cost(row["level"] or 1, tc_level)
                drone_range = None
                scan_dist = haversine_m(player_lat, player_lng, lat, lng)
                if not is_drone and scan_dist > LOCAL_CONSTRUCTION_RANGE_M + GPS_TOLERANCE_M:
                    raise econ.GameError("out_of_range", f"Scan spot is {scan_dist:.0f} m away. Local scans reach "
                                                         f"{LOCAL_CONSTRUCTION_RANGE_M} m; use a drone scan.")
                check_travel(conn, hid, player_lat, player_lng)
                if is_drone:
                    dr_level = building_level(conn, hid, 119)
                    if dr_level < 1:
                        raise econ.GameError("out_of_range", "Drone scans need a Drone Research building")
                    drone_range = DRONE_SCAN_RANGES[max(0, min(dr_level - 1, len(DRONE_SCAN_RANGES) - 1))]
                    if scan_dist > drone_range + GPS_TOLERANCE_M:
                        raise econ.GameError("out_of_range", f"Scan spot is {scan_dist / 1000:.1f} km away. Your "
                                                             f"drones reach {drone_range / 1000:.1f} km.")
                    # owner 2026-10-24: a drone scan uses up one Scan Drone and costs no credits
                    if not DRONE_OVERRIDE:
                        try:
                            econ.take(conn, hid, 117, 1, "drone_scan")
                        except econ.GameError:
                            raise econ.GameError("no_drone", "You need a Scan Drone (you have 0)")
                        award_sink(conn, hid, res={117: 1})
                    scan_cost = 0
                else:
                    try:
                        econ.debit(conn, hid, scan_cost, "scan")
                    except econ.GameError:
                        raise econ.GameError("insufficient_credits", f"Not enough credits (need ꞓ{scan_cost:,})")
                    award_sink(conn, hid, credits=scan_cost)
                results = scan_location(lat, lng, tc_level, mine_count)
                add_proto(conn, hid, "scan", {"lat": lat, "lng": lng, "results": len(results), "drone": is_drone})
                econ.emit(conn, "scan", hid, {"drone": is_drone}, public=False)
        except econ.GameError as e:
            code = {"out_of_range": 6 if not is_drone else 7, "no_drone": 5, "insufficient_credits": 3}.get(e.code, 8)
            return legacy_error(e, code)

    # Issue one single-use prospect token covering all resources found in this scan.
    # Store the player's GPS position so mineNew can determine local vs remote authoritatively.
    old_tok = _player_tokens.get(hid)
    if old_tok:
        _scan_tokens.pop(old_tok, None)
    item_ids_found = [r["mine_item_id"] for r in results if "mine_item_id" in r]
    prospect_token: str | None = None
    if item_ids_found:
        prospect_token = str(uuid.uuid4())
        _scan_tokens[prospect_token] = {
            "hid": hid, "lat": lat, "lng": lng,
            "player_lat": player_lat, "player_lng": player_lng,
            # owner 2026-10-20: the WIP hex stays buildable until the scan is reset (2 h safety limit)
            "item_ids": item_ids_found, "expires": time.time() + 7200,
        }
        _player_tokens[hid] = prospect_token
    else:
        _player_tokens.pop(hid, None)

    return zlib_resp({
        "err": 0,
        "lat": lat,
        "lng": lng,
        "cost": scan_cost,
        "tcLevel": tc_level,
        "scanRadius": TC_CONFIG[min(tc_level, 10)]["radius"],
        "results": results,
        "minDist": 30,
        "droneRange": drone_range,
        "heatmap": _scan_heatmap(lat, lng, tc_level),
        "prospect_token": prospect_token,
    })

# ── Mine management ─────────────────────────────────────────────────────────────

@app.post("/flut23/mineNew.php")
async def mine_new(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat            = float(form.get("lat", 0))
        lng            = float(form.get("lng", 0))
        item_id        = int(form.get("itemID", 0))
        prospect_token = form.get("prospect_token", "")
    except (ValueError, TypeError):
        return zlib_resp({"err": 1})

    # Validate the prospect token (not consumed yet — all checks run before consumption).
    stored = _scan_tokens.get(prospect_token) if prospect_token else None
    if not stored or stored["hid"] != hid:
        return zlib_resp({"err": 9, "msg": "Scan required before building"})
    if time.time() > stored["expires"]:
        _scan_tokens.pop(prospect_token, None)
        _player_tokens.pop(hid, None)
        return zlib_resp({"err": 9, "msg": "Prospecting result expired. Scan again."})
    if item_id not in stored["item_ids"]:
        return zlib_resp({"err": 9, "msg": "This resource was not found in your last scan"})
    # 100m tolerance covers hex-snap drift (nearest valid adjacent slot can be ~52m from scan centre).
    if haversine_m(lat, lng, stored["lat"], stored["lng"]) > 100:
        return zlib_resp({"err": 9, "msg": "Build location is too far from the scanned area"})

    cur_lat_raw = form.get("cur_lat")
    cur_lng_raw = form.get("cur_lng")
    if cur_lat_raw is None or cur_lng_raw is None:
        fallback_lat = stored.get("player_lat")
        fallback_lng = stored.get("player_lng")
        if fallback_lat is None or fallback_lng is None or \
                (fallback_lat == stored["lat"] and fallback_lng == stored["lng"]):
            return zlib_resp({"err": 1, "msg": "Player GPS required for construction"})
        player_lat, player_lng = float(fallback_lat), float(fallback_lng)
    else:
        try:
            player_lat = float(cur_lat_raw)
            player_lng = float(cur_lng_raw)
        except (ValueError, TypeError):
            return zlib_resp({"err": 1, "msg": "Invalid player GPS"})

    mt = MINE_TYPES.get(item_id)
    if not mt:
        return zlib_resp({"err": 2, "msg": "unknown mine type"})
    # quality always comes from the server's own resource field (never from the app)
    true_quality = resource_quality_at(lat, lng, item_id)
    if true_quality < 1.0:
        return zlib_resp({"err": 9, "msg": "There is (almost) none of this resource on this spot"})
    final_quality = max(1, round(true_quality))

    dist_to_mine = haversine_m(player_lat, player_lng, lat, lng)
    is_remote = dist_to_mine > LOCAL_CONSTRUCTION_RANGE_M
    DRONE_ITEM_ID, DIAMOND_ITEM_ID = 117, 42

    conn = get_db()
    try:
        with econ.tx(conn):
            row = get_player(conn, hid)
            if not row:
                raise econ.GameError("no_player", "Player not found")
            if row["level"] < mt["lvl"]:
                raise econ.GameError("level", f"requires level {mt['lvl']}")
            check_travel(conn, hid, player_lat, player_lng)
            dr_level = building_level(conn, hid, 119)
            dr_idx = max(0, min(dr_level - 1, len(DRONE_SCAN_RANGES) - 1))
            build_range = DRONE_SCAN_RANGES[dr_idx] if dr_level > 0 else LOCAL_CONSTRUCTION_RANGE_M
            if dist_to_mine > build_range + GPS_TOLERANCE_M:
                raise econ.GameError("range", f"Building failed: this spot is {dist_to_mine:.0f} m from you, "
                                              f"your range is {build_range:.0f} m")
            mine_count = conn.execute("SELECT COUNT(*) FROM mines WHERE owner_hid=?", (hid,)).fetchone()[0]
            if mine_count >= MAX_MINES_PER_PLAYER:
                raise econ.GameError("max_mines", "Maximum amount of mines reached.")
            if is_remote:
                if dr_level < 10:
                    raise econ.GameError("remote", f"Remote construction requires Drone Research level 10 "
                                                   f"(you have level {dr_level})")
                rh = remote_build_hours(conn, hid)
                if econ.count_events(conn, hid, "remote_build", (datetime.datetime.utcnow() - datetime.timedelta(
                        hours=rh)).isoformat()):
                    raise econ.GameError("cooldown", f"Remote construction is possible once every {rh} hours")
            # Hex-aware proximity check against ALL mines (inside the write lock: no concurrent insert)
            dlat = 40 / 111320.0
            dlng = dlat / max(0.01, math.cos(math.radians(lat)))
            for m in conn.execute("SELECT lat,lng FROM mines WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?",
                                  (lat - dlat, lat + dlat, lng - dlng, lng + dlng)):
                if haversine_m(lat, lng, m["lat"], m["lng"]) < hex_min_dist(lat, lng, m["lat"], m["lng"]) - 0.1:
                    raise econ.GameError("overlap", "Building failed: this spot overlaps an existing mine. "
                                                    "Move the crosshair to a free hex.")
            actual_cost = mine_scaled_cost(mt["cost"], mine_count)
            try:
                econ.debit(conn, hid, actual_cost, "mine_build")
            except econ.GameError:
                raise econ.GameError("insufficient_credits", "not enough credits")
            if is_remote:
                try:
                    econ.take(conn, hid, DRONE_ITEM_ID, 1, "remote_build")
                    econ.take(conn, hid, DIAMOND_ITEM_ID, 1, "remote_build")
                except econ.GameError:
                    raise econ.GameError("remote_items", "Remote build requires 1× Scan Drone and 1× Giant Diamond")
            # consume the token last (a failed build keeps it)
            if _scan_tokens.pop(prospect_token, None) is None:
                raise econ.GameError("token", "Build token already used (concurrent request). Please scan again.")
            _player_tokens.pop(hid, None)
            mid = new_id()
            conn.execute(
                "INSERT INTO mines(mine_id,owner_hid,lat,lng,item_id,quality,last_coll,created_at,paid) "
                "VALUES(?,?,?,?,?,?,?,?,?)",
                (mid, hid, lat, lng, item_id, final_quality, utcnow_iso(), utcnow_iso(), actual_cost))
            econ.emit(conn, "mine_built", hid, {"mID": mid, "itemID": item_id}, public=False)
            if is_remote:
                econ.emit(conn, "remote_build", hid, {"mID": mid}, public=False)
            # XP: the build cost minus what demolishing would give back (+ the drone used remotely)
            award_sink(conn, hid, credits=actual_cost - mt["cost"] * economy.DEMOLISH_REFUND,
                       res={DRONE_ITEM_ID: 1} if is_remote else None)
            add_proto(conn, hid, "newmine", {"mID": mid, "itemID": item_id, "lat": lat, "lng": lng, "remote": is_remote})
    except econ.GameError as e:
        conn.close()
        code = {"level": 4, "range": 11, "max_mines": 7, "remote": 10, "cooldown": 12, "overlap": 6,
                "insufficient_credits": 5, "remote_items": 8, "token": 9, "no_player": 3}.get(e.code, 1)
        return legacy_error(e, code)
    conn.close()
    return zlib_resp({"err": 0, "mID": mid, "cost": actual_cost, "remote": is_remote, "diamondUsed": is_remote,
                      "quality": final_quality})

@app.post("/flut23/mineGetData.php")
async def mine_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mine_id = form.get("mID", "")
    with get_db() as conn:
        mine = conn.execute("SELECT * FROM mines WHERE mine_id=?", (mine_id,)).fetchone()
        if not mine:
            return zlib_resp({"err": 1})
        collect_mine(conn, mine)
        mine = conn.execute("SELECT * FROM mines WHERE mine_id=?", (mine_id,)).fetchone()
        conn.commit()
        if not mine:
            return zlib_resp({"err": 2, "msg": "Mine destroyed"})
        mt = MINE_TYPES.get(mine["item_id"], {})
        player = get_player(conn, mine["owner_hid"])
        tu1 = (mine["tu1"] or 0) if "tu1" in mine.keys() else 0
        tu2 = (mine["tu2"] or 0) if "tu2" in mine.keys() else 0
        tu3 = (mine["tu3"] or 0) if "tu3" in mine.keys() else 0
        tu4 = (mine["tu4"] or 0) if "tu4" in mine.keys() else 0
        tu_factor = 1.0 + (tu1*1.0 + tu2*1.0 + tu3*1.5 + tu4*1.5) / 100.0
        rate = (mt.get("rate", 0) * mine["quality"]/100.0 * mine["condition"]/100.0
                * tu_factor * float(mine["level"]) * hq_boost_for_mine(conn, mine))
    return zlib_resp({
        "err": 0,
        "mID": mine["mine_id"],
        "ownerHID": mine["owner_hid"],
        "ownerName": player["company_name"] if player else "",
        "lat": mine["lat"],
        "lng": mine["lng"],
        "itemID": mine["item_id"],
        "resID": mt.get("res", 0),
        "quality": mine["quality"],
        "condition": mine["condition"],
        "level": mine["level"],
        "tu1": tu1, "tu2": tu2, "tu3": tu3, "tu4": tu4,
        "defence": mine["defence"],
        "ratePerHour": round(rate, 1),
        "createdAt": mine["created_at"],
    })

@app.post("/flut23/mineDensity.php")
async def mine_density(request: Request):
    """Zoom-aware mine density aggregation for cloud rendering.
    Returns deterministic cell centroids {lat, lng, count} — count is the mine count
    in each cell. Client renders with BlendMode.lighten + viewport normalization so
    cloud intensity is bounded and consistent regardless of density or zoom level."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat1 = float(form.get("lat1", -90)); lng1 = float(form.get("lng1", -180))
        lat2 = float(form.get("lat2",  90)); lng2 = float(form.get("lng2",  180))
        zoom = float(form.get("z", 10))
    except Exception:
        return zlib_resp({"err": 1})

    # Cell sizes chosen to show actual mine distribution at each zoom level.
    # Coarse cells only at world zoom (< 4); fine cells everywhere else so
    # mine clusters in a city/country appear as distinct clouds, not one dot.
    if zoom < 4:      cell = 2.0
    elif zoom < 7:    cell = 0.5
    elif zoom < 10:   cell = 0.1
    elif zoom < 12:   cell = 0.05
    elif zoom < 13.5: cell = 0.02
    else:             cell = 0.01

    lat1 = max(-90.0, min(lat1, 90.0)); lat2 = max(-90.0, min(lat2, 90.0))
    lng1 = max(-180.0, min(lng1, 180.0)); lng2 = max(-180.0, min(lng2, 180.0))

    with get_db() as conn:
        rows = conn.execute(
            "SELECT lat, lng FROM mines WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?",
            (lat1, lat2, lng1, lng2)).fetchall()

    cells: dict = {}
    for m in rows:
        lat_c = math.floor(m["lat"] / cell) * cell + cell / 2
        lng_c = math.floor(m["lng"] / cell) * cell + cell / 2
        key = (round(lat_c, 6), round(lng_c, 6))
        if key not in cells:
            cells[key] = [0.0, 0.0, 0]  # lat_sum, lng_sum, count
        cells[key][0] += m["lat"]
        cells[key][1] += m["lng"]
        cells[key][2] += 1

    # Return actual mine-position centroid (mean lat/lng of mines in cell), not the
    # cell's geographic midpoint. At coarse zoom, cell midpoints can be 100s of km
    # from where the mines actually are, causing clouds to appear in wrong locations.
    return zlib_resp([{
        "lat": round(v[0] / v[2], 6),
        "lng": round(v[1] / v[2], 6),
        "count": v[2]
    } for v in cells.values()])


MINE_DOTS_MAX = 60000

@app.post("/flut23/mineDots.php")
async def mine_dots(request: Request):
    """Every mine's position in a bbox, for per-mine smoke clouds at far zoom.
    Response: zlib JSON flat array [lat, lng, lat, lng, ...] rounded to ~1 m.
    Above MINE_DOTS_MAX mines the result is a deterministic rowid-stride subset, so the
    same mines stay visible between requests (no flicker)."""
    _, form = await read_form(request)
    if not hid_from_sid(form.get("sid", "")):
        return zlib_resp([])
    try:
        lat1 = max(-90.0, float(form.get("lat1", -90))); lat2 = min(90.0, float(form.get("lat2", 90)))
        lng1 = max(-180.0, float(form.get("lng1", -180))); lng2 = min(180.0, float(form.get("lng2", 180)))
    except Exception:
        return zlib_resp([])
    q = "FROM mines WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?"
    args = (lat1, lat2, lng1, lng2)
    with get_db() as conn:
        n = conn.execute("SELECT COUNT(*) " + q, args).fetchone()[0]
        stride = max(1, -(-n // MINE_DOTS_MAX))
        if stride == 1:
            rows = conn.execute("SELECT lat, lng " + q, args).fetchall()
        else:
            rows = conn.execute("SELECT lat, lng " + q + " AND rowid % ? = 0", args + (stride,)).fetchall()
    flat = []
    for r in rows:
        flat.append(round(r[0], 5))
        flat.append(round(r[1], 5))
    return Response(content=zlib.compress(json.dumps(flat, separators=(",", ":")).encode(), 6),
                    headers={"content-type": "application/octet-stream"})


@app.post("/flut23/mineLoadMarkers.php")
async def mine_load_markers(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat1 = float(form.get("lat1", -90)); lng1 = float(form.get("lng1", -180))
        lat2 = float(form.get("lat2", 90));  lng2 = float(form.get("lng2", 180))
    except Exception:
        lat1,lng1,lat2,lng2 = -90,-180,90,180

    with get_db() as conn:
        mines = conn.execute(
            "SELECT m.*, p.company_name as owner_name FROM mines m "
            "JOIN players p ON m.owner_hid=p.hID "
            "WHERE m.lat BETWEEN ? AND ? AND m.lng BETWEEN ? AND ? "
            "LIMIT 1000",
            (lat1, lat2, lng1, lng2)).fetchall()
        refs = public_refs(conn, {m["owner_hid"] for m in mines}, hid)
    markers = []
    for m in mines:
        mt = MINE_TYPES.get(m["item_id"], {})
        markers.append({
            "mID":       m["mine_id"],
            "ownerHID":  refs[m["owner_hid"]],   # public id for other players (see public_refs)
            "ownerName": m["owner_name"],
            "lat":       m["lat"],
            "lng":       m["lng"],
            "itemID":    m["item_id"],
            "resID":     mt.get("res", 0),
            "cond":      current_condition(m),      # real, decayed condition (server-side)
            "lvl":       m["level"],
            "isMine":    m["owner_hid"] == hid,
        })
    return zlib_resp(markers)

@app.post("/flut23/mineDelete.php")
async def mine_delete(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mine_id = form.get("mID", "")
    with get_db() as conn:
        with econ.tx(conn):
            mine = conn.execute("SELECT * FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).fetchone()
            if not mine:
                return zlib_resp({"err": 1})
            # the DELETE is the guard: only one of two simultaneous requests can remove the row
            if conn.execute("DELETE FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).rowcount != 1:
                return zlib_resp({"err": 1})
            refund = demolish_refund(mine)
            econ.credit(conn, hid, refund, "mine_demolish", mine_id)
            add_proto(conn, hid, "demolish", {"mID": mine_id, "refund": refund})
    return zlib_resp({"err": 0, "refund": refund})

def demolish_refund(mine) -> int:
    """10 % of the mine type's BASE cost (owner 2026-10-24: not of the scaled price that was paid)."""
    return int(MINE_TYPES.get(mine["item_id"], {}).get("cost", 0) * economy.DEMOLISH_REFUND)

@app.post("/flut23/mineBulkDelete.php")
async def mine_bulk_delete(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mine_ids = list(dict.fromkeys(i.strip() for i in form.get("mIDs", "").split(",") if i.strip()))
    if not mine_ids:
        return zlib_resp({"err": 1, "msg": "No mine IDs"})
    total_refund = 0
    deleted = 0
    with get_db() as conn:
        with econ.tx(conn):
            for mine_id in mine_ids:
                mine = conn.execute("SELECT * FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).fetchone()
                if not mine or conn.execute("DELETE FROM mines WHERE mine_id=? AND owner_hid=?",
                                            (mine_id, hid)).rowcount != 1:
                    continue
                refund = demolish_refund(mine)
                total_refund += refund
                deleted += 1
                add_proto(conn, hid, "demolish", {"mID": mine_id, "refund": refund})
            econ.credit(conn, hid, total_refund, "mine_demolish")
    return zlib_resp({"err": 0, "deleted": deleted, "refund": total_refund})

@app.post("/flut23/mineMaintAPay.php")
async def mine_maint_pay(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mine_id = form.get("mID", "")
    with get_db() as conn:
        try:
            with econ.tx(conn):
                mine = conn.execute("SELECT * FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).fetchone()
                if not mine:
                    return zlib_resp({"err": 1})
                if current_condition(mine) > 99.00:
                    return zlib_resp({"err": 3, "msg": "Mine condition is too high to repair"})
                # settle pending production at the old condition before restoring to 100
                _, destroyed = collect_mine(conn, mine)
                if destroyed:
                    return zlib_resp({"err": 1, "msg": "Mine was destroyed (condition too low)"})
                mine = conn.execute("SELECT * FROM mines WHERE mine_id=?", (mine_id,)).fetchone()
                repair_cost = compute_repair_cost(conn, mine)
                try:
                    econ.debit(conn, hid, repair_cost, "mine_repair", mine_id)
                except econ.GameError:
                    raise econ.GameError("insufficient_credits", "not enough credits")
                conn.execute("UPDATE mines SET condition=100, last_coll=? WHERE mine_id=?", (utcnow_iso(), mine_id))
                award_sink(conn, hid, credits=repair_cost)
                add_proto(conn, hid, "repair", {"mID": mine_id, "cost": repair_cost})
                econ.emit(conn, "mine_repaired", hid, {"mID": mine_id, "how": "pay"}, public=False)
        except econ.GameError as e:
            return zlib_resp({"err": 2, "msg": e.message, "cost": locals().get("repair_cost")})
    return zlib_resp({"err": 0, "cost": repair_cost})

@app.post("/flut23/mineMaintAKit.php")
async def mine_maint_kit(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mine_id = form.get("mID", "")
    KIT_ITEM_ID = 43
    with get_db() as conn:
        try:
            with econ.tx(conn):
                mine = conn.execute("SELECT * FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).fetchone()
                if not mine:
                    return zlib_resp({"err": 1})
                if current_condition(mine) > 99.00:
                    return zlib_resp({"err": 3, "msg": "Mine condition is too high to repair"})
                if econ.qty_of(conn, hid, KIT_ITEM_ID) < 1:
                    return zlib_resp({"err": 2, "msg": "no maintenance kits"})
                _, destroyed = collect_mine(conn, mine)
                if destroyed:
                    return zlib_resp({"err": 1, "msg": "Mine was destroyed (condition too low)"})
                econ.take(conn, hid, KIT_ITEM_ID, 1, "mine_repair_kit", mine_id)
                conn.execute("UPDATE mines SET condition=100, last_coll=? WHERE mine_id=?", (utcnow_iso(), mine_id))
                award_sink(conn, hid, res={KIT_ITEM_ID: 1})
                add_proto(conn, hid, "repairkit", {"mID": mine_id})
                econ.emit(conn, "mine_repaired", hid, {"mID": mine_id, "how": "kit"}, public=False)
        except econ.GameError as e:
            return zlib_resp({"err": 2, "msg": e.message})
    return zlib_resp({"err": 0})

HAULAGE_FIRM_ID = 123

def boss_range_m(hf_level: int) -> float:
    """The boss range (Haulage Firm): 100 m + 10 m per level, max 200 m. Free repairs and trucks."""
    return min(200.0, 100.0 + 10.0 * max(0, hf_level))

@app.post("/flut23/mineMaintAFree.php")
async def mine_maint_free(request: Request):
    """Free repair while the boss stands next to the mine (within the boss range, GPS validated)."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mine_id = form.get("mID", "")
    with get_db() as conn:
        try:
            lat, lng = econ.parse_pos(form)
            with econ.tx(conn):
                mine = conn.execute("SELECT * FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).fetchone()
                if not mine:
                    return zlib_resp({"err": 1})
                if current_condition(mine) > 99.00:
                    return zlib_resp({"err": 3, "msg": "Mine condition is too high to repair"})
                check_travel(conn, hid, lat, lng)
                rng_m = boss_range_m(building_level(conn, hid, HAULAGE_FIRM_ID))
                econ.require_within(lat, lng, mine["lat"], mine["lng"], rng_m, "mine")
                _, destroyed = collect_mine(conn, mine)
                if destroyed:
                    return zlib_resp({"err": 1, "msg": "Mine was destroyed (condition too low)"})
                conn.execute("UPDATE mines SET condition=100, last_coll=? WHERE mine_id=?", (utcnow_iso(), mine_id))
                add_proto(conn, hid, "repairfree", {"mID": mine_id})
                econ.emit(conn, "mine_repaired", hid, {"mID": mine_id, "how": "boss"}, public=False)
        except econ.GameError as e:
            return zlib_resp({"err": 2, "msg": e.message})
    return zlib_resp({"err": 0})

_MINE_SORTS = {"output": _SQL_RATE_HR, "quality": "m.quality", "condition": "m.condition"}

@app.post("/flut23/mineList.php")
async def mine_list(request: Request):
    """The player's mines (same shape as playerGetData 'mines'), optionally sorted/paged:
    sort=output|quality|condition, asc=1, offset, limit (max 100000)."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1})
    expr = _MINE_SORTS.get(form.get("sort", ""), "m.rowid")
    order = f"{expr} {'ASC' if form.get('asc') == '1' else 'DESC'}, m.rowid" if expr != "m.rowid" else "m.rowid"
    try:
        offset = max(0, int(form.get("offset", 0)))
        limit = min(100000, max(1, int(form.get("limit", 100000))))
    except Exception:
        return zlib_resp({"err": 1})

    def work():
        with get_db() as conn:
            total = conn.execute("SELECT COUNT(*) FROM mines WHERE owner_hid=?", (hid,)).fetchone()[0]
            return {"err": 0, "total": total, "offset": offset,
                    "mines": mine_rows(conn, hid, order=order, limit=limit, offset=offset)}
    return zlib_resp(await run_in_threadpool(work))

@app.post("/flut23/minesNear.php")
async def mines_near(request: Request):
    """The player's own mines within r metres (max 5000) of lat/lng."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat, lng = float(form.get("lat")), float(form.get("lng"))
        r = min(5000.0, max(1.0, float(form.get("r", 50))))
    except Exception:
        return zlib_resp({"err": 1})
    if not hid:
        return zlib_resp({"err": 1})
    dlat = r / 111320.0 * 1.05
    dlng = dlat / max(0.01, math.cos(math.radians(lat)))

    def work():
        with get_db() as conn:
            rows = mine_rows(conn, hid, where="AND m.lat BETWEEN ? AND ? AND m.lng BETWEEN ? AND ?",
                             args=(lat - dlat, lat + dlat, lng - dlng, lng + dlng))
        return {"err": 0, "mines": [m for m in rows if haversine_m(lat, lng, m["lat"], m["lng"]) <= r]}
    return zlib_resp(await run_in_threadpool(work))

@app.post("/flut23/mineBulkRepair.php")
async def mine_bulk_repair(request: Request):
    """Repair many mines in one request. ids = JSON list of mine IDs; mode = pay | kit.
    Same rules per mine as mineMaintAPay / mineMaintAKit, applied in the given order until
    credits or kits run out."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    mode = form.get("mode", "pay")
    try:
        ids = [str(i) for i in json.loads(form.get("ids", "[]"))][:100000]
    except Exception:
        return zlib_resp({"err": 1, "msg": "bad ids"})
    if not hid or not ids or mode not in ("pay", "kit"):
        return zlib_resp({"err": 1})

    def work():
        KIT_ITEM_ID = 43
        with get_db() as conn:
            if not get_player(conn, hid):
                return {"err": 1}
            # Settle pending production at the old condition first (destroys doomed mines).
            destroyed = collect_mines_bulk(conn, hid, only_ids=set(ids))
            conn.execute("BEGIN IMMEDIATE")
            rows = {r["mID"]: {"mine_id": r["mID"], "condition": r["cond"], "cost": r["repairCost"]}
                    for r in mine_rows(conn, hid, where="AND m.mine_id IN (SELECT mine_id FROM _only)")}
            eligible = [rows[i] for i in dict.fromkeys(ids) if i in rows and float(rows[i]["condition"]) <= 99.00]
            player = get_player(conn, hid)
            done, spent = [], 0
            if mode == "pay":
                credits = player["credits"]
                for m in eligible:
                    cost = m["cost"]
                    if credits - spent < cost:
                        break
                    spent += cost
                    done.append((m["mine_id"], cost))
                econ.debit(conn, hid, spent, "mine_repair")        # conditional: never below zero
                award_sink(conn, hid, credits=spent)
            else:
                kits = conn.execute("SELECT COALESCE(qty,0) FROM warehouse WHERE hid=? AND item_id=?",
                                    (hid, KIT_ITEM_ID)).fetchone()
                n = min(len(eligible), int(kits[0]) if kits else 0)
                done = [(m["mine_id"], 0) for m in eligible[:n]]
                if n:
                    econ.take(conn, hid, KIT_ITEM_ID, n, "mine_repair_kit")
                    award_sink(conn, hid, res={KIT_ITEM_ID: n})
            now = utcnow_iso()
            conn.executemany("UPDATE mines SET condition=100, last_coll=? WHERE mine_id=?",
                             [(now, mid) for mid, _ in done])
            for mid, cost in done:
                add_proto(conn, hid, "repair" if mode == "pay" else "repairkit",
                          {"mID": mid, "cost": cost} if mode == "pay" else {"mID": mid})
                econ.emit(conn, "mine_repaired", hid, {"mID": mid, "how": mode}, public=False)
            conn.commit()
            return {"err": 0, "repaired": len(done), "failed": len(eligible) - len(done),
                    "destroyed": destroyed, "cost": spent}
    return zlib_resp(await run_in_threadpool(work))

@app.post("/flut23/mineTechupgrade.php")
async def mine_tech_upgrade(request: Request):
    _, form = await read_form(request)
    hid  = hid_from_sid(form.get("sid", ""))
    mine_id = form.get("mID", "")
    TECH_ITEMS = {1: 44, 2: 45, 3: 46, 4: 48}
    TU_COL    = {1: "tu1", 2: "tu2", 3: "tu3", 4: "tu4"}
    try:
        level  = int(form.get("tuLevel", 1))
        amount = int(form.get("amount", 0))
    except Exception:
        return zlib_resp({"err": 1, "msg": "invalid params"})
    if level not in TECH_ITEMS or amount <= 0:
        return zlib_resp({"err": 1, "msg": "invalid level/amount"})
    item_id = TECH_ITEMS[level]
    col     = TU_COL[level]
    with get_db() as conn:
        try:
            with econ.tx(conn):
                mine = conn.execute("SELECT * FROM mines WHERE mine_id=? AND owner_hid=?", (mine_id, hid)).fetchone()
                if not mine:
                    return zlib_resp({"err": 2, "msg": "mine not found"})
                current = (mine[col] or 0)
                if current >= 100:
                    return zlib_resp({"err": 3, "msg": f"TU{level} already full"})
                if level > 1 and (mine[TU_COL[level - 1]] or 0) < 100:
                    return zlib_resp({"err": 4, "msg": f"must fill TU{level-1} first"})
                actual = min(amount, 100 - current)
                try:
                    econ.take(conn, hid, item_id, actual, "tech_install", mine_id)
                except econ.GameError:
                    return zlib_resp({"err": 5, "msg": f"need {actual}× item {item_id}"})
                conn.execute(f"UPDATE mines SET {col}=MIN(100, COALESCE({col},0)+?) WHERE mine_id=?", (actual, mine_id))
                award_sink(conn, hid, res={item_id: actual})
                econ.emit(conn, "tech_installed", hid, {"mID": mine_id, "level": level, "qty": actual}, public=False)
            m2 = conn.execute("SELECT tu1,tu2,tu3,tu4 FROM mines WHERE mine_id=?", (mine_id,)).fetchone()
        except econ.GameError as e:
            return legacy_error(e, 5)
    boost_pct = round((m2["tu1"] or 0) * 1.0 + (m2["tu2"] or 0) * 1.0 + (m2["tu3"] or 0) * 1.5 + (m2["tu4"] or 0) * 1.5)
    return zlib_resp({"err": 0, f"tu{level}": min(100, current + actual), "boostPct": int(boost_pct)})

# ── Map markers ─────────────────────────────────────────────────────────────────

@app.post("/flut23/mapLoadMarkers.php")
async def map_load_markers(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat1 = float(form.get("lat1", -90)); lng1 = float(form.get("lng1", -180))
        lat2 = float(form.get("lat2", 90));  lng2 = float(form.get("lng2", 180))
    except Exception:
        lat1,lng1,lat2,lng2 = -90,-180,90,180

    with get_db() as conn:
        mines = conn.execute(
            "SELECT m.*, p.company_name as owner_name FROM mines m "
            "JOIN players p ON m.owner_hid=p.hID "
            "WHERE m.lat BETWEEN ? AND ? AND m.lng BETWEEN ? AND ?",
            (lat1, lat2, lng1, lng2)).fetchall()
        hqs = conn.execute(
            "SELECT h.*, p.company_name as owner_name FROM hq h "
            "JOIN players p ON h.hid=p.hID "
            "WHERE h.lat BETWEEN ? AND ? AND h.lng BETWEEN ? AND ?",
            (lat1, lat2, lng1, lng2)).fetchall()

    markers = []
    for m in mines:
        mt = MINE_TYPES.get(m["item_id"], {})
        markers.append({
            "type": "mine",
            "mID": m["mine_id"], "ownerHID": m["owner_hid"],
            "ownerName": m["owner_name"], "lat": m["lat"], "lng": m["lng"],
            "itemID": m["item_id"], "resID": mt.get("res", 0),
            "cond": current_condition(m), "lvl": m["level"], "isMine": m["owner_hid"] == hid,
        })
    for h in hqs:
        markers.append({
            "type": "hq", "ownerHID": h["hid"], "ownerName": h["owner_name"],
            "lat": h["lat"], "lng": h["lng"], "lvl": h["level"], "isMine": h["hid"] == hid,
        })
    return zlib_resp(markers)

# ── HQ ──────────────────────────────────────────────────────────────────────────

@app.post("/flut23/HQGetMarkers.php")
async def hq_get_markers(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat1 = float(form.get("lat1", -90)); lng1 = float(form.get("lng1", -180))
        lat2 = float(form.get("lat2", 90));  lng2 = float(form.get("lng2", 180))
        min_level = max(1, int(form.get("min_level", "1")))
    except Exception:
        lat1,lng1,lat2,lng2 = -90,-180,90,180
        min_level = 1
    with get_db() as conn:
        rows = conn.execute(
            "SELECT h.*,p.company_name FROM hq h JOIN players p ON h.hid=p.hID "
            "WHERE h.lat BETWEEN ? AND ? AND h.lng BETWEEN ? AND ? "
            "AND (h.hid = ? OR h.level >= ?)",
            (lat1,lat2,lng1,lng2,hid,min_level)).fetchall()
        refs = public_refs(conn, {r["hid"] for r in rows}, hid)
        subs = {r["hid"]: hq_sub_level(conn, r["hid"], r["level"]) for r in rows if r["level"] >= 10}
    return zlib_resp([{
        "ownerHID": refs[r["hid"]], "ownerName": r["company_name"],
        "lat": r["lat"], "lng": r["lng"], "lvl": r["level"], "isMine": r["hid"]==hid,
        "sub_lvl": subs.get(r["hid"], 0),
    } for r in rows])

@app.post("/flut23/HQNewPosition.php")
async def hq_new_position(request: Request):
    """Place or move the HQ. Owner 2026-10-23: checked against the player's GPS (within
    HQ_PLACE_RANGE_M, travel-speed check), placing costs HQ_COST, moving is free once a day."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        lat = float(form.get("lat", 0))
        lng = float(form.get("lng", 0))
        cur_lat = float(form.get("cur_lat"))
        cur_lng = float(form.get("cur_lng"))
    except Exception:
        return zlib_resp({"err": 1, "msg": "Your position is needed to place the HQ"})
    with get_db() as conn:
        try:
            with econ.tx(conn):
                if not get_player(conn, hid):
                    return zlib_resp({"err": 2})
                check_travel(conn, hid, cur_lat, cur_lng)
                if haversine_m(cur_lat, cur_lng, lat, lng) > HQ_PLACE_RANGE_M + GPS_TOLERANCE_M:
                    raise econ.GameError("range", f"The HQ must be within {HQ_PLACE_RANGE_M} m of you")
                existing = conn.execute("SELECT * FROM hq WHERE hid=?", (hid,)).fetchone()
                now = datetime.datetime.utcnow()
                if existing:
                    moved = conn.execute("SELECT hq_moved_at FROM players WHERE hID=?", (hid,)).fetchone()[0]
                    if moved and now - datetime.datetime.fromisoformat(moved) < datetime.timedelta(hours=HQ_MOVE_HOURS):
                        raise econ.GameError("cooldown", f"The HQ can be moved once every {HQ_MOVE_HOURS} hours")
                    cost = 0                  # owner 2026-10-23: moving is free (once a day, GPS-checked)
                    conn.execute("UPDATE hq SET lat=?,lng=? WHERE hid=?", (lat, lng, hid))
                else:
                    cost = HQ_COST
                    econ.debit(conn, hid, cost, "hq_place")
                    conn.execute("INSERT INTO hq(hid,lat,lng) VALUES(?,?,?)", (hid, lat, lng))
                conn.execute("UPDATE players SET hq_moved_at=? WHERE hID=?", (now.isoformat(), hid))
                award_sink(conn, hid, credits=cost)
                add_proto(conn, hid, "hq", {"lat": lat, "lng": lng, "cost": cost})
        except econ.GameError as e:
            return legacy_error(e, 3)
    return zlib_resp({"err": 0, "cost": cost})

HQ_COST = 5000
HQ_MOVE_COST = 0
HQ_MOVE_HOURS = 24
HQ_PLACE_RANGE_M = 500

@app.post("/flut23/hqUpgrade.php")
async def hq_upgrade(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    with get_db() as conn:
        try:
            with econ.tx(conn):
                hq_row = conn.execute("SELECT * FROM hq WHERE hid=?", (hid,)).fetchone()
                if not hq_row:
                    return zlib_resp({"err": 1, "msg": "no HQ placed"})
                level = hq_row["level"]
                if level >= 10:
                    return zlib_resp({"err": 2, "msg": "HQ already at max level"})
                reqs = HQ_UPGRADE_REQS.get(level + 1, {})
                for item_id, qty in reqs.items():
                    econ.take(conn, hid, item_id, qty, "hq_upgrade")
                new_level = level + 1
                if conn.execute("UPDATE hq SET level=? WHERE hid=? AND level=?", (new_level, hid, level)).rowcount != 1:
                    raise econ.GameError("busy", "HQ changed, try again")
                award_sink(conn, hid, res=reqs)
                add_proto(conn, hid, "hqupgrade", {"newLvl": new_level})
        except econ.GameError as e:
            return legacy_error(e, 3)
    return zlib_resp({"err": 0, "newLevel": new_level})

@app.post("/flut23/hqDeposit.php")
async def hq_deposit(request: Request):
    """Deposit resources toward the next HQ level (partial deposits allowed, whole units).
    XP is the system value of what was deposited (owner 2026-10-23)."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    with get_db() as conn:
        try:
            with econ.tx(conn):
                hq_row = conn.execute("SELECT * FROM hq WHERE hid=?", (hid,)).fetchone()
                if not hq_row:
                    return zlib_resp({"err": 1, "msg": "no HQ placed"})
                level = hq_row["level"]
                if level >= 10:
                    return zlib_resp({"err": 2, "msg": "HQ already at max level"})
                target_level = level + 1
                reqs = HQ_UPGRADE_REQS.get(target_level, {})
                deposits_now = {}
                for item_id in reqs:
                    try:
                        amt = int(float(form.get(f"amt_{item_id}", 0)))
                    except Exception:
                        amt = 0
                    if amt <= 0:
                        continue
                    dep_row = conn.execute("SELECT amount FROM hq_deposits WHERE hid=? AND target_level=? AND item_id=?",
                                           (hid, target_level, item_id)).fetchone()
                    already = dep_row["amount"] if dep_row else 0.0
                    amt = int(min(amt, econ.qty_of(conn, hid, item_id), max(0.0, reqs[item_id] - already)))
                    if amt <= 0:
                        continue
                    econ.take(conn, hid, item_id, amt, "hq_deposit")
                    conn.execute("INSERT INTO hq_deposits(hid, target_level, item_id, amount) VALUES(?, ?, ?, ?) "
                                 "ON CONFLICT(hid, target_level, item_id) DO UPDATE SET amount = amount + excluded.amount",
                                 (hid, target_level, item_id, amt))
                    deposits_now[item_id] = amt
                if not deposits_now:
                    return zlib_resp({"err": 3, "msg": "nothing to deposit"})
                award_sink(conn, hid, res=deposits_now)
                all_met = all((conn.execute("SELECT amount FROM hq_deposits WHERE hid=? AND target_level=? AND item_id=?",
                                            (hid, target_level, i)).fetchone() or [0])[0] >= q for i, q in reqs.items())
                upgraded, new_level = False, level
                if all_met:
                    conn.execute("DELETE FROM hq_deposits WHERE hid=? AND target_level=?", (hid, target_level))
                    new_level = target_level
                    conn.execute("UPDATE hq SET level=? WHERE hid=?", (new_level, hid))
                    add_proto(conn, hid, "hqupgrade", {"newLvl": new_level})
                    upgraded = True
                current_deposits = {str(d["item_id"]): d["amount"] for d in conn.execute(
                    "SELECT item_id, amount FROM hq_deposits WHERE hid=? AND target_level=?", (hid, new_level + 1))}
        except econ.GameError as e:
            return legacy_error(e, 3)
    return zlib_resp({"err": 0, "deposited": {str(k): v for k, v in deposits_now.items()},
                      "currentDeposits": current_deposits, "upgraded": upgraded, "newLevel": new_level})

# ── Warehouse ───────────────────────────────────────────────────────────────────

@app.post("/flut23/lagerGetData.php")
async def lager_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    with get_db() as conn:
        row = get_player(conn, hid)
        if not row:
            return zlib_resp({"err": 1})
        # collect pending production
        collect_mines_bulk(conn, hid)
        wh = conn.execute("SELECT item_id,qty FROM warehouse WHERE hid=?", (hid,)).fetchall()
        cap = wh_capacity(row["wh_level"])
    # Filter out special buildings — they are stored in the factories table, not the warehouse.
    items = {str(r["item_id"]): round(r["qty"], 2)
             for r in wh if r["item_id"] not in SPECIAL_BUILDINGS}
    return zlib_resp({
        "err": 0,
        "whLvl": row["wh_level"],
        "whCap": int(cap),
        "items": items,
    })

@app.post("/flut23/lagerUpgrade.php")
async def lager_upgrade(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    return zlib_resp(_warehouse_upgrade(hid, 1))

def _warehouse_upgrade(hid: str, levels: int) -> dict:
    """Upgrade the warehouse by `levels` (1..1000); cost per level economy.wh_upgrade_cost."""
    levels = max(1, min(1000, levels))
    with get_db() as conn:
        try:
            with econ.tx(conn):
                row = get_player(conn, hid)
                if not row:
                    return {"err": 1}
                cur = row["wh_level"]
                total_cost = sum(economy.wh_upgrade_cost(cur + i) for i in range(levels))
                try:
                    econ.debit(conn, hid, total_cost, "warehouse_upgrade")
                except econ.GameError:
                    return {"err": 2, "msg": "not enough credits", "cost": total_cost}
                new_lvl = cur + levels
                if conn.execute("UPDATE players SET wh_level=? WHERE hID=? AND wh_level=?", (new_lvl, hid, cur)).rowcount != 1:
                    raise econ.GameError("busy", "Warehouse changed, try again")
                award_sink(conn, hid, credits=total_cost)
                add_proto(conn, hid, "lagerupgrade", {"newLvl": new_lvl, "cost": total_cost, "levels": levels})
        except econ.GameError as e:
            return {"err": 3, "msg": e.message}
    return {"err": 0, "newLvl": new_lvl, "newCap": int(wh_capacity(new_lvl)), "cost": total_cost}

# ── Factories ───────────────────────────────────────────────────────────────────

@app.post("/flut23/factoryGetData.php")
async def factory_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    with get_db() as conn:
        row = get_player(conn, hid)
        if not row:
            return zlib_resp({"err": 1})
        facts = conn.execute("SELECT * FROM factories WHERE hid=?", (hid,)).fetchall()
        now = datetime.datetime.utcnow()
        factory_list = []
        owned_types = {f["item_id"] for f in facts}
        for f in facts:
            ft = FACTORY_TYPES.get(f["item_id"], {})
            sb = SPECIAL_BUILDINGS.get(f["item_id"])
            level = f["level"]
            if sb:
                # Special building: use SPECIAL_BUILDINGS cost table
                next_idx = level  # costs[level] = cost to upgrade to level+1
                if next_idx < len(sb["costs"]):
                    upg_credits = sb["costs"][next_idx]["credits"]
                    upg_res = {str(k): v for k, v in sb["costs"][next_idx].get("res", {}).items()}
                else:
                    upg_credits = 0
                    upg_res = {}
            elif f["item_id"] in FACTORY_TYPES:      # the real price (owner 2026-10-23: no level cap)
                up = economy.factory_upgrade(f["item_id"], level)
                upg_credits = up["credits"]
                upg_res = {str(k): v for k, v in up["res"].items()}
            else:
                upg_credits, upg_res = 0, {}
            cooldown_until = None
            if f["boost_cooldown_until"]:
                cu = datetime.datetime.fromisoformat(f["boost_cooldown_until"])
                if now < cu:
                    cooldown_until = f["boost_cooldown_until"]
            fire_until = None
            if f["fire_until"]:
                fu = datetime.datetime.fromisoformat(f["fire_until"])
                if now < fu:
                    fire_until = f["fire_until"]
            booster_until = None
            booster_item = None
            if f["booster_until"]:
                bu = datetime.datetime.fromisoformat(f["booster_until"])
                if now < bu:
                    booster_until = f["booster_until"]
                    booster_item = f["booster_item"]
            max_lvl = sb["max_level"] if sb else 1_000_000          # factories: no maximum
            factory_list.append({
                "fID": f["factory_id"], "itemID": f["item_id"], "lvl": level,
                "isSpecial": sb is not None, "maxLvl": max_lvl,
                "prodItem": f["prod_item"], "prodAmt": f["prod_amount"],
                "prodStart": f["prod_start"], "prodEnd": f["prod_end"],
                "cooldownUntil": cooldown_until,
                "fireUntil": fire_until,
                "boosterItem": booster_item, "boosterUntil": booster_until,
                "upgCredits": upg_credits, "upgRes": upg_res,
                "strikeAt": f["strike_at"], "strikeCost": f["strike_cost"],
            })
        catalog = []
        for fid, ft in FACTORY_TYPES.items():
            build_res = FACTORY_BUILD_RESOURCES.get(fid, {})
            catalog.append({
                "itemID": fid, "name": ft["name"], "produces": ft["produces"],
                "needs": ft["needs"], "out": ft["out"], "hrs": ft["hrs"], "credits": ft.get("credits", 0),
                "cost": ft["cost"], "minLvl": ft["lvl"],
                "buildRes": {str(k): v for k, v in build_res.items()},
                "owned": fid in owned_types,
            })
        special_catalog = []
        for sb_id, sb in SPECIAL_BUILDINGS.items():
            build_cost = sb["costs"][0]
            special_catalog.append({
                "itemID": sb_id, "name": sb["name"], "desc": sb["desc"],
                "maxLvl": sb["max_level"],
                "buildCredits": build_cost["credits"],
                "buildRes": {str(k): v for k, v in build_cost.get("res", {}).items()},
                "owned": sb_id in owned_types,
                "currentLvl": next((f["level"] for f in facts if f["item_id"] == sb_id), 0),
            })
        boost_days = round(5 * (1 - artifact_effect(conn, hid, 175) / 100), 2)    # Thor's Crucible
    return zlib_resp({"err": 0, "factories": factory_list, "catalog": catalog, "specialCatalog": special_catalog,
                      "boostCooldownDays": boost_days})

@app.post("/flut23/factoryBuy.php")
async def factory_buy(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        item_id = int(form.get("itemID", 0))
    except Exception:
        return zlib_resp({"err": 1})
    ft = FACTORY_TYPES.get(item_id)
    if not ft:
        return zlib_resp({"err": 2, "msg": "unknown factory type"})
    with get_db() as conn:
        try:
            with econ.tx(conn):
                row = get_player(conn, hid)
                if not row:
                    return zlib_resp({"err": 3})
                if row["level"] < ft["lvl"]:
                    return zlib_resp({"err": 4, "msg": f"requires player level {ft['lvl']}"})
                if conn.execute("SELECT 1 FROM factories WHERE hid=? AND item_id=?", (hid, item_id)).fetchone():
                    return zlib_resp({"err": 6, "msg": "you already own this factory"})
                build_res = FACTORY_BUILD_RESOURCES.get(item_id, {})
                try:
                    econ.debit(conn, hid, ft["cost"], "factory_build", str(item_id))
                except econ.GameError:
                    return zlib_resp({"err": 5, "msg": "not enough credits"})
                for res_item, qty in build_res.items():
                    try:
                        econ.take(conn, hid, res_item, qty, "factory_build", str(item_id))
                    except econ.GameError:
                        raise econ.GameError("insufficient_items", f"need {qty} × item {res_item}")
                fid = new_id()
                conn.execute("INSERT INTO factories(factory_id,hid,item_id,last_active) VALUES(?,?,?,?)",
                             (fid, hid, item_id, utcnow_iso()))
                award_sink(conn, hid, credits=ft["cost"], res=build_res)
                add_proto(conn, hid, "buyfactory", {"fID": fid, "itemID": item_id})
        except econ.GameError as e:
            return legacy_error(e, 7)
    return zlib_resp({"err": 0, "fID": fid})

@app.post("/flut23/factoryNewOrder.php")
async def factory_new_order(request: Request):
    """Start `batches` batches. Inputs AND the recipe credits (srx.txt) are taken at the start."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    try:
        batches = max(1, min(100_000, int(form.get("batches", 1))))
    except Exception:
        batches = 1
    with get_db() as conn:
        try:
            with econ.tx(conn):
                factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
                if not factory:
                    return zlib_resp({"err": 1})
                now = datetime.datetime.utcnow()
                if factory["strike_at"]:
                    return zlib_resp({"err": 7, "msg": "Workers are on strike. Settle the strike first."})
                if factory["fire_until"] and now < datetime.datetime.fromisoformat(factory["fire_until"]):
                    return zlib_resp({"err": 5, "msg": "factory is on fire!", "fireUntil": factory["fire_until"]})
                if factory["prod_item"] is not None:
                    return zlib_resp({"err": 2, "msg": "production already active"})
                ft = FACTORY_TYPES.get(factory["item_id"])
                if not ft:
                    return zlib_resp({"err": 3})
                for need_item, need_qty in ft["needs"].items():
                    try:
                        econ.take(conn, hid, need_item, need_qty * batches, "factory_input", fid)
                    except econ.GameError:
                        return zlib_resp({"err": 4, "msg": f"not enough item {need_item}"})
                credits = ft.get("credits", 0) * batches
                try:
                    econ.debit(conn, hid, credits, "factory_production", fid)
                except econ.GameError:
                    return zlib_resp({"err": 4, "msg": f"not enough credits (ꞓ{credits:,} for {batches} batches)"})
                award_sink(conn, hid, credits=credits)
                level_mult = float(max(1, factory["level"]))      # srx.txt: production/h = base × level
                # a booster raises the batches made while it lasts, at the factory's level (one
                # booster can't boost an order of a thousand batches; owner 2026-10-24: its price
                # scales instead, billions)
                booster_mult, boosted = 1.0, 0
                if factory["booster_until"] and factory["booster_item"]:
                    try:
                        left_h = (datetime.datetime.fromisoformat(factory["booster_until"]) - now).total_seconds() / 3600
                        if left_h > 0:
                            booster_mult = WA_BOOSTERS.get(factory["booster_item"], {}).get("boost", 1.0)
                            boosted = min(batches, int(math.ceil(left_h * level_mult / ft["hrs"] - 1e-9)))
                    except ValueError:
                        pass
                output = round(ft["out"] * (batches + boosted * (booster_mult - 1)), 1)
                hrs = ft["hrs"] * batches / level_mult
                start_time, end_time = now.isoformat(), (now + datetime.timedelta(hours=hrs)).isoformat()
                conn.execute("UPDATE factories SET prod_item=?,prod_amount=?,prod_start=?,prod_end=?,last_active=? "
                             "WHERE factory_id=? AND prod_item IS NULL",
                             (ft["produces"], output, start_time, end_time, start_time, fid))
                econ.emit(conn, "factory_started", hid, {"fID": fid, "item": ft["produces"], "batches": batches},
                          public=False)
        except econ.GameError as e:
            return legacy_error(e, 4)
    return zlib_resp({"err": 0, "prodItem": ft["produces"], "prodAmt": output, "prodStart": start_time,
                      "prodEnd": end_time, "credits": credits})

@app.post("/flut23/factoryCollect.php")
async def factory_collect(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    with get_db() as conn:
        with econ.tx(conn):
            factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
            if not factory or factory["prod_item"] is None:
                return zlib_resp({"err": 1})
            if factory["strike_at"]:
                return zlib_resp({"err": 7, "msg": "Workers are on strike. Settle the strike first."})
            now = utcnow_iso()
            if now < factory["prod_end"]:
                return zlib_resp({"err": 2, "msg": "production not done yet", "end": factory["prod_end"]})
            # clearing the order is the guard: a second simultaneous collect finds nothing
            if conn.execute("UPDATE factories SET prod_item=NULL,prod_amount=NULL,prod_start=NULL,prod_end=NULL, "
                            "last_active=? WHERE factory_id=? AND prod_item IS NOT NULL AND prod_end=?",
                            (now, fid, factory["prod_end"])).rowcount != 1:
                return zlib_resp({"err": 1})
            row = get_player(conn, hid)
            amount = apply_output_hooks(conn, hid, factory["prod_item"], factory["prod_amount"])
            added = wh_add(conn, hid, factory["prod_item"], amount, wh_capacity(row["wh_level"]))
            add_proto(conn, hid, "factcollect", {"fID": fid, "itemID": factory["prod_item"], "qty": added})
    return zlib_resp({"err": 0, "collected": added})

@app.post("/flut23/factoryStop.php")
async def factory_stop(request: Request):
    """Stop production: the inputs and credits of the part not produced yet are returned."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    with get_db() as conn:
        with econ.tx(conn):
            factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
            if not factory or factory["prod_item"] is None:
                return zlib_resp({"err": 1})
            if factory["strike_at"]:
                return zlib_resp({"err": 7, "msg": "Workers are on strike. Settle the strike first."})
            if conn.execute("UPDATE factories SET prod_item=NULL,prod_amount=NULL,prod_start=NULL,prod_end=NULL "
                            "WHERE factory_id=? AND prod_item IS NOT NULL AND prod_end=?",
                            (fid, factory["prod_end"])).rowcount != 1:
                return zlib_resp({"err": 1})
            ft = FACTORY_TYPES.get(factory["item_id"], {})
            now = datetime.datetime.utcnow()
            try:
                start = datetime.datetime.fromisoformat(factory["prod_start"])
                end = datetime.datetime.fromisoformat(factory["prod_end"])
                left = max(0.0, min(1.0, (end - now).total_seconds() / max(1.0, (end - start).total_seconds())))
            except (TypeError, ValueError):
                left = 0.0
            batches = (factory["prod_amount"] or 0) / ft["out"] if ft.get("out") else 0
            refunded = {}
            for need_item, need_qty in ft.get("needs", {}).items():
                q = int(need_qty * batches * left)
                if q > 0:
                    got = econ.give(conn, hid, need_item, q, "factory_stop_refund", fid, ignore_capacity=True)
                    refunded[str(need_item)] = got
            econ.credit(conn, hid, int(ft.get("credits", 0) * batches * left), "factory_stop_refund", fid)
    return zlib_resp({"err": 0, "refunded": refunded})

@app.post("/flut23/factoryUpgrade.php")
async def factory_upgrade(request: Request):
    """No maximum level; the cost grows faster than the output (economy.factory_upgrade)."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    with get_db() as conn:
        try:
            with econ.tx(conn):
                factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
                if not factory:
                    return zlib_resp({"err": 1})
                if factory["strike_at"]:
                    return zlib_resp({"err": 7, "msg": "Workers are on strike. Settle the strike first."})
                if factory["prod_item"] is not None:
                    return zlib_resp({"err": 2, "msg": "stop production before upgrading"})
                if factory["item_id"] not in FACTORY_TYPES:
                    return zlib_resp({"err": 3})
                level = factory["level"]
                cost = economy.factory_upgrade(factory["item_id"], level)
                try:
                    econ.debit(conn, hid, cost["credits"], "factory_upgrade", fid)
                except econ.GameError:
                    return zlib_resp({"err": 4, "msg": f"need ꞓ{cost['credits']:,} credits"})
                for item_id, qty in cost["res"].items():
                    try:
                        econ.take(conn, hid, item_id, qty, "factory_upgrade", fid)
                    except econ.GameError:
                        raise econ.GameError("insufficient_items", f"need {qty} × item {item_id}")
                if conn.execute("UPDATE factories SET level=? WHERE factory_id=? AND level=?",
                                (level + 1, fid, level)).rowcount != 1:
                    raise econ.GameError("busy", "Factory changed, try again")
                award_sink(conn, hid, credits=cost["credits"], res=cost["res"])
                add_proto(conn, hid, "factoryupgrade", {"fID": fid, "newLvl": level + 1, "cost": cost["credits"]})
        except econ.GameError as e:
            return legacy_error(e, 5)
    return zlib_resp({"err": 0, "newLvl": level + 1, "cost": cost["credits"]})

# ── Special Buildings ────────────────────────────────────────────────────────────

@app.post("/flut23/specialBuildingBuy.php")
async def special_building_buy(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        item_id = int(form.get("itemID", 0))
    except Exception:
        return zlib_resp({"err": 1})
    sb = SPECIAL_BUILDINGS.get(item_id)
    if not sb:
        return zlib_resp({"err": 2, "msg": "unknown special building"})
    cost = sb["costs"][0]  # build cost = upgrade to level 1
    with get_db() as conn:
        try:
            with econ.tx(conn):
                if not get_player(conn, hid):
                    return zlib_resp({"err": 3})
                if conn.execute("SELECT 1 FROM factories WHERE hid=? AND item_id=?", (hid, item_id)).fetchone():
                    return zlib_resp({"err": 6, "msg": "already owned. Use upgrade"})
                try:
                    econ.debit(conn, hid, cost["credits"], "special_build", str(item_id))
                except econ.GameError:
                    return zlib_resp({"err": 5, "msg": f"need ꞓ{cost['credits']:,} credits"})
                for res_item, qty in cost.get("res", {}).items():
                    try:
                        econ.take(conn, hid, res_item, qty, "special_build", str(item_id))
                    except econ.GameError:
                        raise econ.GameError("insufficient_items", f"need {qty} × item {res_item}")
                fid = new_id()
                conn.execute("INSERT INTO factories(factory_id,hid,item_id,level) VALUES(?,?,?,1)", (fid, hid, item_id))
                award_sink(conn, hid, credits=cost["credits"], res=cost.get("res"))
                add_proto(conn, hid, "buyspecial", {"fID": fid, "itemID": item_id})
        except econ.GameError as e:
            return legacy_error(e, 7)
    return zlib_resp({"err": 0, "fID": fid})

@app.post("/flut23/specialBuildingUpgrade.php")
async def special_building_upgrade(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    with get_db() as conn:
        try:
            with econ.tx(conn):
                factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
                if not factory:
                    return zlib_resp({"err": 1})
                sb = SPECIAL_BUILDINGS.get(factory["item_id"])
                if not sb:
                    return zlib_resp({"err": 2, "msg": "not a special building"})
                current_level = factory["level"]
                if current_level >= sb["max_level"]:
                    return zlib_resp({"err": 8, "msg": "already at max level"})
                cost = sb["costs"][current_level]  # costs[level] = upgrade to level+1
                try:
                    econ.debit(conn, hid, cost["credits"], "special_upgrade", fid)
                except econ.GameError:
                    return zlib_resp({"err": 4, "msg": f"need ꞓ{cost['credits']:,} credits"})
                for res_item, qty in cost.get("res", {}).items():
                    try:
                        econ.take(conn, hid, res_item, qty, "special_upgrade", fid)
                    except econ.GameError:
                        raise econ.GameError("insufficient_items", f"need {qty} × item {res_item}")
                if conn.execute("UPDATE factories SET level=? WHERE factory_id=? AND level=?",
                                (current_level + 1, fid, current_level)).rowcount != 1:
                    raise econ.GameError("busy", "Building changed, try again")
                award_sink(conn, hid, credits=cost["credits"], res=cost.get("res"))
                add_proto(conn, hid, "upgradespecial", {"fID": fid, "newLvl": current_level + 1})
        except econ.GameError as e:
            return legacy_error(e, 5)
    return zlib_resp({"err": 0, "newLvl": current_level + 1})

@app.post("/flut23/factoryBoost.php")
async def factory_boost(request: Request):
    """Instant production: up to 7 days of output now, for 1 Giant Diamond (as the app says),
    then a cooldown of 5 days (Thor's Crucible: shorter)."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    with get_db() as conn:
        try:
            with econ.tx(conn):
                factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
                if not factory:
                    return zlib_resp({"err": 1})
                if factory["strike_at"]:
                    return zlib_resp({"err": 7, "msg": "Workers are on strike. Settle the strike first."})
                now = datetime.datetime.utcnow()
                if factory["boost_cooldown_until"]:
                    cd = datetime.datetime.fromisoformat(factory["boost_cooldown_until"])
                    if now < cd:
                        return zlib_resp({"err": 2, "msg": "boost on cooldown", "remainingSecs": int((cd - now).total_seconds())})
                if factory["prod_item"] is None or factory["prod_end"] is None:
                    return zlib_resp({"err": 3, "msg": "factory not producing"})
                ft = FACTORY_TYPES.get(factory["item_id"])
                if not ft:
                    return zlib_resp({"err": 4})
                try:
                    econ.take(conn, hid, 42, 1, "factory_boost", fid)
                except econ.GameError:
                    return zlib_resp({"err": 5, "msg": "You need 1 Giant Diamond"})
                player_row = get_player(conn, hid)
                prod_end = datetime.datetime.fromisoformat(factory["prod_end"])
                remaining_hrs = max(0.0, (prod_end - now).total_seconds() / 3600)
                apply_hrs = min(7 * 24, remaining_hrs)
                out_per_hr = ft["out"] * max(1, factory["level"]) / ft["hrs"]      # same as production
                instant_output = min(float(factory["prod_amount"] or 0), round(out_per_hr * apply_hrs, 1))
                added = wh_add(conn, hid, ft["produces"], instant_output, wh_capacity(player_row["wh_level"]))
                add_proto(conn, hid, "factoryboost", {"fID": fid, "item": ft["produces"], "qty": added})
                if apply_hrs >= remaining_hrs:
                    conn.execute("UPDATE factories SET prod_item=NULL, prod_amount=NULL, prod_start=NULL, prod_end=NULL "
                                 "WHERE factory_id=?", (fid,))
                    new_prod_end = None
                else:
                    new_prod_end = (prod_end - datetime.timedelta(hours=7 * 24)).isoformat()
                    new_amount = max(0.0, round((factory["prod_amount"] or 0) - instant_output, 1))
                    conn.execute("UPDATE factories SET prod_end=?, prod_amount=? WHERE factory_id=?",
                                 (new_prod_end, new_amount, fid))
                cooldown_until = (now + datetime.timedelta(days=5 * (1 - artifact_effect(conn, hid, 175) / 100))).isoformat()
                conn.execute("UPDATE factories SET boost_cooldown_until=?, last_active=? WHERE factory_id=?",
                             (cooldown_until, now.isoformat(), fid))
        except econ.GameError as e:
            return legacy_error(e, 5)
    return zlib_resp({"err": 0, "qty": added, "newProdEnd": new_prod_end})

@app.post("/flut23/factoryUseBooster.php")
async def factory_use_booster(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    fid = form.get("fID", "")
    try:
        item_id = int(form.get("itemID", 0))
    except Exception:
        return zlib_resp({"err": 1})
    booster = WA_BOOSTERS.get(item_id)
    if not booster:
        return zlib_resp({"err": 2, "msg": "not a booster item"})
    with get_db() as conn:
        try:
            with econ.tx(conn):
                factory = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
                if not factory:
                    return zlib_resp({"err": 3})
                row = get_player(conn, hid)
                if not row:
                    return zlib_resp({"err": 4})
                try:
                    econ.take(conn, hid, item_id, 1, "booster", fid)
                except econ.GameError:
                    return zlib_resp({"err": 5, "msg": f"you need 1x {booster['name']}"})
                booster_until = (datetime.datetime.utcnow() + datetime.timedelta(hours=booster["hours"])).isoformat()
                conn.execute("UPDATE factories SET booster_item=?, booster_until=? WHERE factory_id=?",
                             (item_id, booster_until, fid))
                new_wa = change_wa(conn, hid, booster["wa_delta"], "booster")
                award_sink(conn, hid, res={item_id: 1})
                add_proto(conn, hid, "booster", {"fID": fid, "item": item_id, "wa": new_wa})
        except econ.GameError as e:
            return legacy_error(e, 5)
    return zlib_resp({"err": 0, "boostMult": booster["boost"], "boosterUntil": booster_until,
                      "waNew": new_wa, "waDelta": booster["wa_delta"]})

@app.post("/flut23/lagerUpgradeMulti.php")
async def lager_upgrade_multi(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        levels = int(form.get("levels", 1))
    except Exception:
        levels = 1
    return zlib_resp(_warehouse_upgrade(hid, levels))

# ── Market ───────────────────────────────────────────────────────────────────────

@app.post("/flut23/marketGetData.php")
async def market_get_data(request: Request):
    """The first market (no price limits, no tax) was removed (audit C2); see systems/market.py."""
    return zlib_resp({"err": 9, "msg": "This market was replaced. Please update the app."})

@app.post("/flut23/marketNewReq.php")
async def market_new_req(request: Request):
    """The first market (no price limits, no tax) was removed (audit C2); see systems/market.py."""
    return zlib_resp({"err": 9, "msg": "This market was replaced. Please update the app."})

@app.post("/flut23/marketDealReq.php")
async def market_deal_req(request: Request):
    """The first market (no price limits, no tax) was removed (audit C2); see systems/market.py."""
    return zlib_resp({"err": 9, "msg": "This market was replaced. Please update the app."})

@app.post("/flut23/marketCancelReq.php")
async def market_cancel_req(request: Request):
    """The first market (no price limits, no tax) was removed (audit C2); see systems/market.py."""
    return zlib_resp({"err": 9, "msg": "This market was replaced. Please update the app."})

# ── Activity log ─────────────────────────────────────────────────────────────────

@app.post("/flut23/protokollGetData.php")
async def protokoll_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        offset = int(form.get("offset", 0))
    except Exception:
        offset = 0
    log_type = form.get("type", "")
    cutoff = (datetime.datetime.utcnow() - datetime.timedelta(days=365)).isoformat()
    with get_db() as conn:
        # purge entries older than 365 days for this player
        conn.execute("DELETE FROM proto_log WHERE hid=? AND created_at<?", (hid, cutoff))
        if log_type:
            rows = conn.execute(
                "SELECT * FROM proto_log WHERE hid=? AND log_type=? AND created_at>=? ORDER BY created_at DESC LIMIT 100 OFFSET ?",
                (hid, log_type, cutoff, offset)).fetchall()
            total = conn.execute(
                "SELECT COUNT(*) FROM proto_log WHERE hid=? AND log_type=? AND created_at>=?",
                (hid, log_type, cutoff)).fetchone()[0]
        else:
            rows = conn.execute(
                "SELECT * FROM proto_log WHERE hid=? AND created_at>=? ORDER BY created_at DESC LIMIT 100 OFFSET ?",
                (hid, cutoff, offset)).fetchall()
            total = conn.execute(
                "SELECT COUNT(*) FROM proto_log WHERE hid=? AND created_at>=?",
                (hid, cutoff)).fetchone()[0]
        entries = []
        for r in rows:
            data = json.loads(r["data_json"] or "{}")
            for key in ("buyerHID", "sellerHID", "attackerHID", "defenderHID"):
                if isinstance(data.get(key), str):  # never show other players' internal ids
                    data[key] = public_refs(conn, {data[key]}, hid)[data[key]]
            entries.append({"logID": r["log_id"], "type": r["log_type"], "data": data,
                            "ts": r["created_at"]})
    return zlib_resp({
        "entries": entries,
        "total": total,
        "offset": offset,
    })

# ── Items catalog ─────────────────────────────────────────────────────────────────

@app.post("/flut23/itemsGetData.php")
async def items_get_data(request: Request):
    catalog = []
    for mid, mt in MINE_TYPES.items():
        catalog.append({"itemID": mid, "type": "mine",
                         "resID": mt["res"], "rate": mt["rate"],
                         "cost": mt["cost"], "minLvl": mt["lvl"]})
    for fid, ft in FACTORY_TYPES.items():
        catalog.append({"itemID": fid, "type": "factory",
                         "name": ft["name"], "produces": ft["produces"],
                         "needs": ft["needs"], "cost": ft["cost"], "minLvl": ft["lvl"]})
    return zlib_resp(catalog)

# System ("AI") price per unit — the existing game price definitions. The market buys at
# 100% and sells at 150% of these (systems/market.py).
# System market prices (what the system pays; it sells at 150 % + tax). Owner 2026-10-19: the system
# trades nearly everything, which also bounds player bids (min = this price, max = the system's
# selling price). Not tradeable at all: Giant Diamonds (42), Tech Upgrade IV (48), luxury items
# (auctions), buildings. Products without an original price: srx.txt recipe inputs + recipe credits
# per unit, +30 %; found objects: about what they recycle into. A placeholder until the economy rework.
SYSTEM_PRICES = {
    # raw resources and the original products
    2: 5, 3: 5, 7: 20, 8: 15, 10: 40, 12: 18, 13: 20, 14: 200,
    15: 80, 20: 8, 24: 25, 26: 35, 30: 60, 32: 90, 35: 150,
    36: 120, 38: 70, 49: 45, 53: 6, 79: 500, 81: 400, 90: 300, 169: 350,
    # factory products (srx.txt recipes)
    22: 18, 59: 590, 28: 95, 57: 57, 92: 10270, 93: 36865, 87: 14925, 67: 32484, 66: 6187,
    51: 3367, 75: 15074, 84: 292923, 171: 8973, 124: 89312,
    # former shop items (× 1.5 = old shop price)
    43: 333, 44: 3333, 45: 10000, 46: 23333, 117: 1333,
    # found objects (≈ recycling value)
    41: 30, 55: 30, 40: 80, 70: 15, 74: 12, 77: 6, 78: 40, 115: 5, 120: 40,
    # production boosters, units, archaeology
    158: 10000, 159: 10000, 160: 10000, 161: 10000,
    95: 200, 97: 1500, 98: 4000, 102: 250, 103: 2000, 104: 5000,
    166: 3200000, 167: 1000,
    # artifacts (rarer = dearer)
    172: 3333, 173: 10000, 174: 5000, 175: 6667, 176: 20000, 177: 5000,
}
# economy revamp (owner 2026-10-23): derived prices replace the placeholders above
SYSTEM_PRICES = economy.system_prices()

@app.post("/flut23/itemsGetKurse.php")
async def items_get_kurse(request: Request):
    prices = [{"itemID": k, "price": v} for k, v in SYSTEM_PRICES.items()]
    return zlib_resp(prices)

# (The developer shop was removed: items come from the market, factories and Cargo Rain.)

@app.post("/flut23/mineUpgrade.php")
async def mine_upgrade(request: Request):
    """Mines have no levels (owner 2026-10-23); output grows with quality, tech and the HQ."""
    return zlib_resp({"err": 2, "msg": "Mines have no levels. Use tech upgrades and your HQ to boost output."})

# ── Leaderboard & Profile ─────────────────────────────────────────────────────────

@app.post("/flut23/setCountryCode.php")
async def set_country_code(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    code = form.get("code", "")[:5]
    if not hid or not code:
        return zlib_resp({"err": 1})
    with get_db() as conn:
        conn.execute("UPDATE players SET country_code=? WHERE hID=?", (code, hid))
        conn.commit()
    return zlib_resp({"err": 0})

@app.post("/flut23/leaderboard.php")
async def leaderboard(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    now = datetime.datetime.utcnow()
    cutoff_100 = (now - datetime.timedelta(days=100)).strftime("%Y-%m-%d")
    today = now.strftime("%Y-%m-%d")
    with get_db() as conn:
        rows = conn.execute(
            "SELECT hID, company_name, xp, level, country_code, created_at FROM players"
        ).fetchall()
        scored = []
        for r in rows:
            xp = r["xp"] or 0
            created_at_str = r["created_at"] or today
            try:
                created_dt = datetime.datetime.fromisoformat(created_at_str)
            except Exception:
                created_dt = now
            age_days = max(1, (now - created_dt).days)
            if age_days < 100:
                active_days = conn.execute(
                    "SELECT COUNT(*) FROM player_activity WHERE hid=? AND day<=?",
                    (r["hID"], today)).fetchone()[0]
                activity = active_days / age_days
            else:
                active_days = conn.execute(
                    "SELECT COUNT(*) FROM player_activity WHERE hid=? AND day>=? AND day<=?",
                    (r["hID"], cutoff_100, today)).fetchone()[0]
                activity = active_days / 100.0
            activity = min(1.0, activity)
            score = round(xp * activity)        # points = XP × activity (owner 2026-10-23)
            scored.append({
                "hID": public_refs(conn, {r["hID"]}, hid)[r["hID"]],
                "name": r["company_name"],
                "level": r["level"],
                "countryCode": r["country_code"] or "",
                "score": score,
                "activity": round(activity * 100),
                "isMe": r["hID"] == hid,
            })
        scored.sort(key=lambda x: x["score"], reverse=True)
        result = [{"rank": i + 1, **e} for i, e in enumerate(scored[:50])]
    return zlib_resp({"err": 0, "leaderboard": result})

# ── News ──────────────────────────────────────────────────────────────────────────

@app.api_route("/flut23/newsX26.php", methods=["GET","POST"])
async def news(request: Request):
    return zlib_resp([{
        "newsID": "1",
        "title": "Welcome to Resources!",
        "body": "Private server running. Scan for resources and build your empire!",
        "ts": "2024-01-01T00:00:00",
    }])

@app.get("/api/v1/health")
async def health():
    """Public liveness check (used by the download page, so any origin may read it)."""
    return JSONResponse({"ok": True, "time": utcnow_iso()},
                        headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"})

# ── Master field pre-generation (background thread at startup) ────────────────────

def _pregenerate_master_fields():
    """Generate all master resource fields in the background so the first scan is fast."""
    if not _HAS_NP:
        return
    for mid in _RES_ORDER:
        try:
            get_master_field(mid)
        except Exception:
            pass

threading.Thread(target=_pregenerate_master_fields, daemon=True).start()

# ── Background mine destruction sweeper ──────────────────────────────────────────

def _mine_destruction_sweeper():
    """Hourly sweep: process collect_mine for any mine whose condition has fallen below 20.
    This ensures offline destruction is handled even when no endpoint accesses the mine."""
    while True:
        time.sleep(3600)
        try:
            now = datetime.datetime.utcnow()
            with get_db() as conn:
                doomed = {}  # owner -> mine IDs whose projected condition is below 20
                for mine in conn.execute("SELECT mine_id, owner_hid, condition, last_coll FROM mines"):
                    try:
                        last = datetime.datetime.fromisoformat(mine["last_coll"])
                        hours = (now - last).total_seconds() / 3600
                        if float(mine["condition"]) - hours / 6.0 < 20.0:
                            doomed.setdefault(mine["owner_hid"], set()).add(mine["mine_id"])
                    except Exception:
                        pass
                for owner, ids in doomed.items():
                    try:
                        collect_mines_bulk(conn, owner, only_ids=ids)
                    except Exception:
                        pass
        except Exception:
            pass

threading.Thread(target=_mine_destruction_sweeper, daemon=True).start()

# ── FCM push helper (HTTP v1) ─────────────────────────────────────────────────────
# Requires two environment variables (see deploy/.env.example and docs/FIREBASE.md):
#   GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/firebase_sa
#   FIREBASE_PROJECT_ID=your-firebase-project-id
#
# Pushes are silently skipped until a Firebase service account JSON is provided.

_FIREBASE_PROJECT_ID = os.environ.get("FIREBASE_PROJECT_ID", "")
_GOOGLE_CREDS_PATH   = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
_fcm_credentials = None  # cached google.oauth2 Credentials object

def _get_fcm_token() -> str:
    """Return a valid OAuth2 bearer token for FCM HTTP v1, refreshing if needed."""
    global _fcm_credentials
    if not _FIREBASE_PROJECT_ID or not _GOOGLE_CREDS_PATH:
        return ""
    try:
        from google.oauth2 import service_account
        import google.auth.transport.requests as google_requests
        if _fcm_credentials is None or not _fcm_credentials.valid:
            scopes = ["https://www.googleapis.com/auth/firebase.messaging"]
            _fcm_credentials = service_account.Credentials.from_service_account_file(
                _GOOGLE_CREDS_PATH, scopes=scopes)
        if not _fcm_credentials.valid:
            _fcm_credentials.refresh(google_requests.Request())
        return _fcm_credentials.token or ""
    except Exception:
        return ""

def _send_fcm(token: str, title: str, body: str) -> bool:
    """Send a push notification via FCM HTTP v1 API. Returns True on success."""
    bearer = _get_fcm_token()
    if not bearer:
        return False
    try:
        import urllib.request
        url = f"https://fcm.googleapis.com/v1/projects/{_FIREBASE_PROJECT_ID}/messages:send"
        payload = json.dumps({
            "message": {
                "token": token,
                "notification": {"title": title, "body": body},
                "android": {"priority": "HIGH"},
            }
        }).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Authorization": f"Bearer {bearer}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False

def _push_to_player(conn, hid: str, title: str, body: str):
    """Send FCM push to all registered tokens for a player."""
    rows = conn.execute("SELECT token FROM fcm_tokens WHERE hid=?", (hid,)).fetchall()
    for row in rows:
        _send_fcm(row["token"], title, body)

# ── Server-side notification sweeper (runs every 30 min) ─────────────────────────

def _notification_sweeper():
    """Check all players for notification-worthy events every 30 minutes.
    Respects 24h per-category cooldowns stored in notif_prefs table."""
    while True:
        time.sleep(1800)
        try:
            now = datetime.datetime.utcnow()
            now_iso = now.isoformat()
            with get_db() as conn:
                players = conn.execute("SELECT hID, wh_level FROM players").fetchall()
                for p in players:
                    hid = p["hID"]
                    prefs_row = conn.execute(
                        "SELECT * FROM notif_prefs WHERE hid=?", (hid,)).fetchone()
                    if prefs_row and not prefs_row["enabled"]:
                        continue

                    cap = wh_capacity(p["wh_level"])
                    wh_used = wh_total(conn, hid)
                    mines = conn.execute("SELECT * FROM mines WHERE owner_hid=?", (hid,)).fetchall()

                    # ── Mine warning / destruction ──────────────────────────────
                    warn_mines, destr_mines = [], []
                    for mine in mines:
                        try:
                            last = datetime.datetime.fromisoformat(mine["last_coll"])
                            hours_elapsed = (now - last).total_seconds() / 3600
                            cond_now = float(mine["condition"]) - hours_elapsed / 6.0
                            if cond_now < 20.0:
                                destr_mines.append(mine["mine_id"])
                            elif cond_now <= 24.0:
                                warn_mines.append(mine["mine_id"])
                        except Exception:
                            pass

                    # owner 2026-10-24: these alerts are notification kinds with a daily maximum too
                    # (systems/notify.py); the sweeper only detects, notify() decides and counts
                    note = getattr(SYSTEM_HELPERS, "notify", None)
                    if not note:
                        continue
                    if destr_mines:
                        n = len(destr_mines)
                        note(hid, "mine_destroyed", "Mine destroyed", f"{n} mine{'s have' if n > 1 else ' has'} been destroyed.")
                    if warn_mines:
                        n = len(warn_mines)
                        note(hid, "mine_warning", "Mine condition warning",
                             f"{n} mine{'s are' if n > 1 else ' is'} close to destruction. Repair soon.")
                    if cap > 0:
                        usage_pct = wh_used / cap
                        if usage_pct >= 1.0:
                            note(hid, "wh_full", "Warehouse full", "Your warehouse is full. Production is being lost.")
                        elif usage_pct >= 0.80:
                            note(hid, "wh_almost", "Warehouse almost full", f"Your warehouse is {round(usage_pct * 100)}% full.")
                conn.commit()
        except Exception:
            pass

threading.Thread(target=_notification_sweeper, daemon=True).start()

# ── Config & Locale ───────────────────────────────────────────────────────────────

@app.api_route("/flut23/configGetData.php", methods=["GET","POST"])
async def config_get_data(request: Request):
    global _config_cache
    body, _ = await read_form(request)
    if _config_cache is None:
        resp = await proxy_to_original(request, body)
        if resp.status_code == 200 and resp.body:
            _config_cache = resp.body
    if _config_cache is None:
        cfg = [dict(x) for x in _FALLBACK_CONFIG]
        for item in cfg:
            if item["key"] == "rt":
                item["value"] = int(datetime.datetime.utcnow().timestamp())
        _config_cache = zlib_bytes(cfg)
    return Response(content=_config_cache,
                    headers={"content-type": "application/octet-stream"})

@app.api_route("/flut23/localeGet.php", methods=["GET","POST"])
async def locale_get(request: Request):
    body, form = await read_form(request)
    lang = (form.get("l") or "en").strip()
    if lang not in _locale_cache:
        resp = await proxy_to_original(request, body)
        if resp.status_code == 200 and resp.body:
            _locale_cache[lang] = apply_locale_overrides(resp.body)
    if lang not in _locale_cache:
        _locale_cache[lang] = zlib_bytes({})
    return Response(content=_locale_cache[lang],
                    headers={"content-type": "application/octet-stream"})

# ── Stub endpoints (return empty/ok for less critical features) ───────────────────

async def _stub_empty(request: Request):
    return zlib_resp([])

async def _stub_ok(request: Request):
    return zlib_resp({"err": 0})

# ── Chat ─────────────────────────────────────────────────────────────────────────

@app.post("/flut23/chatGetData2.php")
async def chat_get(request: Request):
    form = await request.form()
    hid  = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1, "msg": "auth"})
    since = int(form.get("since", "0") or "0")
    with get_db() as conn:
        rows = conn.execute(
            "SELECT id, hid, name, msg, ts FROM chat_messages WHERE id > ? ORDER BY id DESC LIMIT 50",
            (since,)
        ).fetchall()
        refs = public_refs(conn, {r["hid"] for r in rows}, hid)
    return zlib_resp([{**dict(r), "hid": refs[r["hid"]]} for r in reversed(rows)])

@app.post("/flut23/chatNewMsg2.php")
async def chat_send(request: Request):
    form = await request.form()
    hid  = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1, "msg": "auth"})
    msg = (form.get("msg", "") or "").strip()
    if not msg or len(msg) > 500:
        return zlib_resp({"err": 2, "msg": "invalid"})
    from systems import social as _social  # shared spam protection with /api/v1/chat/send
    if not (_social.chat_limit_burst.allow(hid) and _social.chat_limit_minute.allow(hid)):
        return zlib_resp({"err": 4, "msg": "You're sending messages too fast"})
    with get_db() as conn:
        row = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()
        if not row:
            return zlib_resp({"err": 3, "msg": "player not found"})
        name = row["company_name"]
        conn.execute(
            "INSERT INTO chat_messages (hid, name, msg, ts) VALUES (?,?,?,?)",
            (hid, name, msg, utcnow_iso())
        )
        conn.execute("DELETE FROM chat_messages WHERE ts < ?",      # keep one week (owner 2026-10-20)
                     ((datetime.datetime.utcnow() - datetime.timedelta(days=7)).isoformat(),))
        conn.commit()
        conn.execute(
            "DELETE FROM chat_messages WHERE id NOT IN "
            "(SELECT id FROM chat_messages ORDER BY id DESC LIMIT 5000)"
        )
        conn.commit()
    return zlib_resp({"err": 0})

# ── Casino ────────────────────────────────────────────────────────────────────────

_CASINO_ITEM_ID      = 61
_CASINO_FREE_SPINS   = 500
_CASINO_GD_PACKS_MAX = 4          # max GD packs per cycle
_CASINO_GD_ITEM      = 42         # Giant Diamond item id
_CASINO_SYMBOLS      = 32         # 0-30 regular luxury items, 31 = jackpot symbol
_JACKPOT_START       = 100_000_000_000
_JACKPOT_INCREMENT   = 1_000_000  # per spin across all players

# Payout multiplier of bet (total received, not net profit). RTP ≈ 115.2%.
_CASINO_PAYOUTS = {
    "no_pair":         0,
    "one_pair":        3,
    "two_pair":        5,
    "three_of_a_kind": 26,
    "full_house":      100,
    "four_of_a_kind":  300,
    "five_of_a_kind":  10000,
    "jackpot":         0,   # variable – uses jackpot pool
}

_HAND_DISPLAY = {
    "no_pair":         "No Pair",
    "one_pair":        "One Pair",
    "two_pair":        "Two Pair",
    "three_of_a_kind": "Three of a Kind",
    "full_house":      "Full House",
    "four_of_a_kind":  "Four of a Kind",
    "five_of_a_kind":  "Five of a Kind!",
    "jackpot":         "JACKPOT!!!",
}

def _eval_hand(reels):
    from collections import Counter
    counts = Counter(reels)
    freqs  = sorted(counts.values(), reverse=True)
    if freqs[0] == 5:
        sym = counts.most_common(1)[0][0]
        return "jackpot" if sym == 31 else "five_of_a_kind"
    if freqs[0] == 4:                              return "four_of_a_kind"
    if freqs[0] == 3 and len(freqs) > 1 and freqs[1] == 2: return "full_house"
    if freqs[0] == 3:                              return "three_of_a_kind"
    if freqs[0] == 2 and len(freqs) > 1 and freqs[1] == 2: return "two_pair"
    if freqs[0] == 2:                              return "one_pair"
    return "no_pair"

def _get_casino_level(conn, hid):
    row = conn.execute(
        "SELECT level FROM factories WHERE hid=? AND item_id=?",
        (hid, _CASINO_ITEM_ID)).fetchone()
    return row["level"] if row else 0

def _get_casino_state(conn, hid):
    row = conn.execute("SELECT * FROM casino_state WHERE hid=?", (hid,)).fetchone()
    if not row:
        conn.execute("INSERT OR IGNORE INTO casino_state(hid) VALUES(?)", (hid,))
        conn.commit()
        row = conn.execute("SELECT * FROM casino_state WHERE hid=?", (hid,)).fetchone()
    return row

def _maybe_reset(conn, hid, state):
    if state["reset_at"] is None:
        return state
    try:
        reset_dt = datetime.datetime.fromisoformat(state["reset_at"])
    except Exception:
        return state
    if datetime.datetime.utcnow() >= reset_dt:
        conn.execute(
            "UPDATE casino_state SET spins_left=500, gd_packs_used=0, reset_at=NULL WHERE hid=?",
            (hid,))
        conn.commit()
        state = conn.execute("SELECT * FROM casino_state WHERE hid=?", (hid,)).fetchone()
    return state

def _get_jackpot(conn):
    row = conn.execute("SELECT amount FROM jackpot WHERE id=1").fetchone()
    return row["amount"] if row else _JACKPOT_START

@app.post("/flut23/casinoGetData.php")
async def casino_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1, "msg": "not logged in"})
    with get_db() as conn:
        level = _get_casino_level(conn, hid)
        state = _get_casino_state(conn, hid)
        state = _maybe_reset(conn, hid, state)
        jackpot = _get_jackpot(conn)
    time_left = None
    if state["reset_at"]:
        try:
            delta = (datetime.datetime.fromisoformat(state["reset_at"]) -
                     datetime.datetime.utcnow()).total_seconds()
            time_left = max(0, int(delta))
        except Exception:
            pass
    return zlib_resp({
        "err": 0,
        "casino_level":    level,
        "max_bet":         level * 1_000_000,
        "spins_left":      state["spins_left"],
        "gd_packs_used":   state["gd_packs_used"],
        "reset_at":        state["reset_at"],
        "time_left_secs":  time_left,
        "jackpot":         jackpot,
    })

@app.post("/flut23/casinoNewRoll.php")
async def casino_new_roll(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1, "msg": "not logged in"})
    try:
        bet   = int(form.get("bet",   "1000000"))
        count = int(form.get("count", "1"))
    except Exception:
        return zlib_resp({"err": 2, "msg": "bad params"})
    count = max(1, min(count, _CASINO_FREE_SPINS))

    with get_db() as conn:
        level = _get_casino_level(conn, hid)
        if level < 1:
            return zlib_resp({"err": 3, "msg": "build Casino first"})
        max_bet = level * 1_000_000
        if bet < 1_000_000 or bet > max_bet:
            return zlib_resp({"err": 4, "msg": f"bet must be 1M–{max_bet//1_000_000}M"})

        # (reset may commit, so it runs before the transaction)
        _maybe_reset(conn, hid, _get_casino_state(conn, hid))
        total_cost = bet * count
        dividends = []
        try:
            with econ.tx(conn):
                state = conn.execute("SELECT * FROM casino_state WHERE hid=?", (hid,)).fetchone()
                if state["spins_left"] < count:
                    raise econ.GameError("no_spins", "not enough spins")
                # conditional debit: concurrent rolls can't overspend
                econ.debit(conn, hid, total_cost, "casino_bet")

                rng = random.Random()
                total_win   = 0
                jackpot_won = False
                jackpot_amt = _get_jackpot(conn)
                hand_counts: dict = {k: 0 for k in _CASINO_PAYOUTS}
                last_reels  = [0, 0, 0, 0, 0]
                last_hand   = "no_pair"
                last_win    = 0
                fives = []

                for _ in range(count):
                    reels = [rng.randint(0, _CASINO_SYMBOLS - 1) for _ in range(5)]
                    hand  = _eval_hand(reels)
                    hand_counts[hand] = hand_counts.get(hand, 0) + 1
                    if hand == "jackpot" and not jackpot_won:
                        jackpot_won = True
                        win = jackpot_amt
                        econ.emit(conn, "casino_jackpot", hid, {"amount": win})
                        jackpot_amt = _JACKPOT_START  # reset
                    else:
                        win = bet * _CASINO_PAYOUTS.get(hand, 0)
                        if hand == "five_of_a_kind":
                            fives.append(reels[0])
                    total_win   += win
                    last_reels   = reels
                    last_hand    = hand
                    last_win     = win

                big = hand_counts.get("four_of_a_kind", 0) + hand_counts.get("five_of_a_kind", 0) \
                    + hand_counts.get("jackpot", 0)
                if big:                                  # achievement "Gambler" (four of a kind or better)
                    conn.execute("INSERT INTO news_counters(hid, key, value) VALUES(?, 'casino_four_plus', ?) "
                                 "ON CONFLICT(hid, key) DO UPDATE SET value = value + excluded.value", (hid, big))
                # Increment jackpot by 1M per spin (unless won this batch)
                if jackpot_won:
                    conn.execute("UPDATE jackpot SET amount=? WHERE id=1", (jackpot_amt,))
                else:
                    conn.execute("UPDATE jackpot SET amount=amount+? WHERE id=1",
                                 (_JACKPOT_INCREMENT * count,))

                # five of a kind of a luxury symbol → dividend to holders of that item (systems/auctions.py)
                for sym in fives:
                    for hook in CASINO_FIVE_HOOKS:
                        d = hook(conn, sym, hid)
                        if d:
                            dividends.append(d)

                econ.credit(conn, hid, total_win, "casino_win")

                # Decrement spins; start timer if first spin this cycle
                new_spins = state["spins_left"] - count
                reset_at  = state["reset_at"]
                if reset_at is None:
                    reset_at = (datetime.datetime.utcnow() +
                                datetime.timedelta(hours=24)).isoformat()
                conn.execute(
                    "UPDATE casino_state SET spins_left=?, reset_at=? WHERE hid=?",
                    (new_spins, reset_at, hid))
        except econ.GameError as e:
            return zlib_resp({"err": 5 if e.code == "no_spins" else 7, "msg": e.message})
        jackpot_amt = _get_jackpot(conn)

    new_jackpot = jackpot_amt

    if count == 1:
        return zlib_resp({
            "err": 0,
            "reels":       last_reels,
            "hand":        last_hand,
            "hand_display": _HAND_DISPLAY.get(last_hand, last_hand),
            "win":         last_win,
            "spins_left":  new_spins,
            "jackpot":     new_jackpot,
            "jackpot_won": jackpot_won,
            "dividends":   dividends,
        })
    else:
        return zlib_resp({
            "err": 0,
            "batch":       True,
            "hand_counts": hand_counts,
            "total_bet":   total_cost,
            "total_win":   total_win,
            "net":         total_win - total_cost,
            "spins_left":  new_spins,
            "jackpot":     new_jackpot,
            "jackpot_won": jackpot_won,
            "dividends":   dividends,
        })

@app.post("/flut23/casinoUseDiamond.php")
async def casino_use_diamond(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return zlib_resp({"err": 1, "msg": "not logged in"})
    with get_db() as conn:
        if _get_casino_level(conn, hid) < 1:
            return zlib_resp({"err": 2, "msg": "build Casino first"})
        _maybe_reset(conn, hid, _get_casino_state(conn, hid))      # (may commit: before the transaction)
        try:
            with econ.tx(conn):
                state = conn.execute("SELECT * FROM casino_state WHERE hid=?", (hid,)).fetchone()
                if state["spins_left"] > 0:
                    return zlib_resp({"err": 3, "msg": "use your remaining spins first"})
                if state["gd_packs_used"] >= _CASINO_GD_PACKS_MAX:
                    return zlib_resp({"err": 4, "msg": "max GD packs used this cycle"})
                try:
                    econ.take(conn, hid, _CASINO_GD_ITEM, 1, "casino_pack")
                except econ.GameError:
                    return zlib_resp({"err": 5, "msg": "no Giant Diamond"})
                new_packs = state["gd_packs_used"] + 1
                conn.execute("UPDATE casino_state SET spins_left=?, gd_packs_used=? WHERE hid=? AND gd_packs_used=?",
                             (_CASINO_FREE_SPINS, new_packs, hid, state["gd_packs_used"]))
        except econ.GameError as e:
            return legacy_error(e, 5)
        jackpot = _get_jackpot(conn)
    return zlib_resp({"err": 0, "spins_left": _CASINO_FREE_SPINS, "gd_packs_used": new_packs, "jackpot": jackpot})

# ── Game systems (server/systems/*) ───────────────────────────────────────────────

import types as _types
import econ
import protection
import systems

def public_refs(conn, hids, viewer_hid: str) -> dict:
    """Map internal player ids to what other players may see: the viewer's own id stays as is
    (old clients compare it), everyone else gets their public id. Internal ids must never leak:
    in AUTH_MODE=mixed an id still opens accounts that have no password yet."""
    from systems.social import pid_of
    out = {h: (h if h == viewer_hid else pid_of(conn, h)) for h in hids}
    if conn.in_transaction:
        conn.commit()
    return out

def building_level(conn, hid: str, item_id: int) -> int:
    """Level of a special building / factory the player owns (0 if not built)."""
    r = conn.execute("SELECT MAX(level) FROM factories WHERE hid=? AND item_id=?", (hid, item_id)).fetchone()
    return int(r[0] or 0) if r else 0

def mine_rate_hr(conn, hid: str, mine) -> float:
    """Effective production per hour of one mine (same formula as playerGetData rateHr)."""
    mt = MINE_TYPES.get(mine["item_id"], {})
    hq = conn.execute("SELECT lat,lng,level FROM hq WHERE hid=?", (mine["owner_hid"],)).fetchone()
    tech = 1.0 + ((mine["tu1"] or 0) * 1.0 + (mine["tu2"] or 0) * 1.0 +
                  (mine["tu3"] or 0) * 1.5 + (mine["tu4"] or 0) * 1.5) / 100.0
    return (mt.get("rate", 0) * mine["quality"] / 100.0 * max(0.1, mine["condition"] / 100.0)
            * tech * float(mine["level"]) * _hq_boost_from(hq, mine))

with get_db() as _conn:
    econ.init(_conn, capacity_fn=lambda p: wh_capacity(p["wh_level"]),
              non_warehouse_items=set(SPECIAL_BUILDINGS))

def _owner_balance_x10_once() -> None:
    """One-time owner decision (2026-10-19): existing companies get 10× their credits, like the new
    starting balance. Runs once per database (scheduler flag), ledgered as owner_balance_x10."""
    with get_db() as c:
        with econ.tx(c):
            if c.execute("SELECT 1 FROM scheduler WHERE name='owner_balance_x10'").fetchone():
                return
            for r in c.execute("SELECT hID, credits FROM players WHERE credits > 0").fetchall():
                econ.credit(c, r[0], int(r[1]) * 9, "owner_balance_x10")
            c.execute("INSERT INTO scheduler(name, last_run) VALUES('owner_balance_x10', ?)", (utcnow_iso(),))

_owner_balance_x10_once()


def _realtime_decay_start_once() -> None:
    """One-time (2026-10-23): condition now decays with real time. So that long-unvisited mines aren't
    all destroyed at once, decay starts from now for mines older than 24 h: their clock is set to
    24 h ago, which keeps the full 24 h production buffer and the old decay behaviour for the past."""
    with get_db() as c:
        with econ.tx(c):
            if c.execute("SELECT 1 FROM scheduler WHERE name='realtime_decay_start'").fetchone():
                return
            cutoff = (datetime.datetime.utcnow() - datetime.timedelta(hours=24)).isoformat()
            c.execute("UPDATE mines SET last_coll=? WHERE last_coll < ?", (cutoff, cutoff))
            c.execute("INSERT INTO scheduler(name, last_run) VALUES('realtime_decay_start', ?)", (utcnow_iso(),))

_realtime_decay_start_once()

def _economy_revamp_once() -> None:
    """One-time (2026-10-23, economy revamp): mines have no levels any more (all set to 1) and the
    player level follows the new curve (economy.py). Levels are recomputed in both directions; no
    level-up rewards are paid for this."""
    with get_db() as c:
        with econ.tx(c):
            if c.execute("SELECT 1 FROM scheduler WHERE name='economy_revamp_2026_10_23'").fetchone():
                return
            c.execute("UPDATE mines SET level=1 WHERE level IS NULL OR level<>1")
            for r in c.execute("SELECT hID, xp FROM players").fetchall():
                c.execute("UPDATE players SET level=? WHERE hID=?", (level_from_xp(r["xp"] or 0), r["hID"]))
            c.execute("INSERT INTO scheduler(name, last_run) VALUES('economy_revamp_2026_10_23', ?)", (utcnow_iso(),))

_economy_revamp_once()

SYSTEM_HELPERS = _types.SimpleNamespace(
    get_db=get_db, hid_from_sid=hid_from_sid, read_form=read_form, zlib_resp=zlib_resp,
    get_player=get_player, wh_capacity=wh_capacity, building_level=building_level,
    award_sink=award_sink, change_wa=change_wa, check_travel=check_travel, economy=economy, norm_name=norm_name,
    EVENT_HOOKS=EVENT_HOOKS, FIRE_DURATION_DAYS=FIRE_DURATION_DAYS, DISEASE_DURATION_DAYS=DISEASE_DURATION_DAYS,
    mine_rate_hr=mine_rate_hr, collect_mine=collect_mine, current_condition=current_condition, compute_repair_cost=compute_repair_cost, collect_mines_bulk=collect_mines_bulk,
    award_xp=award_xp, add_proto=add_proto, level_from_xp=level_from_xp, push=_push_to_player,
    mine_stats=mine_stats, mine_rows=mine_rows,
    MINE_TYPES=MINE_TYPES, SPECIAL_BUILDINGS=SPECIAL_BUILDINGS, HQ_BOOST_RADIUS=HQ_BOOST_RADIUS,
    HQ_BOOST_FACTORS=HQ_BOOST_FACTORS, FACTORY_TYPES=FACTORY_TYPES, TC_CONFIG=TC_CONFIG,
    HQ_UPGRADE_REQS=HQ_UPGRADE_REQS,
    DRONE_SCAN_RANGES=DRONE_SCAN_RANGES, new_id=new_id, SYSTEM_PRICES=SYSTEM_PRICES,
    LEVEL_UP_HOOKS=LEVEL_UP_HOOKS, CASINO_FIVE_HOOKS=CASINO_FIVE_HOOKS, OUTPUT_HOOKS=OUTPUT_HOOKS,
)
INSTALLED_SYSTEMS = systems.install_all(app, SYSTEM_HELPERS)

# ── Stub routes ───────────────────────────────────────────────────────────────────

for _path in [
    "/flut23/questGetData26.php", "/flut23/questStart.php", "/flut23/questClaimReward.php",
    "/flut23/achievementsGetData26.php", "/flut23/achievementsCheck26.php", "/flut23/achievementsClaim26.php",
    "/flut23/auctionsGetData.php", "/flut23/auctionsBid.php",
    "/flut23/loanGetList.php", "/flut23/loanReqLoan.php",
    "/flut23/specBuildingGetData.php", "/flut23/specBuildingBuy.php",
    "/flut23/statsLoadOverallData26.php", "/flut23/contactsGetData.php",
    "/flut23/hofGetData.php", "/flut23/artifactGetData.php",
    "/flut23/mapLoadArtifactMarkers.php",
]:
    app.add_api_route(_path, _stub_empty, methods=["GET","POST"])

# ── Catch-all ─────────────────────────────────────────────────────────────────────

@app.api_route("/{path:path}", methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"])
async def proxy_fallback(request: Request, path: str = ""):
    body = await request.body()
    resp = await proxy_to_original(request, body)
    log_entry({"ts": utcnow_iso(), "method": request.method, "path": path,
               "status": resp.status_code})
    return resp
