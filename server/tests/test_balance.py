"""Owner balance settings: new companies start with 500 000 credits; scans cost 10x less."""
from helpers import credits, new_player

import main


def test_new_company_starting_credits():
    hid, _, _ = new_player("start")
    assert credits(hid) == main.STARTING_CREDITS == 250_000


def test_scan_cost_divisor():
    assert main.SCAN_COST_DIVISOR == 10


def test_scan_cost_by_mines_and_tech_center():
    import economy
    assert economy.scan_cost(4, 0, 50) == 0                 # new company: free
    assert economy.scan_cost(4, 1, 10) == 440               # Tech Center built: paid
    assert economy.scan_cost(5, 0, 0) == 20                 # level 5: paid
    assert economy.scan_cost(30, 10, 1000) == economy.scan_cost(80, 10, 1000) == 220_220
