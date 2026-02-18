#!/usr/bin/env python3
"""
ViciDial Rocky Linux 10 — Install Script Audit
===============================================
Checks all three install scripts for known bug patterns and confirms
that all required fixes are present.

Usage:
    python3 vicidial_rocky10_audit.py
    python3 vicidial_rocky10_audit.py --dir /path/to/scripts

Exit codes:
    0 — all checks passed
    1 — one or more checks failed
"""

import re
import sys
import os
import argparse

# ── Script paths (relative to this file's directory) ────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

FILES = {
    "Part1": "vicidial_rocky10_part1_install.sh",
    "Part2": "vicidial_rocky10_part2_install.sh",
    "Part3": "vicidial_rocky10_part3_process_mgmt.sh",
}

# Exact daemon script names that must NOT appear in MAX_RUNTIME or HIGH_FREQ_SCRIPTS.
# NOTE: AST_VDauto_dial_FILL.pl is a legitimate cron script — excluded by the quotes+name.
DAEMONS = [
    r'"AST_VDauto_dial\.pl"',       # excludes _FILL variant
    r'"AST_VDremote_agents\.pl"',
    r'"AST_VDadapt\.pl"',
]


# ── Helpers ──────────────────────────────────────────────────────────────────

def extract_block(content, start_pattern, end_token=')'):
    """Extract first block matching start_pattern up to a line containing only end_token."""
    lines = content.splitlines()
    in_block, block = False, []
    for line in lines:
        if not in_block and re.search(start_pattern, line):
            in_block = True
            block = [line]
        elif in_block:
            block.append(line)
            if line.strip() == end_token:
                return '\n'.join(block)
    return ''


def is_patch_code(line):
    """
    True if the line contains ps -o "%p %a" as a search target inside the
    ps-patch step (grep -cF, Python c.replace, etc.) — not a real ps call.
    """
    s = line.strip()
    return any(k in s for k in [
        "grep -cF",        # grep searching for the old pattern
        "c.count(",        # Python counting occurrences
        "c.replace(",      # Python replacing occurrences
        "fn=open(",        # Python file open
        "fn,'r'",
        "old =",
        "new =",
        "n=c.count",
    ])


# ── Audit engine ─────────────────────────────────────────────────────────────

