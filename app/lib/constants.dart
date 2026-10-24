import 'package:flutter/widgets.dart';
import 'branding.dart';

const String kBaseUrl = Branding.apiBaseUrl;

const Map<int, String> kItemNames = {
  1: 'Credits',
  2: 'Clay', 3: 'Gravel', 7: 'Concrete', 8: 'Coal',
  10: 'Crude Oil', 12: 'Bauxite', 13: 'Iron Ore', 14: 'Gold Ore',
  15: 'Silver Ore', 20: 'Limestone', 22: 'Fertilizer', 24: 'Bricks',
  26: 'Chalcopyrite', 28: 'Insecticides', 30: 'Steel', 32: 'Aluminium',
  35: 'Silver', 36: 'Copper', 38: 'Fossil Fuel', 40: 'Roman Coins',
  41: 'Fossils', 42: 'Giant Diamonds', 43: 'Maintenance Kit',
  44: 'Tech Upgrade I', 45: 'Tech Upgrade II', 46: 'Tech Upgrade III',
  48: 'Tech Upgrade IV', 49: 'Ilmenite', 51: 'Titanium', 53: 'Quartz Sand',
  55: 'Copper Coins', 56: 'Old Tires', 57: 'Plastics', 58: 'Recycling Plant', 59: 'Glass',
  60: 'Glazier Workshop', 61: 'Casino', 62: 'Plastic Factory',
  63: 'Drone Factory', 64: 'Drone Factory II', 65: 'Museum',
  66: 'Electronics', 67: 'Silicon', 68: 'Silicon Refinery',
  69: 'Electronics Factory', 70: 'Scrap Metal', 71: 'Hospital',
  72: 'Law Firm', 74: 'Used Oil', 75: 'Medical Technology',
  76: 'Medical Tech Inc', 77: 'Plastic Scrap', 78: 'Electronic Scrap',
  79: 'Gold', 80: 'Gold Refinery', 81: 'Rough Diamonds',
  84: 'Jewellery', 85: 'Goldsmith', 86: 'Mafia HQ', 87: 'Weapons',
  88: 'Arms Dealer', 90: 'Lithium Ore', 91: 'Lithium Refinery',
  92: 'Lithium', 93: 'Batteries', 95: 'Watch Dogs', 96: 'Army Camp',
  97: 'Security Staff', 98: 'Elite Force', 99: 'Arms Factory',
  102: 'Attack Dogs', 103: 'Gangster', 104: 'Private Army',
  115: 'Waste Glass', 116: 'Tech Center', 117: 'Scan Drone',
  118: 'Drone Shipyard', 119: 'Drone Research', 120: 'Drone Wreckage',
  121: 'Service Center', 122: 'HR Department', 123: 'Haulage Firm',
  124: 'Trucks', 125: 'Truck Plant', 126: 'Fire Station',
  127: 'Seismology Centre',
  128: 'Luxury Chandelier', 129: 'Ancient Watch', 130: 'Unique Plate',
  131: 'Luxury Dog House', 132: 'Private Island', 133: 'Private Jet',
  134: 'Pyramid', 135: 'Eiffel Tower', 136: 'Salvator Mundi',
  137: 'Dinosaur Skeleton', 138: 'Luxury Watch', 139: 'Painting',
  140: 'Luxury Yacht', 141: 'Space Shuttle', 142: 'Luxury Motorhome',
  143: 'Castle', 144: 'Luxury Car', 145: 'Old Coins',
  146: 'Coin Collection', 147: 'Luxury Ranch', 148: 'Vineyard',
  149: 'Private Satellite', 150: 'Weapons Collection', 151: 'Bunker',
  152: 'Private Mansion', 153: 'Private Helicopter', 154: 'Gold Sculpture',
  155: 'Gold Foot', 156: 'Oldtimer', 157: 'Wine Cellar',
  158: 'Night Shift', 159: 'Overtime', 160: 'Guestworkers',
  161: 'Wage Subsidy', 163: 'Necklace', 164: 'Archeology Center',
  165: 'Detector Factory', 166: 'Artifact Detector', 167: 'Archeologists',
  169: 'Wolframite', 170: 'Tungsten Smelter', 171: 'Tungsten',
  172: 'Astrolabium', 173: 'Throne of Depths', 174: 'Shadow Obelisk',
  175: "Thor's Crucible", 176: 'Aeon Mechanism', 177: 'Dwarven Pick',
};

