Write a complete Python 3 program defining a class `RingBuffer` with:

- `RingBuffer(capacity)` — a fixed-capacity buffer.
- `append(x)` — add an item; when the buffer is full, overwrite the oldest.
- `to_list()` — return the items as a list, oldest first.
- `__len__` — the number of items currently stored.

The program's main block must run exactly this and nothing else:

```python
rb = RingBuffer(3)
for i in range(1, 6):
    rb.append(i)
print(rb.to_list())
print(len(rb))
rb2 = RingBuffer(2)
rb2.append("a")
print(rb2.to_list())
print(len(rb2))
```

Expected output:
```
[3, 4, 5]
3
['a']
1
```
