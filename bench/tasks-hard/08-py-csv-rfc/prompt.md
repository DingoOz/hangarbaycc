Write a complete Python 3 program that reads ONE line of RFC-4180-style CSV
from stdin and prints each field on its own line. Do not use the `csv`
module — parse it yourself.

Rules:
- Fields are separated by commas.
- A field may be enclosed in double quotes. Inside a quoted field, commas are
  literal, and a doubled quote `""` is a literal `"` character.
- Print fields without their surrounding quotes and with `""` collapsed to `"`.
- Empty fields are allowed (including a trailing empty field after a final
  comma) and print as empty lines.

Example: input `a,"b""c",,"d,e",` -> output is five lines:
```
a
b"c

d,e

```
(the 3rd and 5th lines are empty).