const Map<int, String> kMineNames = {
  4: 'Clay Pit', 5: 'Gravel Pit', 9: 'Coal Mine', 11: 'Oil Derrick',
  16: 'Bauxite Mine', 17: 'Iron Ore Mine', 18: 'Gold Mine',
  19: 'Silver Mine', 21: 'Limestone Quarry', 27: 'Copper Mine',
  50: 'Ilmenite Mine', 54: 'Sand Mine', 82: 'Diamond Mine',
  89: 'Lithium Ore Mine', 168: 'Wolframite Mine',
};

// mine item_id → resource item_id it produces
const Map<int, int> kMineResource = {
  4: 2, 5: 3, 9: 8, 11: 10, 16: 12, 17: 13, 18: 14, 19: 15,
  21: 20, 27: 26, 50: 49, 54: 53, 82: 81, 89: 90, 168: 169,
};

// mine item_id → base units per hour at level 1, 100% quality/condition, no tech
// = official max_rate / 5 (linear level scaling: output = base * level)
const Map<int, int> kMineBaseRate = {
  // economy revamp 2026-10-23: srs.txt output per hour at 100 % quality (server: economy.MINES)
  4: 1530, 5: 542, 9: 510, 11: 306, 16: 306, 17: 383, 18: 2040, 19: 638,
  21: 510, 27: 408, 50: 281, 54: 765, 82: 1275, 89: 2040, 168: 510,
};

// mine item_id → build cost (credits)
const Map<int, int> kMineBuildCost = {
  // economy revamp: costs.txt base cost / 25 (server: economy.mine_base_cost); the demolish refund
  // is 10 % of this base cost
  4: 40000, 5: 200000, 9: 2000000, 11: 4000000, 16: 24000000, 17: 400000,
  18: 60000000, 19: 50000000, 21: 100000, 27: 16000000, 50: 40000000, 54: 8000000,
  82: 80000000, 89: 32000000, 168: 72000000,
};

// mine level → upgrade cost (level is the TARGET level)
const Map<int, int> kMineUpgradeCost = {
  2: 5000, 3: 15000, 4: 40000, 5: 100000,
};

const int kMaxMineLevel = 5;

// tech level → required item_id
const Map<int, int> kTechUpgradeItem = {1: 44, 2: 45, 3: 46, 4: 48};


// Factory item_id → factory name
const Map<int, String> kFactoryNames = {
  6: 'Concrete Factory', 23: 'Fertilizer Factory', 25: 'Brick Factory',
  29: 'Insecticide Factory', 31: 'Ironworks', 33: 'Aluminium Factory',
  34: 'Silver Refinery', 37: 'Copper Refinery', 39: 'Oil Refinery',
  52: 'Titanium Refinery', 58: 'Recycling Plant', 60: "Glazier's Workshop", 94: 'Battery Factory',
  61: 'Casino', 62: 'Plastic Factory', 63: 'Drone Factory',
  65: 'Museum', 68: 'Silicon Refinery', 69: 'Electronics Factory',
  71: 'Hospital', 72: 'Law Firm', 76: 'Medical Tech Inc',
  80: 'Gold Refinery', 85: 'Goldsmith', 86: 'Mafia HQ', 91: 'Lithium Refinery',
  96: 'Army Camp', 99: 'Arms Factory', 116: 'Tech Center',
  118: 'Drone Shipyard', 121: 'Service Center', 122: 'HR Department',
  123: 'Haulage Firm', 125: 'Truck Plant', 126: 'Fire Station',
  127: 'Seismology Centre', 164: 'Archeology Center',
  165: 'Detector Factory', 170: 'Tungsten Smelter',
};

