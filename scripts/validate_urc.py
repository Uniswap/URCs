#!/usr/bin/env python3
"""Validate URC markdown files for correct preamble and required sections."""

import re
import sys
import os


REQUIRED_PREAMBLE_FIELDS = ["urc", "title", "author", "status", "created"]
VALID_STATUSES = ["Draft", "Discussion", "Last Call", "Final", "Superseded", "Withdrawn"]
REQUIRED_SECTIONS = ["Abstract", "Specification", "Rationale", "Security Considerations", "Copyright"]


def parse_preamble(content):
    """Extract YAML preamble from markdown content. Returns dict or None."""
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if not match:
        return None
    preamble = {}
    for line in match.group(1).strip().split("\n"):
        if ":" in line:
            key, _, value = line.partition(":")
            preamble[key.strip()] = value.strip()
    return preamble


def validate_preamble(preamble):
    """Check required fields and valid status. Returns list of error strings."""
    errors = []
    if preamble is None:
        return ["No valid YAML preamble found. Expected --- delimited frontmatter."]
    for field in REQUIRED_PREAMBLE_FIELDS:
        if field not in preamble or not preamble[field]:
            errors.append(f"Missing required preamble field: {field}")
    if "status" in preamble and preamble["status"] not in VALID_STATUSES:
        errors.append(
            f"Invalid status: '{preamble['status']}'. "
            f"Must be one of: {', '.join(VALID_STATUSES)}"
        )
    return errors


def validate_sections(content):
    """Check that all required section headings exist. Returns list of error strings."""
    errors = []
    headings = [h.strip() for h in re.findall(r"^##\s+(.+)$", content, re.MULTILINE)]
    for section in REQUIRED_SECTIONS:
        if section not in headings:
            errors.append(f"Missing required section: {section}")
    return errors


def validate_filename(filepath, preamble):
    """Check filename matches urc-N.md and N matches preamble. Returns list of error strings."""
    errors = []
    basename = os.path.basename(filepath)
    match = re.match(r"^urc-(\d+)\.md$", basename)
    if not match:
        errors.append(f"Invalid filename format: '{basename}'. Expected 'urc-N.md'.")
        return errors
    file_number = match.group(1)
    if preamble and "urc" in preamble and str(preamble["urc"]) != file_number:
        errors.append(
            f"Filename number ({file_number}) does not match preamble urc field ({preamble['urc']})"
        )
    return errors


def validate_file(filepath):
    """Run all validations on a single URC file. Returns list of error strings."""
    try:
        with open(filepath, "r") as f:
            content = f.read()
    except OSError as e:
        return [f"Could not read file: {e}"]
    preamble = parse_preamble(content)
    errors = []
    errors.extend(validate_preamble(preamble))
    errors.extend(validate_sections(content))
    errors.extend(validate_filename(filepath, preamble))
    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: validate_urc.py <file> [file ...]", file=sys.stderr)
        sys.exit(1)
    all_errors = []
    for filepath in sys.argv[1:]:
        errors = validate_file(filepath)
        for error in errors:
            all_errors.append(f"{filepath}: {error}")
    if all_errors:
        for error in all_errors:
            print(error, file=sys.stderr)
        sys.exit(1)
    print("All URCs valid.")
    sys.exit(0)


if __name__ == "__main__":
    main()
