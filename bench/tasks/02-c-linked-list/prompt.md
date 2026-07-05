Write a complete C program that:

1. Builds a singly linked list holding the integers 1 through 9 in order,
   with each node allocated by `malloc`.
2. Removes every node holding an even value.
3. Prints the remaining values in order on one line, separated by single
   spaces, followed by a newline (expected output: `1 3 5 7 9`).
4. Frees every remaining node before exiting.

Do not use an array to fake the list — actually link nodes with pointers.