// item_id → market base price (ꞓ per unit)
const Map<int, int> kBasePrice = {
  2: 5, 3: 5, 7: 20, 8: 15, 10: 40, 12: 18, 13: 20, 14: 200,
  15: 80, 20: 8, 24: 25, 26: 35, 30: 60, 32: 90, 35: 150,
  36: 120, 38: 70, 49: 45, 53: 6, 79: 500, 81: 400, 90: 300, 169: 350,
};

String itemName(int id) => kItemNames[id] ?? kMineNames[id] ?? kFactoryNames[id] ?? 'Item $id';
String mineName(int id) => kMineNames[id] ?? 'Mine';
String factoryName(int id) => kFactoryNames[id] ?? itemName(id);

// Factory types: item_id → {produces, out(units/batch), hrs(per batch)}. Starts with the original
// eight and is completed from the server catalog (factory_screen.dart), which lists all factories.
final Map<int, Map<String, dynamic>> kFactoryTypes = {
  6:  {'produces': 7,  'out': 50,  'hrs': 2},
  25: {'produces': 24, 'out': 80,  'hrs': 2},
  31: {'produces': 30, 'out': 40,  'hrs': 4},
  33: {'produces': 32, 'out': 30,  'hrs': 3},
  34: {'produces': 35, 'out': 20,  'hrs': 5},
  37: {'produces': 36, 'out': 25,  'hrs': 4},
  39: {'produces': 38, 'out': 15,  'hrs': 6},
  80: {'produces': 79, 'out': 10,  'hrs': 8},
};

// mine item_id → minimum player level required to build (per official reference)
const Map<int, int> kMineMinLevel = {
  4: 1, 5: 3, 9: 4, 11: 1, 16: 11, 17: 4, 18: 38, 19: 33,
  21: 2, 27: 9, 50: 20, 54: 7, 82: 48, 89: 15, 168: 50,
};

// Tech center level → max quality percentage shown by scanner
const List<int> kTcMaxQuality = [26, 34, 42, 49, 56, 63, 71, 79, 85, 93, 100];

// Tech center level → scan radius in metres (matches TC_CONFIG in server)
const List<int> kTcScanRadius = [150, 200, 250, 300, 350, 400, 500, 600, 750, 900, 1125];

// Drone scan range in metres per Drone Research level (item 119), levels 1–10
// same as the server (DRONE_SCAN_RANGES): at most 10 km
const List<int> kDroneScanRanges = [500, 1000, 1500, 2000, 3000, 4000, 5000, 6500, 8000, 10000];


