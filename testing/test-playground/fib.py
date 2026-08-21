"""Inline autocomplete (FIM) test file.

Put your cursor at each TODO marker and wait for ghost-text.
Accept with Tab, reject with Escape, cycle alternatives with Alt+] / Alt+[.
"""


def fibonacci(n: int) -> int:
    """Return the nth Fibonacci number using iteration.

    Runs in O(n) time and O(1) space.
    Raises ValueError if n is negative.
    """
    # TODO: place your cursor at the end of this line and let Continue fill in the body
    if n < 0:
        raise ValueError("n must be a non-negative integer")
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a    




def fibonacci_memo(n: int, cache: dict[int, int] | None = None) -> int:
    """Return the nth Fibonacci number using recursion with memoization.

    First call uses a fresh cache; recursive calls reuse it.
    """
    if cache is None:
        cache = {}

    # Base cases
    if n < 0:
        raise ValueError("n must be a non-negative integer")
    if n == 0:
        return 0
    if n == 1:
        return 1

    # Check cache first
    if n in cache:
        return cache[n]

    # Recursive calculation with memoization
    result = fibonacci_memo(n - 1, cache) + fibonacci_memo(n - 2, cache)
    cache[n] = result
    return result


def is_prime(n: int) -> bool:
    """Return True if n is prime, False otherwise.

    Uses trial division up to sqrt(n). Handles n < 2 correctly.
    """
    if n < 2:
        return False
    if n == 2:
        return True
    if n % 2 == 0:
        return False

    # Check odd divisors up to sqrt(n)
    i = 3
    while i * i <= n:
        if n % i == 0:
            return False
        i += 2
    return True

def primes_up_to(n: int) -> list[int]:
    """Return every prime number <= n, in ascending order.

    Uses the Sieve of Eratosthenes for O(n log log n) performance.
    """
    if n < 2:
        return []

    # Initialize sieve - True means "is prime" initially
    sieve = [True] * (n + 1)
    sieve[0] = sieve[1] = False

    # Sieve of Eratosthenes
    p = 2
    while p * p <= n:
        if sieve[p]:
            # Mark multiples of p as not prime
            for i in range(p * p, n + 1, p):
                sieve[i] = False
        p += 1

    # Collect all primes
    return [i for i, is_prime in enumerate(sieve) if is_prime]

def every_other_prime(n: int) -> list[int]:
    """Return every other prime number <= n, in ascending order.

    Uses the Sieve of Eratosthenes and then filters to every other prime.
    """
    primes = primes_up_to(n)
    return primes[::2]  # Return every other prime

if __name__ == "__main__":
    # Quick sanity check once you've accepted the completions above:
    print("fib(10)      =", fibonacci(10))          # expect 55
    print("fib_memo(30) =", fibonacci_memo(30))     # expect 832040
    print("is_prime(97) =", is_prime(97))           # expect True
    print("primes<=30   =", primes_up_to(30))       # expect [2,3,5,7,11,13,17,19,23,29]
    print("every_other_prime(30) =", every_other_prime(30))  # expect [2,5,11,17,23]

    
