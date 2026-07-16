The following C program is intended to make heap-allocated copies of four
words and print the copies in reverse order, one per line — expected output:

```
delta
gamma
beta
alpha
```

It compiles, but it contains memory bugs and does not behave correctly.

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    const char *words[] = {"alpha", "beta", "gamma", "delta"};
    int n = 4;
    char *copies[4];
    for (int i = 0; i < n; i++) {
        copies[i] = malloc(strlen(words[i]));
        strcpy(copies[i], words[i]);
    }
    for (int i = n; i >= 0; i--) {
        printf("%s\n", copies[i]);
    }
    for (int i = 0; i < n; i++) {
        free(copies[i]);
    }
    return 0;
}
```

Fix all the bugs. Keep the program's structure, variable names, and output
format unchanged — make the smallest changes that make it correct. The fixed
program must run cleanly under AddressSanitizer and UndefinedBehaviorSanitizer
and produce exactly the expected output above.
