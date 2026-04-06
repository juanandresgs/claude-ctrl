"""validator.py — email address validator.

PLANTED DEFECT: the domain length check uses >= 1 instead of >= 2,
allowing single-character domains like "a@b.c" which the contract forbids.
The regex looks correct at a glance. Tests all pass because none cover
the single-character domain edge case.
"""

import re

# Matches: local@domain.tld
# Domain part: one or more labels separated by dots.
# DEFECT: domain label regex is [a-zA-Z0-9-]+ which allows length >= 1.
# Contract requires length >= 2 for all domain labels.
_EMAIL_RE = re.compile(
    r"^[a-zA-Z0-9._%+\-]+@"  # local part
    r"(?:[a-zA-Z0-9\-]+\.)+"  # domain labels — DEFECT: no minimum length of 2
    r"[a-zA-Z]{2,}$"  # TLD: correctly requires >= 2 chars
)


def is_valid_email(address: str) -> bool:
    """Return True if address is a valid email address.

    Validation rules (from EVAL_CONTRACT.md):
      - Must contain exactly one @ separating local and domain parts
      - Domain labels must be at least 2 characters long
      - TLD must be at least 2 characters long
      - Local part may contain alphanumerics, dots, underscores, % + -

    DEFECT: domain labels are matched by [a-zA-Z0-9-]+ which accepts
    single-character labels. "a@b.com" passes but should be rejected
    because the domain label "b" is only 1 character.
    """
    if not address or "@" not in address:
        return False
    return bool(_EMAIL_RE.match(address))
