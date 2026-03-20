#!/usr/bin/env python3
"""Parse lemma agent output into human-readable format.

Lemma outputs plain text logs (not JSON stream like claude --print),
so this is mostly a pass-through with minor cleanup.
"""
import sys
import argparse


def parse_lemma_output(input_path: str, output_path: str):
    with open(input_path, "r", errors="replace") as f:
        raw = f.read()

    # Strip ANSI escape codes
    import re
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    cleaned = ansi_escape.sub('', raw)

    with open(output_path, "w") as f:
        f.write(cleaned)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", help="Path to solve_out.txt")
    parser.add_argument("-o", "--output", required=True, help="Output path")
    args = parser.parse_args()

    parse_lemma_output(args.input, args.output)


if __name__ == "__main__":
    main()