def audit_file(name, path):
    """
    Run all checks on one script file.
    Returns (passed: list[str], failed: list[tuple[str, list]])
    """
    with open(path) as f:
        lines = f.readlines()
    content = ''.join(lines)

    passed, failed = [], []

    def bad(label, pattern, exclude_fn=None):
        """Pattern should NOT appear (bugs)."""
        hits = []
        for i, line in enumerate(lines, 1):
            if not re.search(pattern, line):
                continue
            if line.strip().startswith('#'):
                continue
            if exclude_fn and exclude_fn(line):
                continue
            hits.append((i, line.rstrip()))
        if hits:
            failed.append((label, hits))
        else:
            passed.append(label)

    def good(label, pattern, flags=0):
        """Pattern MUST appear (required fixes)."""
        if re.search(pattern, content, flags):
            passed.append(label)
        else:
            failed.append((label, []))

    # ── Bad patterns (should be zero occurrences) ────────────────────────────

    bad(
        "((VAR++)) arithmetic under set -e  [crashes when counter=0]",
        r'\(\((?:WARNINGS|ERRORS|COUNT)\+\+\)\)',
    )

    bad(
        "pgrep | wc -l || echo pipefail bug  [gives '0\\n0' under pipefail]",
        r'pgrep.+\| wc -l \|\| echo',
    )

    bad(
        "phantom keepalive_AST_* scripts  [these scripts don't exist]",
        r'keepalive_AST_[A-Za-z]',
    )

    bad(
        'ps -o "%p %a" truncation call  [procps-ng 4.x truncates paths]',
        r'ps -o "%p %a"',
        exclude_fn=is_patch_code,
    )

    bad(
        'bare pgrep -f "$script" without perl.*  [matches SCREEN wrapper too]',
        r'''pgrep -f "\$script"''',
    )

    # Daemon scripts in MAX_RUNTIME block
    mr_block = extract_block(content, r'declare -A MAX_RUNTIME=\(')
    for pat in DAEMONS:
        if re.search(pat, mr_block):
            bad(
                f"daemon {pat} in MAX_RUNTIME  [persistent daemons have no runtime limit]",
                pat,
                exclude_fn=lambda l: 'FILL' in l,
            )

    # Daemon scripts in HIGH_FREQ_SCRIPTS block
    hf_block = extract_block(content, r'HIGH_FREQ_SCRIPTS=\(')
    for pat in DAEMONS:
        if re.search(pat, hf_block):
            bad(
                f"daemon {pat} in HIGH_FREQ_SCRIPTS  [daemons must not run via cron]",
                pat,
                exclude_fn=lambda l: 'FILL' in l,
            )

    # ── Required patterns (must be present) ──────────────────────────────────

    if name == "Part1":
        good(
            "Switch module in cpanm block  [Perl 5.40 FIX 6]",
            r'^\s+Switch\s*$',
            re.MULTILINE,
        )

    if name == "Part2":
        good("WARNINGS uses safe arithmetic  [set -e FIX]",
             r'WARNINGS=\$\(\(WARNINGS \+ 1\)\)')
        good("ERRORS uses safe arithmetic  [set -e FIX]",
             r'ERRORS=\$\(\(ERRORS \+ 1\)\)')
        good("Switch.pm Part 0a install step  [FIX 6]",
             r'PART 0a')
        good("ps-patch Part 0b step  [FIX 7]",
             r'PART 0b')
        good("pgrep uses perl\\.\\* pattern  [FIX 10]",
             r'pgrep -f "perl\.\*\$\{script\}"')
        good("WATCHED_SCRIPTS used (not CRITICAL_SCRIPTS)  [FIX 10]",
             r'WATCHED_SCRIPTS')
        good("AST_manager_kill_hung_congested in crontab  [FIX 8]",
             r'AST_manager_kill_hung_congested')
        good("AST_vm_update in crontab  [FIX 8]",
             r'AST_vm_update')
        good("KEEPALIVE pgrep uses || true (no pipefail)  [FIX 1]",
             r'pgrep.*ADMIN_keepalive.*\|\| true')

    if name == "Part3":
        good("Script version is 2.0",
             r'^# Version:\s+2\.0', re.MULTILINE)
        good("Switch.pm STEP 0 install step  [FIX 6]",
             r'STEP 0.*Switch|cpanm.*Switch')
        good("ps-patch STEP G0  [FIX 7]",
             r'STEP G0')
        good("pgrep uses perl\\.\\* pattern  [FIX 10]",
             r'pgrep -f "perl\.\*\$\{script\}"')
        good("WARNINGS uses safe arithmetic  [set -e FIX]",
             r'WARNINGS=\$\(\(WARNINGS \+ 1\)\)')
        good("ERRORS uses safe arithmetic  [set -e FIX]",
             r'ERRORS=\$\(\(ERRORS \+ 1\)\)')
        good("HIGH_FREQ_SCRIPTS block exists",
             r'HIGH_FREQ_SCRIPTS=')

    return passed, failed


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dir', default=SCRIPT_DIR,
                        help='Directory containing the install scripts (default: same dir as this script)')
    args = parser.parse_args()

    base = args.dir
    all_clean = True
    total_passed = 0
    total_failed = 0

    print()
    for name, filename in FILES.items():
        path = os.path.join(base, filename)

        if not os.path.exists(path):
            print(f"{'='*64}")
            print(f"  {name} — {filename}")
            print(f"{'='*64}")
            print(f"  ✗  FILE NOT FOUND: {path}")
            print()
            all_clean = False
            total_failed += 1
            continue

        passed, failed = audit_file(name, path)
        total_passed += len(passed)
        total_failed += len(failed)
        if failed:
            all_clean = False

        print(f"{'='*64}")
        print(f"  {name} — {filename}")
        print(f"{'='*64}")
        for label in passed:
            print(f"  ✓  {label}")
        for label, hits in failed:
            print(f"  ✗  {label}")
            for lineno, text in hits[:2]:
                print(f"       L{lineno}: {text[:100]}")
        print(f"  ─── {len(passed)} passed  /  {len(failed)} failed")
        print()

    print(f"{'='*64}")
    if all_clean:
        print(f"  ✓  ALL {total_passed} CHECKS PASSED — scripts are clean")
    else:
        print(f"  ✗  {total_failed} CHECK(S) FAILED — see above")
    print(f"{'='*64}")
    print()

    return 0 if all_clean else 1


if __name__ == '__main__':
    sys.exit(main())
