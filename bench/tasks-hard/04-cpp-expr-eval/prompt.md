Write a complete C++ program (C++17) that reads one arithmetic expression per
line from stdin until EOF, evaluates each on `long long`, and prints each
result on its own line.

Expression grammar:
- Integer literals, parentheses, binary operators `+` `-` `*` `/` `%`, and
  unary minus.
- Usual precedence: `*` `/` `%` bind tighter than `+` `-`; operators of equal
  precedence associate left; unary minus binds tighter than `*` `/` `%`
  (so `-(3+4)%5` is `(-(3+4)) % 5`).
- `/` and `%` use C semantics: division truncates toward zero and the result
  of `%` has the sign of the dividend (`-7/2` is `-3`, `-7%5` is `-2`).
- Tokens may be separated by arbitrary spaces (or none).
- Every input line is a valid expression; no division or modulo by zero.

Examples:
- `2+3*4` -> `14`
- `(2+3)*-4` -> `-20`
- `7--3` -> `10`
