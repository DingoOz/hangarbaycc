Write a complete C program that reads ONE line of CSV from stdin and prints
each field on its own line.

Rules:
- Fields are separated by commas.
- A field may be enclosed in double quotes; a quoted field may contain commas,
  which are then part of the field, not separators.
- Print fields without their surrounding quotes.
- You may assume quotes are never escaped inside a quoted field, and the line
  is at most 1000 characters.

Example: input `a,"b,c",d` -> output is three lines: `a` then `b,c` then `d`.