// Special buildings: item_id → config
// res keys MUST be strings (e.g. '24') to match lager map string keys
// not const: the costs are replaced by the server's (rebalanced) costs at runtime
final Map<int, Map<String, dynamic>> kSpecialBuildings = {
  116: {
    'name': 'Tech Center',
    'desc': 'Your scanning base. It decides how far your scans reach and how good the resources are that they can reveal.',
    'maxLevel': 10,
    'costs': [
      {'credits': 200000,    'res': {'24': 100}},
      {'credits': 500000,    'res': {'24': 500,   '7': 100}},
      {'credits': 1500000,   'res': {'30': 500}},
      {'credits': 4000000,   'res': {'30': 1000,  '32': 100}},
      {'credits': 10000000,  'res': {'30': 2000,  '32': 500}},
      {'credits': 25000000,  'res': {'30': 5000,  '32': 1000, '79': 100}},
      {'credits': 60000000,  'res': {'30': 10000, '79': 5000}},
      {'credits': 150000000, 'res': {'79': 20000, '81': 100}},
      {'credits': 350000000, 'res': {'79': 50000, '81': 500}},
      {'credits': 800000000, 'res': {'79': 100000, '81': 1000}},
    ],
  },
  119: {
    'name': 'Drone Research',
    'desc': 'Lets you scan and collect cargo with drones far from where you are, and at the top level build mines remotely.',
    'maxLevel': 10,
    'costs': [
      {'credits': 1000000,     'res': {'66': 500,    '117': 2}},
      {'credits': 5000000,     'res': {'66': 2000,   '117': 8}},
      {'credits': 20000000,    'res': {'66': 8000,   '117': 25}},
      {'credits': 80000000,    'res': {'66': 30000,  '117': 75}},
      {'credits': 300000000,   'res': {'66': 100000, '117': 200}},
      {'credits': 1000000000,  'res': {'66': 300000, '117': 500,   '79': 1000}},
      {'credits': 3000000000,  'res': {'66': 800000, '117': 1200,  '79': 4000}},
      {'credits': 8000000000,  'res': {'81': 500,    '117': 2500,  '79': 15000}},
      {'credits': 20000000000, 'res': {'81': 2000,   '117': 5000,  '79': 50000}},
      {'credits': 50000000000, 'res': {'81': 5000,   '117': 10000, '79': 150000}},
    ],
  },
  65: {
    'name': 'Museum',
    'desc': 'Studies the objects you find. It lets you pick up cargo and artifacts from further away, adds to every crate you open and unlocks rarer objects.',
    'maxLevel': 10,
    'costs': [
      {'credits': 500000,      'res': {'41': 200,    '40': 100}},
      {'credits': 2000000,     'res': {'41': 800,    '40': 400,   '55': 200}},
      {'credits': 8000000,     'res': {'41': 2000,   '40': 1000,  '55': 500}},
      {'credits': 30000000,    'res': {'41': 6000,   '40': 3000,  '55': 1500}},
      {'credits': 100000000,   'res': {'41': 15000,  '40': 7000,  '55': 4000}},
      {'credits': 300000000,   'res': {'41': 40000,  '40': 18000, '55': 10000}},
      {'credits': 800000000,   'res': {'41': 100000, '40': 45000, '55': 25000,  '79': 500}},
      {'credits': 2000000000,  'res': {'41': 250000, '40': 110000,'55': 60000,  '79': 2000}},
      {'credits': 5000000000,  'res': {'41': 600000, '40': 270000,'55': 150000, '79': 6000}},
      {'credits': 12000000000, 'res': {'41': 1500000,'40': 650000,'55': 350000, '79': 15000}},
    ],
  },
  71: {
    'name': 'Hospital',
    'desc': 'Keeps your miners healthy, so diseases break out less often and spread less between your mines.',
    'maxLevel': 10,
    'costs': [
      {'credits': 500000,      'res': {'24': 2000,    '75': 50}},
      {'credits': 2000000,     'res': {'24': 8000,    '75': 200,   '35': 500}},
      {'credits': 8000000,     'res': {'24': 25000,   '75': 500,   '35': 2000}},
      {'credits': 30000000,    'res': {'24': 60000,   '75': 1500,  '35': 8000}},
      {'credits': 100000000,   'res': {'24': 150000,  '75': 5000,  '35': 30000}},
      {'credits': 300000000,   'res': {'24': 400000,  '75': 12000, '35': 75000}},
      {'credits': 800000000,   'res': {'24': 1000000, '75': 30000, '35': 180000, '79': 500}},
      {'credits': 2000000000,  'res': {'24': 2500000, '75': 75000, '35': 450000, '79': 2000}},
      {'credits': 5000000000,  'res': {'24': 6000000, '75': 180000,'35': 1000000,'79': 6000}},
      {'credits': 12000000000, 'res': {'24': 15000000,'75': 450000,'35': 2500000,'79': 15000}},
    ],
  },
  58: {
    'name': 'Recycling Plant',
    'desc': 'Turns found objects you don\'t need into useful resources.',
    'maxLevel': 10,
    'costs': [
      {'credits': 300000,      'res': {'70': 1000,    '77': 500,    '115': 500}},
      {'credits': 1500000,     'res': {'70': 5000,    '77': 2000,   '115': 2000}},
      {'credits': 6000000,     'res': {'70': 15000,   '77': 6000,   '115': 6000}},
      {'credits': 20000000,    'res': {'70': 40000,   '77': 15000,  '115': 15000}},
      {'credits': 60000000,    'res': {'70': 100000,  '77': 40000,  '115': 40000}},
      {'credits': 180000000,   'res': {'70': 250000,  '77': 100000, '115': 100000}},
      {'credits': 500000000,   'res': {'70': 600000,  '77': 240000, '115': 240000, '79': 200}},
      {'credits': 1300000000,  'res': {'70': 1500000, '77': 600000, '115': 600000, '79': 800}},
      {'credits': 3500000000,  'res': {'70': 3500000, '77': 1400000,'115': 1400000,'79': 2500}},
      {'credits': 9000000000,  'res': {'70': 8000000, '77': 3200000,'115': 3200000,'79': 7000}},
    ],
  },
  127: {
    'name': 'Seismology Centre',
    'desc': 'Monitors earthquakes and reinforces your mines, so quakes damage them less.',
    'maxLevel': 10,
    'costs': [
      {'credits': 1000000,     'res': {'66': 1000,    '93': 500,    '79': 100}},
      {'credits': 5000000,     'res': {'66': 5000,    '93': 2000,   '79': 500}},
      {'credits': 20000000,    'res': {'66': 15000,   '93': 6000,   '79': 2000}},
      {'credits': 80000000,    'res': {'66': 40000,   '93': 15000,  '79': 6000}},
      {'credits': 300000000,   'res': {'66': 100000,  '93': 40000,  '79': 20000}},
      {'credits': 1000000000,  'res': {'66': 250000,  '93': 100000, '79': 50000}},
      {'credits': 3000000000,  'res': {'66': 600000,  '93': 250000, '79': 125000, '81': 200}},
      {'credits': 8000000000,  'res': {'66': 1500000, '93': 600000, '79': 300000, '81': 800}},
      {'credits': 20000000000, 'res': {'66': 3500000, '93': 1400000,'79': 700000, '81': 2500}},
      {'credits': 50000000000, 'res': {'66': 8000000, '93': 3200000,'79': 1600000,'81': 6000}},
    ],
  },
  126: {
    'name': 'Fire Station',
    'desc': 'Protects your factories: fires break out less often and are put out sooner.',
    'maxLevel': 10,
    'costs': [
      {'credits': 1000000,     'res': {'124': 500,     '117': 50,    '97': 500}},
      {'credits': 5000000,     'res': {'124': 2000,    '117': 100,   '97': 2000}},
      {'credits': 20000000,    'res': {'124': 6000,    '117': 250,   '97': 5000}},
      {'credits': 80000000,    'res': {'124': 15000,   '117': 500,   '97': 10000}},
      {'credits': 300000000,   'res': {'124': 40000,   '117': 1000,  '97': 25000}},
      {'credits': 1000000000,  'res': {'124': 100000,  '117': 2500,  '97': 60000}},
      {'credits': 3000000000,  'res': {'124': 250000,  '117': 6000,  '97': 150000, '32': 500}},
      {'credits': 8000000000,  'res': {'124': 600000,  '117': 14000, '97': 350000, '32': 2000}},
      {'credits': 20000000000, 'res': {'124': 1400000, '117': 33000, '97': 800000, '32': 6000}},
      {'credits': 50000000000, 'res': {'124': 3200000, '117': 75000, '97': 1800000,'32': 15000}},
    ],
  },
  123: {
    'name': 'Haulage Firm',
    'desc': 'Your transport company. It lowers the market transport tax, extends the range of your trucks and unlocks Stacked Cargo Rain and truck collection.',
    'maxLevel': 10,
    'costs': [
      {'credits': 200000,      'res': {'7': 500,    '2': 1000}},
      {'credits': 600000,      'res': {'7': 2000,   '2': 4000}},
      {'credits': 2000000,     'res': {'7': 5000,   '20': 2000}},
      {'credits': 5000000,     'res': {'7': 10000,  '20': 5000,  '24': 500}},
      {'credits': 12000000,    'res': {'7': 20000,  '20': 10000, '24': 2000}},
      {'credits': 30000000,    'res': {'30': 5000,  '24': 5000,  '36': 1000}},
      {'credits': 70000000,    'res': {'30': 12000, '36': 3000,  '32': 500}},
      {'credits': 160000000,   'res': {'30': 25000, '36': 8000,  '32': 2000}},
      {'credits': 350000000,   'res': {'30': 50000, '79': 5000,  '32': 5000}},
      {'credits': 750000000,   'res': {'30': 100000, '79': 15000, '81': 500}},
    ],
  },
  61: {
    'name': 'Casino',
    'desc': 'Your own slot machine with free daily spins and a jackpot that grows with every spin.',
    'maxLevel': 10,
    'costs': [
      {'credits': 2500000,     'res': {'7': 2000,    '40': 1000,   '55': 500}},
      {'credits': 7500000,     'res': {'7': 5000,    '40': 3000,   '55': 1500}},
      {'credits': 20000000,    'res': {'7': 10000,   '40': 6000,   '55': 3000}},
      {'credits': 50000000,    'res': {'7': 20000,   '40': 12000,  '55': 6000}},
      {'credits': 120000000,   'res': {'7': 40000,   '40': 25000,  '55': 12000}},
      {'credits': 300000000,   'res': {'7': 80000,   '40': 50000,  '55': 25000}},
      {'credits': 700000000,   'res': {'7': 150000,  '40': 100000, '55': 50000}},
      {'credits': 1500000000,  'res': {'7': 300000,  '40': 200000, '55': 100000}},
      {'credits': 3500000000,  'res': {'7': 600000,  '40': 400000, '55': 200000}},
      {'credits': 8000000000,  'res': {'7': 1000000, '40': 800000, '55': 400000}},
    ],
  },
  86: {
    'name': 'Mafia HQ',
    'desc': 'Hires criminals to attack other players\' mines. A won attack brings you part of the mine\'s output.',
    'maxLevel': 10,
    'costs': [
      {'credits': 2000000,     'res': {'24': 500,    '20': 500,   '70': 500}},
      {'credits': 8000000,     'res': {'24': 2000,   '20': 2000,  '70': 2000}},
      {'credits': 25000000,    'res': {'24': 6000,   '70': 6000,  '87': 50}},
      {'credits': 70000000,    'res': {'70': 15000,  '87': 200,   '79': 100}},
      {'credits': 150000000,   'res': {'70': 30000,  '87': 500,   '79': 500}},
      {'credits': 400000000,   'res': {'70': 75000,  '87': 1200,  '79': 1500}},
      {'credits': 1000000000,  'res': {'70': 180000, '87': 3000,  '79': 4000,  '81': 50}},
      {'credits': 2500000000,  'res': {'70': 430000, '87': 7000,  '79': 10000, '81': 200}},
      {'credits': 6000000000,  'res': {'70': 1000000,'87': 16000, '79': 24000, '81': 600}},
      {'credits': 15000000000, 'res': {'70': 2400000,'87': 38000, '79': 55000, '81': 1500}},
    ],
  },
  72: {
    'name': 'Law Firm',
    'desc': 'Your lawyers soften the consequences of incidents: mine diseases, earthquake damage and factory fires.',
    'maxLevel': 10,
    'costs': [
      {'credits': 500000,     'res': {'59': 200,   '32': 100,   '57': 50}},
      {'credits': 2000000,    'res': {'59': 800,   '32': 300,   '57': 200}},
      {'credits': 6000000,    'res': {'59': 2000,  '32': 800,   '57': 500}},
      {'credits': 15000000,   'res': {'59': 4000,  '32': 2000,  '57': 1200}},
      {'credits': 30000000,   'res': {'59': 8000,  '32': 4000,  '57': 2500}},
      {'credits': 70000000,   'res': {'59': 20000, '32': 10000, '57': 6000}},
      {'credits': 160000000,  'res': {'59': 50000, '32': 25000, '57': 15000, '79': 100}},
      {'credits': 360000000,  'res': {'59': 120000,'32': 60000, '57': 36000, '79': 400}},
      {'credits': 800000000,  'res': {'59': 280000,'32': 140000,'57': 84000, '79': 1200}},
      {'credits': 1800000000, 'res': {'59': 650000,'32': 325000,'57': 195000,'79': 3500}},
    ],
  },
  121: {
    'name': 'Service Center',
    'desc': 'Rewards you for maintaining other players\' mines and can add bonus crates to the reward.',
    'maxLevel': 10,
    'costs': [
      {'credits': 1000000,    'res': {'93': 20,    '35': 50,     '36': 15}},
      {'credits': 4000000,    'res': {'93': 80,    '35': 200,    '36': 60}},
      {'credits': 10000000,   'res': {'93': 200,   '35': 500,    '36': 150}},
      {'credits': 20000000,   'res': {'93': 400,   '35': 1000,   '36': 300}},
      {'credits': 40000000,   'res': {'93': 800,   '35': 2000,   '36': 600}},
      {'credits': 90000000,   'res': {'93': 1800,  '35': 4500,   '36': 1350}},
      {'credits': 200000000,  'res': {'93': 4000,  '35': 10000,  '36': 3000,  '79': 50}},
      {'credits': 450000000,  'res': {'93': 9000,  '35': 22500,  '36': 6750,  '79': 200}},
      {'credits': 1000000000, 'res': {'93': 20000, '35': 50000,  '36': 15000, '79': 600}},
      {'credits': 2200000000, 'res': {'93': 44000, '35': 110000, '36': 33000, '79': 1800}},
    ],
  },
  122: {
    'name': 'HR Department',
    'desc': 'Keeps your workforce content, so strikes break out less often and cost you less.',
    'maxLevel': 10,
    'costs': [
      {'credits': 1000000,    'res': {'36': 50,     '98': 1,    '66': 50}},
      {'credits': 4000000,    'res': {'36': 200,    '98': 2,    '66': 200}},
      {'credits': 10000000,   'res': {'36': 500,    '98': 5,    '66': 500}},
      {'credits': 20000000,   'res': {'36': 1000,   '98': 15,   '66': 1000}},
      {'credits': 40000000,   'res': {'36': 2000,   '98': 40,   '66': 2000}},
      {'credits': 90000000,   'res': {'36': 4500,   '98': 90,   '66': 4500}},
      {'credits': 200000000,  'res': {'36': 10000,  '98': 200,  '66': 10000, '79': 50}},
      {'credits': 450000000,  'res': {'36': 22000,  '98': 450,  '66': 22000, '79': 200}},
      {'credits': 1000000000, 'res': {'36': 48000,  '98': 1000, '66': 48000, '79': 600}},
      {'credits': 2200000000, 'res': {'36': 105000, '98': 2200, '66': 105000,'79': 1800}},
    ],
  },
  164: {
    'name': 'Archaeological Center',
    'desc': 'Unlocks the artifact detector and the recovery of ancient artifacts by your archaeologists.',
    'maxLevel': 10,
    'costs': [
      {'credits': 2000000,    'res': {'166': 1,   '124': 10,    '79': 40}},
      {'credits': 8000000,    'res': {'166': 2,   '124': 30,    '79': 150}},
      {'credits': 20000000,   'res': {'166': 3,   '124': 80,    '79': 400}},
      {'credits': 50000000,   'res': {'166': 5,   '124': 200,   '79': 1000}},
      {'credits': 100000000,  'res': {'166': 10,  '124': 500,   '79': 2500}},
      {'credits': 250000000,  'res': {'166': 20,  '124': 1200,  '79': 6000}},
      {'credits': 600000000,  'res': {'166': 40,  '124': 2800,  '79': 14000, '81': 20}},
      {'credits': 1500000000, 'res': {'166': 80,  '124': 6500,  '79': 32000, '81': 80}},
      {'credits': 3500000000, 'res': {'166': 160, '124': 15000, '79': 75000, '81': 250}},
      {'credits': 8000000000, 'res': {'166': 320, '124': 35000, '79': 175000,'81': 750}},
    ],
  },
};

