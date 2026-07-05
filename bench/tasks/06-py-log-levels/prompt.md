Write a complete Python 3 program that reads log lines from stdin. Each line
has the form `LEVEL: message` (a level name, a colon, a space, then text).
Count how many lines there are of each level, then print one line per level in
the format `LEVEL=count`, sorted alphabetically by level name. Ignore lines
that do not match the format.

Example input:
```
INFO: started
ERROR: bad thing
INFO: still going
WARN: look out
ERROR: worse thing
```
Expected output:
```
ERROR=2
INFO=2
WARN=1
```
