#!/usr/bin/env python3
"""Build the submission PDF from report/report.md with a LaTeX (Latin Modern) look.

The Markdown source stays the single source of truth. This script only applies
presentation transforms before calling pandoc + xelatex:
  * the first H1 and the line after it become the title and subtitle;
  * "![Figure N](path)" followed by an italic "*Figure N. caption*" paragraph
    becomes one LaTeX figure whose caption is the italic text (no duplicate label);
  * any leftover ```latex fenced block is rendered as display math.

Usage (from anywhere):  python3 report/build/build_pdf.py [output.pdf]
Requires: pandoc >= 3, xelatex with unicode-math, newunicodechar, fvextra, xurl.
"""
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPORT_DIR = HERE.parent
SRC = REPORT_DIR / "report.md"


def transform(md: str) -> str:
    lines = md.split("\n")
    if not lines[0].startswith("# "):
        raise ValueError("report.md must start with an H1 title line")
    title = lines[0][2:].strip()
    subtitle = lines[2].strip() if lines[1].strip() == "" else lines[1].strip()
    body = "\n".join(lines[1:]).replace(subtitle, "", 1).lstrip("\n")

    # Merge image + italic caption paragraph into a single captioned figure.
    fig = re.compile(r"!\[(Figure \d+)\]\(([^)]+)\)\n\n\*(Figure \d+)\.\s+(.*?)\*\n", re.S)

    def merge(m):
        if m.group(1) != m.group(3):
            raise ValueError(f"figure label mismatch: {m.group(1)} vs {m.group(3)}")
        return f"![**{m.group(3)}.** *{m.group(4)}*]({m.group(2)})\n"

    body, nfig = fig.subn(merge, body)
    leftover = re.findall(r"!\[Figure \d+\]", body)
    if leftover:
        raise ValueError(f"figures without a following caption paragraph: {leftover}")

    body = re.sub(r"```latex\n(.*?)\n```", r"$$\n\1\n$$", body, flags=re.S)

    esc = lambda s: s.replace('"', '\\"')
    yaml = f'---\ntitle: "{esc(title)}"\nsubtitle: "{esc(subtitle)}"\n---\n\n'
    print(f"merged {nfig} figures with their captions", file=sys.stderr)
    return yaml + body


def main():
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else REPORT_DIR / "SPH5105_Assessment_4_report.pdf"
    tmp = REPORT_DIR / ".build_report.md"  # same directory so ../results paths resolve
    tmp.write_text(transform(SRC.read_text()))
    cmd = [
        "pandoc", tmp.name, "--from", "markdown", "--pdf-engine=xelatex",
        f"--include-in-header={HERE / 'header.tex'}",
        "-V", "documentclass=article", "-V", "papersize=a4", "-V", "fontsize=11pt",
        "-V", "geometry:margin=2.3cm", "-V", "colorlinks=true",
        "-V", "linkcolor=black", "-V", "urlcolor=blue", "-V", "citecolor=black",
        "-o", str(out),
    ]
    try:
        res = subprocess.run(cmd, cwd=REPORT_DIR, capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    missing = [l for l in res.stderr.splitlines() if "Missing character" in l]
    if res.returncode != 0:
        sys.exit(f"pandoc failed:\n{res.stderr}")
    if missing:
        sys.exit("glyphs missing from the fonts (add a newunicodechar mapping):\n" + "\n".join(missing))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
