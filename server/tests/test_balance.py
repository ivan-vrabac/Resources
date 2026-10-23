"""Owner balance settings: new companies start with 500 000 credits; scans cost 10x less."""
from helpers import credits, new_player

import main


def test_new_company_starting_credits():
    hid, _, _ = new_player("start")
    assert credits(hid) == main.STARTING_CREDITS == 250_000


def test_scan_cost_divisor():
    assert main.SCAN_COST_DIVISOR == 10