// WA booster items: itemId → {name, boost multiplier, WA delta, hours}
const Map<int, Map<String, dynamic>> kWaBoosters = {
  158: {'name': 'Night Shift',   'boost': 1.30, 'waDelta': -20, 'hours': 8},
  159: {'name': 'Overtime',      'boost': 1.10, 'waDelta': -5,  'hours': 8},
  160: {'name': 'Guest Workers', 'boost': 1.20, 'waDelta': -15, 'hours': 8},
  161: {'name': 'Wage Subsidy',  'boost': 1.50, 'waDelta': 10, 'hours': 8},
};

// Alias used in factory_screen
Map<int, Map<String, dynamic>> get WA_BOOSTERS => kWaBoosters;

/// Returns asset path for a resource image, or null if no image exists.
const Set<int> _kResImageIds = {
  1,2,3,6,7,8,10,12,13,14,15,20,22,23,24,25,26,28,29,30,31,32,33,34,35,36,
  37,38,39,40,41,42,43,44,45,46,48,49,51,52,53,55,57,58,59,60,61,62,63,64,
  65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,84,85,86,87,88,90,91,
  92,93,95,96,97,98,99,101,102,103,104,115,116,117,118,119,120,121,122,123,
  124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,
  142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
  160,161,163,164,165,166,167,169,170,171,172,173,174,175,176,177,
};

