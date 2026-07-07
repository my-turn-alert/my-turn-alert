"""grid.py — 共用的自適應網格數學（與 grid.ps1 規格一致）。renderer 與測試都 import 此檔。"""
import math


def grid_cols(n, m=3):
    if n <= 0:
        return 0
    if n <= m:
        return n
    return min(m, math.ceil(math.sqrt(n)))


def grid_rows(n, c):
    return 0 if c <= 0 else math.ceil(n / c)
