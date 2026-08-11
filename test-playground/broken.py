"""Bug-fix workflow test file.

Run: python broken.py
Expected: it crashes. Ask Continue chat to diagnose + fix.

The bug is subtle enough that a shallow fix will leave one of the sample inputs
still failing. A good response identifies the root cause, not just a symptom.
"""
from collections import defaultdict


def word_frequencies(text: str) -> dict[str, int]:
    """Count how often each lowercased word appears in `text`.

    Punctuation should be stripped. Empty strings and whitespace-only input
    should return an empty dict.
    """
    counts = defaultdict(int)
    for word in text.split(" "):
        clean = word.lower().strip(".,!?;:")
        counts[clean] += 1
    return counts


def top_n_words(text: str, n: int) -> list[tuple[str, int]]:
    """Return the top-n most common words as (word, count) pairs, descending by count."""
    freqs = word_frequencies(text)
    ranked = sorted(freqs.items(), key=lambda kv: kv[1], reverse=True)
    return ranked[:n]


if __name__ == "__main__":
    samples = [
        "The quick brown fox jumps over the lazy dog. The dog barks!",
        "one\ntwo\ntwo\nthree\nthree\nthree",
        "   ",
        "",
    ]
    for s in samples:
        print(repr(s), "->", top_n_words(s, 2))
