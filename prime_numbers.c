#include <stdio.h>
#include <math.h>

// Function to check if a number is prime
int isPrime(int n) {
    if (n < 2) return 0;
    if (n == 2) return 1;
    if (n % 2 == 0) return 0;
    int max = sqrt(n) + 1;
    for (int i = 3; i <= max; i += 2) {
        if (n % i == 0) return 0;
    }
    return 1;
}

int main() {
    int count = 0;
    int num = 2;
    
    printf("First 100 prime numbers:\n");
    
    while (count < 100) {
        if (isPrime(num)) {
            printf("%d ", num);
            count++;
        }
        num++;
    }
    
    printf("\n");
    return 0;
}
