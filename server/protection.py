"""Protective special buildings (Phase 9). The game files only describe *what* each building
protects against, not by how much, so the percentages are a configurable proposal:

- Hospital (71): random mine disease chance −7 %/level, spread chance −5 %/level.
- Fire Station (126): factory fire chance −8 %/level, fire duration −5 %/level.
- Seismology Centre (127): earthquake damage −6 %/level (−60 % at level 10).
- Law Firm (72): claims −5 %/level (eva.txt). The game has no lawsuit/claim mechanic yet, so
  nothing calls law_firm_factor() — documented as BLOCKED until claims exist.
"""
HOSPITAL = 71
LAW_FIRM = 72
FIRE_STATION = 126
SEISMOLOGY = 127

HOSPITAL_DISEASE_PER_LEVEL = 0.07
HOSPITAL_SPREAD_PER_LEVEL = 0.05
FIRE_CHANCE_PER_LEVEL = 0.08
FIRE_DURATION_PER_LEVEL = 0.05
SEISMO_PER_LEVEL = 0.06
LAW_PER_LEVEL = 0.05


def _f(level, per):
    return max(0.0, 1.0 - per * max(0, min(10, int(level or 0))))


def disease_factor(level):
    return _f(level, HOSPITAL_DISEASE_PER_LEVEL)


def spread_factor(level):
    return _f(level, HOSPITAL_SPREAD_PER_LEVEL)


def fire_factor(level):
    return _f(level, FIRE_CHANCE_PER_LEVEL)


def fire_duration_factor(level):
    return _f(level, FIRE_DURATION_PER_LEVEL)


def quake_factor(level):
    return _f(level, SEISMO_PER_LEVEL)


def law_firm_factor(level):
    return _f(level, LAW_PER_LEVEL)