/// Items whose picture has a different number in the original artwork (owner 2026-10-24):
/// Plastics → res58, Old Tires → res57, Glass → res60, Watch Dogs → res96, Security Staff → res98, Elite Force → res99;
/// factories: Recycling Plant → res59, Glazier's Workshop → res61, Casino → res62, Plastic Factory → res63,
/// Drone Factory → res64, Battery Factory → res95, Army Camp → res97, Arms Factory → res101.
const Map<int, int> kItemImageOverride = {
  57: 58, 56: 57, 59: 60, 95: 96, 97: 98, 98: 99,
  58: 59, 60: 61, 61: 62, 62: 63, 63: 64, 94: 95, 96: 97, 99: 101,
};

/// Asset path of an item's picture (always use this, never 'res$id' directly).
String resAsset(int id) => 'assets/images_res/res${kItemImageOverride[id] ?? id}.png';

String? resImagePath(int id) {
  final img = kItemImageOverride[id] ?? id;
  return _kResImageIds.contains(img) ? 'assets/images_res/res$img.png' : null;
}

/// Decodes all resource images into Flutter's image cache.
/// Call once during the splash screen so every tab shows images instantly.
void precacheResImages(BuildContext ctx) {
  for (final id in _kResImageIds) {
    precacheImage(AssetImage('assets/images_res/res$id.png'), ctx);
  }
}

