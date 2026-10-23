"""Company name rules (owner 2026-10-23): no rude names, no impersonation, no characters that could
break the game (only plain letters, digits and . , [ ] ( ) - and single spaces).

Rude words are found even when written with digits or symbols (n1gg3r, f.u.c.k, sh!t) or with
repeated letters (fuuuck): the name is lower-cased, look-alike characters are mapped to letters,
separators removed and repeated letters collapsed before the check. Long words are matched
anywhere in the name; short ones only as a whole word (so "scunthorpe"-style names survive).
"""
from __future__ import annotations

import re

ALLOWED = re.compile(r"^[a-zA-Z0-9 .,\[\]()\-]{3,20}$")
LEET = str.maketrans({"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "9": "g",
                      "@": "a", "$": "s", "!": "i", "|": "i", "+": "t"})
# matched anywhere (after normalising)
ANYWHERE = (
    "nigger", "niger", "nigga", "niga", "faggot", "fagot", "retard", "cunt", "fuck", "fuk", "shit", "bitch",
    "whore", "slut", "rapist", "rape", "nazi", "hitler", "heil", "porn", "penis", "vagina", "pussy",
    "asshole", "bastard", "wank", "jizz", "dildo", "blowjob", "boner", "cock", "dick", "tits", "boob",
    "pedo", "paedo", "molest", "incest", "genocide", "terrorist", "jihad", "hamas", "holocaust",
    "kurac", "kurca", "picka", "pizda", "jebem", "jebi", "jebo", "peder", "kurva", "govno", "sranje",
    "cigan", "debil", "kreten", "idiot", "moron", "suicide", "killyourself", "kys",
    # impersonating the game or its staff
    "moderator", "gamemaster", "resourcesteam",
)
# matched as a whole word only
WHOLE = ("fag", "cum", "sex", "anal", "ass", "hoe", "tit", "nig", "kill", "die", "mod", "gm",
         "system", "server", "null", "undefined", "none", "admin", "official", "support", "staff", "kkk")


def _norm(s: str) -> str:
    s = s.lower().translate(LEET)
    return re.sub(r"(.)\1{2,}", r"\1", s)        # fuuuck → fuck (runs of 3+; doubles stay: glass, kitty)


def name_problem(name: str) -> str | None:
    """None if the name is fine, else a message for the player."""
    if not ALLOWED.match(name or ""):
        return "Name: 3-20 letters, digits, spaces and . , [ ] ( ) -"
    if "  " in name or name != name.strip():
        return "No double spaces or spaces at the start or end"
    if not re.search(r"[a-zA-Z]", name):
        return "The name needs at least one letter"
    if re.search(r"[.,\[\]()\-]{3,}", name):
        return "Too many symbols in a row"
    flat = _norm(re.sub(r"[^a-z0-9@$!|+]", "", name.lower()))      # separators out first: n.i.g.g.a
    tokens = {t for t in re.split(r"[^a-z]+", _norm(name)) if t}
    if any(w in flat for w in _ANYWHERE_N) or tokens & _WHOLE_N or "kkk" in name.lower():
        return ("This name is not allowed. Rude or misleading names are not accepted, and accounts "
                "with such names can be banned or deleted.")
    return None


_ANYWHERE_N = tuple(_norm(w) for w in ANYWHERE)     # words normalised like names (repeats collapsed)
_WHOLE_N = {_norm(w) for w in WHOLE}
