import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))
from grid import grid_cols, grid_rows  # 與 renderer 同一份

cases = [(0,0,0),(1,1,1),(2,2,1),(3,3,1),(4,2,2),(5,3,2),(6,3,2),(7,3,3),(9,3,3),(10,3,4),(12,3,4)]
fail = 0
for n, c, r in cases:
    gc = grid_cols(n); gr = grid_rows(n, gc)
    if gc != c or gr != r:
        fail += 1; print(f"FAIL n={n}: got {gr}x{gc} want {r}x{c}")
# M!=3 case
if grid_cols(4, 2) != 2: fail += 1; print("FAIL n=4,M=2: cols not 2")
if grid_rows(4, 2) != 2: fail += 1; print("FAIL n=4,M=2: rows not 2")
print("grid: PASS" if fail == 0 else f"grid: FAIL={fail}")
sys.exit(0 if fail == 0 else 1)
