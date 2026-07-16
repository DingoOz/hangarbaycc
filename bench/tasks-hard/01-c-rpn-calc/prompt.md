Write a complete C program that evaluates a Reverse Polish Notation (postfix)
expression given as command-line arguments — one token per argument — and
prints the result as an integer followed by a newline.

Rules:
- Operators: `+` `-` `*` `/` (binary). Arithmetic on `long long`.
- Division truncates toward zero (C semantics: `-7 2 /` is `-3`).
- Numeric tokens may be negative, e.g. `-7`. A lone `-` is the operator.
- Error handling — print exactly the message below to stdout and exit with
  status 1:
  - an operator finds fewer than 2 values on the stack: `error: stack underflow`
  - division by zero: `error: division by zero`
  - a token that is neither a number nor an operator: `error: bad token 'X'`
    where X is the offending token
  - after all tokens, the stack does not hold exactly one value (this includes
    no arguments at all): `error: leftover operands`

Examples:
- args `3 4 + 2 *` -> prints `14`
- args `4 0 /` -> prints `error: division by zero`, exit status 1
- args `2 x *` -> prints `error: bad token 'x'`, exit status 1
