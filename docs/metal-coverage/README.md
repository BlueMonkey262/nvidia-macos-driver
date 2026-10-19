# Metal coverage map

`docs/metal-coverage.svg` (shown at the top of the main README) has one cell per method of each public Metal protocol.
The whole API counts, including features made for Apple silicon.

| Color | Meaning |
|---|---|
| gray | not implemented |
| teal | answered by Apple's own Metal code, not by this driver |
| red | implemented but very slow |
| yellow | needs improvement, fine for now |
| green | works great |
| purple | implemented but does not return what Apple's implementation returns |
| blue | implemented, not yet rated |

A color other than gray, teal and blue only comes from `tools/metal-ratings.json`, with a note and the evidence (a test,
a measurement or a source line). "Implemented" means a driver class answers the selector; it says nothing about whether
it works.

## Refreshing the data

CI re-renders the picture when this directory, `tools/metal_coverage.py` or `tools/metal-ratings.json` changes. The method
list and who answers each selector are measured on a Mac with the driver installed (read-only, nothing is changed):

```sh
clang -fobjc-arc -framework Foundation -framework Metal -o metal_coverage tools/metal_coverage.m
./metal_coverage > raw.json
python3 tools/metal_coverage.py raw.json --public-list docs/metal-coverage/public-protocols.txt \
  --slim docs/metal-coverage/dump.json --svg docs/metal-coverage.svg -o coverage.html
```

`public-protocols.txt` lists protocol names taken from the macOS SDK headers (names only; the headers are Apple's and are
not stored here). `coverage.html` is the interactive page with a tooltip per method.
