"""Links to phototrans.eu's vehicle search, for the bot's issues: one click instead of a search by hand.

phototrans's number search is exact and stops at 10 results across all of Europe (#9001 alone
gives Gdańsk trams, Prague buses and a Tokyo train), so each link names the operator. A new or
unknown number takes the operator of the nearest number of its kind in fleet.json, which is
right for a batch that grows (#9055 next to ReloBus's #9054). Trams use the same search page.

Operator ids from phototrans's Warsaw page (06,57,0,Warszawa.html), checked 2026-11-19.
"""
import bisect

SEARCH = "https://phototrans.eu/autobusy.php?s=5015&operator={}&numer={}&r=Send"
OPERATORS = {
    "MZA": 54,
    "Tramwaje Warszawskie": 65,
    "Mobilis": 193,
    "PKS Polonus": 172,
    "KMKM": 650,
    "ReloBus": 41021,
    "KM Łomianki": 241,
    "PKS Grodzisk": 12,
}


class Phototrans:
    def __init__(self, fleet):
        # (kind, number) → operator, in service and retired alike.
        self.operator = {}
        for key in ("models", "worksModels", "retiredModels"):
            for m in fleet.get(key, []):
                for b in m.get("batches", []) + m.get("retiredBatches", []):
                    for n in b["numbers"]:
                        self.operator[(m["kind"], n)] = b.get("operator")
        self.sorted = {k: sorted(n for kk, n in self.operator if kk == k) for k in ("BUS", "TRAM")}

    def operator_of(self, kind, number):
        if (kind, number) in self.operator:
            return self.operator[(kind, number)]
        # Trial buses are MZA's to run; a new number is most likely its neighbour's batch.
        if kind == "BUS" and 900 <= number <= 999:
            return "MZA"
        numbers = self.sorted.get(kind) or []
        if not numbers:
            return None
        i = bisect.bisect_left(numbers, number)
        near = min(numbers[max(i - 1, 0):i + 1], key=lambda n: abs(n - number))
        return self.operator[(kind, near)]

    def url(self, kind, number):
        op = OPERATORS.get(self.operator_of(kind, int(number)))
        # Without a known operator the search runs Europe-wide: still worth a look.
        return SEARCH.format(op if op else "--", number)

    def link(self, kind, number, text="phototrans"):
        return f"[{text}]({self.url(kind, number)})"