/// Number of decimal places used by [fmtNum]. Changed at runtime from settings.
int kNumDecimals = 1;

/// Market colours: ASK red / BID green like a stock ticker; Settings > Numbers & Display can invert.
bool kInvertAskBid = false;
Color get kAskColor => kInvertAskBid ? const Color(0xFF4CAF50) : const Color(0xFFEF5350);
Color get kBidColor => kInvertAskBid ? const Color(0xFFEF5350) : const Color(0xFF4CAF50);

/// Format large numbers with suffix. Uses [kNumDecimals] decimal places.
/// kNumDecimals == -1 → full digits with comma separators (no suffix).
String fmtNum(num n, {int? decimals}) {
  final d = decimals ?? kNumDecimals;
  if (d < 0) {
    final v = n.round().abs();
    final s = v.toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    final start = s.length % 3;
    if (start > 0) buf.write(s.substring(0, start));
    for (int i = start; i < s.length; i += 3) {
      if (buf.isNotEmpty && buf.toString() != '-') buf.write(',');
      buf.write(s.substring(i, i + 3));
    }
    return buf.toString();
  }
  if (n >= 1e15) return '${(n / 1e15).toStringAsFixed(d)}Q';
  if (n >= 1e12) return '${(n / 1e12).toStringAsFixed(d)}T';
  if (n >= 1e9)  return '${(n / 1e9).toStringAsFixed(d)}B';
  if (n >= 1e6)  return '${(n / 1e6).toStringAsFixed(d)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(d)}K';
  return n.toStringAsFixed(0);
}

/// Format a quality percentage: integer for whole numbers, 2 decimals otherwise.
/// e.g. 70 → "70%", 10.25 → "10.25%"
String fmtQual(num q) {
  final d = q - q.truncate();
  return d == 0 ? '${q.toInt()}%' : '${q.toStringAsFixed(2)}%';
}
