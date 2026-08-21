# Chat-panel test prompts

Paste each into Continue's chat panel one at a time. `Cmd+L` opens the panel; highlight code first and `Cmd+L` again to include it as context.

---

## 1. Explain code (uses `fib.py` as context)

> Highlight all of `fib.py`, then send this prompt:

Explain what each function is supposed to do and how you'd test them. Give me one representative pytest test per function.

**Judge:** does it distinguish the four functions' behavior, or does it lump them together? Are the tests actually meaningful?

---

## 2. Refactor with a constraint

> Highlight `word_frequencies` in `broken.py`, then send:

Rewrite this function to use `collections.Counter` and to also strip apostrophes, without changing the return type or the empty-input behavior. Do not change anything about `top_n_words`.

**Judge:** did it honor "return type unchanged" (dict, not Counter)? Did it leave `top_n_words` alone?

---

## 3. Design a small module

Design a Python module `rate_limiter.py` that implements a token-bucket rate limiter.

Requirements:
- Class `TokenBucket(capacity: int, refill_rate: float)` where `refill_rate` is tokens per second.
- Method `try_acquire(tokens: int = 1) -> bool` — non-blocking, returns True/False.
- Method `acquire(tokens: int = 1) -> None` — blocks until tokens are available.
- Thread-safe (multiple threads calling concurrently).
- One usage example at the bottom demonstrating both methods.

Don't use any external libraries. Include type hints.

**Judge:** correctness of the refill math, actual thread safety (needs a Lock), sensible docstrings, no gratuitous features.

---

## 4. Diagnose bad code

Someone wrote this to detect palindromes:

```python
def is_palindrome(s: str) -> bool:
    for i in range(len(s)):
        if s[i] != s[-i]:
            return False
    return True
```

Find every bug and explain each one. Give me a corrected version.

**Judge:** it should catch (a) `s[-i]` is wrong when i=0 (should be `s[-(i+1)]` or use reversed comparison), (b) no case-insensitivity handling if that's expected, (c) iterating past the midpoint doubles work. A good answer names all three.

---

## 5. Tool use / multi-step agentic (if using Continue's agent mode)

Only run this if you're testing tool calling. Otherwise skip — regular chat won't have file-system access.

> In Continue's agent mode:

Look at `broken.py`, figure out why it crashes on the third and fourth sample inputs, and write a fixed version to `broken_fixed.py` in the same directory. Then run `python broken_fixed.py` and confirm all four samples produce output.

**Judge:** does the model actually call read_file / write_file / run_command tools, or does it just describe what to do? Does the fix actually work when run?
