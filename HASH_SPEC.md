## BGLogger Hash Specification (simple_v1)

This document defines the exact hash used by BGLogger to verify battleground logs. The addon and the website MUST implement this identically. Any change here requires a coordinated change on both sides.

### Version
- algorithm: simple_v1

### Inputs included in the hash
- Battleground metadata
  - battleground: map name (normalized)
  - duration: integer seconds
  - winner: winner string (normalized)
- Players (all players in the saved stats list)
  - name (normalized)
  - realm (normalized)
  - damage (integer)
  - healing (integer)

Notes:
- Fields `type` and `date` are NOT included in the hash.
- Players are sorted by normalized `name` ascending before hashing.

### Normalization
For any field marked “normalized”, characters outside ASCII range are replaced with underscore `_`.

Pseudo-code:
```
function normalizeString(str):
  s = toString(str or "")
  out = ""
  for each byte b in s:
    if b <= 127: out += char(b)
    else: out += "_"
  return out
```

### Canonical data string construction
1) Build array `parts`:
   - push normalizeString(battleground)
   - push tostring(duration)
   - push normalizeString(winner)
2) Sort players by normalizeString(player.name)
3) For each player in sorted order, push a player part:
   - playerPart = normalizeString(name) + "|" + normalizeString(realm) + "|" + tostring(damage) + "|" + tostring(healing)
4) Join parts with double-pipe separator: `dataString = table.concat(parts, "||")`

Separators:
- Between metadata and each player entry: `||`
- Inside a player entry: `|`

### Hash algorithm
Custom DJB2-style variant with 31-bit modulus.

Pseudo-code:
```
function simpleStringHash(dataString):
  hash = 5381
  for each byte b in dataString:
    hash = ((hash * 33) + b) % 2147483647
  return toUpperHex(hash, width=8)  // zero-padded to 8 chars
```

### Golden test vectors
Use `/bgdebug goldens` in-game to compute these, then copy the resulting expected hashes below and into the website test suite. Keep vectors identical across addon and website.

Vector 1: Simple ASCII names
```
metadata:
  battleground: "Warsong Gulch"
  duration: 180
  winner: "Alliance"
players (pre-sort):
  - { name: "Alice", realm: "Stormrage", damage: 100000, healing: 5000 }
  - { name: "Bob", realm: "Area-52",  damage: 80000,  healing: 0 }
expected: <fill-after-running-/bgdebug-goldens>
```

Vector 2: Non-ASCII characters (normalized to `_`)
```
metadata:
  battleground: "Arathi Basin"
  duration: 900
  winner: "Horde"
players (pre-sort):
  - { name: "Kìllah", realm: "Tichondrius", damage: 123456, healing: 7890 }
  - { name: "Änne",   realm: "Aegwynn",     damage: 654321, healing: 42 }
expected: <fill-after-running-/bgdebug-goldens>
```

Vector 3: Sorting check (names differ by case and punctuation)
```
metadata:
  battleground: "Eye of the Storm"
  duration: 1200
  winner: "Alliance"
players (pre-sort):
  - { name: "charlie", realm: "Illidan", damage: 1, healing: 2 }
  - { name: "Charlie", realm: "Illidan", damage: 3, healing: 4 }
  - { name: "Charlie.", realm: "Illidan", damage: 5, healing: 6 }
expected: <fill-after-running-/bgdebug-goldens>
```

### How to use
1) In-game (addon): run `/bgdebug goldens` to compute/verify vectors.
2) On the website repo: add a unit test file that re-implements this spec exactly and asserts the three vectors match the expected hashes.
3) If anything fails, do not change the algorithm; investigate data construction/normalization or player ordering first.


