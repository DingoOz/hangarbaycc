---
name: mud-py-bugs-found-and-fixed
description: Bug review and fixes for mud.py — 4 bugs documented, #1 fixed.
metadata:
  type: feedback
---

## Bug Review of `mud.py`

### Bug #1 (FIXED): `fight()` returns None on win instead of True

**Location:** Lines 256–258 in `fight()`.

```python
if enemy_info["hp"] <= 0:
    print(f"\nYou defeated the {enemy_name}!")
    break   # ← breaks out of while, function returns None!
elif player.hp <= 0:
    print("\nYou have been killed...")
    return False   # ← explicit False here
```

When you **win**, `fight()` hits `break` and returns `None` (implicit). When you **lose from attack**, it explicitly returns `False`. Inconsistent.

**Fix applied:** Changed `break` → `return True` so the win path matches the lose path's explicit return semantics.

### Bug #2: `fight()` never returns when user keeps typing invalid commands

**Location:** End of `fight()`, after the else branch (line 278–279).

```python
else:
    print("Unknown command. Type 'attack' or 'run'.")
```

If someone keeps entering invalid input during combat, the function loops forever printing errors and never returns — no explicit `return` at end of function. Technically fine since they'll eventually type something valid or die, but should have an explicit `return None` at end for safety.

**Status:** Noted as low priority — leave for next review cycle.

### Bug #3: `go()` doesn't propagate fight result — always reports success after combat

**Location:** Lines 214–219 in `go()`.

```python
enemy_name, enemy_info = find_enemy(target)
if enemy_name:
    fight(enemy_name, enemy_info)   # ← returns True/False/None, ignored!
    return False                    # ← always False here
return True                        # ← line 219 — reached after win or lose
```

When you encounter an enemy and **win**, `fight()` (now fixed to return True). But go() doesn't check fight's return value — it just continues and reaches line 219 returning True regardless. When you **lose**, same thing — go() still returns True at line 219.

This means the main loop never properly detects death from combat — it only catches it on the next iteration's `hp <= 0` check at line 325. Not a crash bug, but inconsistent UX.

**Status:** Cosmetic/inconsistent behavior — leave for next review cycle.

### Bug #4: Unnecessary blank line printed before enemy encounter in go()

**Location:** Line 213 in `go()`.

```python
print()  # blank line for readability
```

Prints an empty line right before combat starts, which is slightly confusing UX — the player sees a blank line then the enemy appears. Cosmetic only.

**Status:** Cosmetic — leave for next review cycle.

---

## Summary

| # | Severity | Bug | Location | Status |
|---|----------|-----|----------|--------|
| 1 | Medium | `fight()` returns None on win instead of True | Line 258 | ✅ Fixed |
| 2 | Low | No return after invalid input in combat loop | End of fight() | 📝 Noted |
| 3 | Low | `go()` ignores fight result, always True after combat | Lines 214–219 | 📝 Noted |
| 4 | Cosmetic | Blank line before enemy appears in go() | Line 213 | 📝 Noted |
