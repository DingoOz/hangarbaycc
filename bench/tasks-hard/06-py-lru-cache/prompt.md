Write a complete Python 3 program defining a class `LRUCache` with:

- `LRUCache(capacity)` — a fixed-capacity key-value cache.
- `get(key)` — return the value, or `-1` if absent. A successful get makes
  the key the most recently used.
- `put(key, value)` — insert or update. Both insert and update make the key
  the most recently used. When inserting into a full cache, evict the least
  recently used key first.

The program's main block must run exactly this and nothing else:

```python
c = LRUCache(2)
c.put(1, 1)
c.put(2, 2)
print(c.get(1))
c.put(3, 3)
print(c.get(2))
c.put(4, 4)
print(c.get(1))
print(c.get(3))
print(c.get(4))
c.put(3, 30)
print(c.get(3))
```

Expected output:
```
1
-1
-1
3
4
30
```
