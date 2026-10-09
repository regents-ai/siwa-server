"""Embed the shared local Touch ID page in both standalone clients and Regents CLI."""

import argparse
import base64
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--design-system", type=Path, required=True)
    parser.add_argument("--cli", type=Path, help="Regents CLI checkout to update")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    design = args.design_system

    def data_url(path, mime):
        return "data:" + mime + ";base64," + base64.b64encode(path.read_bytes()).decode()

    tokens = (design / "design_system_tokens.css").read_text()
    # Only the three regular fonts used by this page travel with each client.
    fonts = {"GeistPixel-Square.woff2", "Geist-Regular.woff2", "GeistMono-Regular.woff2"}

    def font_face(match):
        face = match.group()
        name = re.search(r'/fonts/regent-ui/([^"\)]+)', face).group(1)
        if name not in fonts:
            return ""
        return face.replace(
            "/fonts/regent-ui/" + name,
            data_url(design / "regent_ui/priv/static/fonts" / name, "font/woff2"),
        )

    tokens = re.sub(r"@font-face\s*\{[^}]+\}", font_face, tokens)
    page = (design / "standalone/agent-key.html").read_text().replace("__TOKENS__", tokens)
    for mode in ("dark", "light"):
        page = page.replace(
            "__MARK_" + mode.upper() + "__",
            data_url(design / "logos" / f"regents-crown-flat-{mode}.svg", "image/svg+xml"),
        )
    license_text = "\n".join(
        line.rstrip() for line in (design / "geist-font/OFL.txt").read_text().splitlines()
    )
    page = page.replace("<head>", "<head>\n<!-- Bundled fonts:\n" + license_text + "\n-->")
    page = page.replace("__CLIENT_SCRIPT__", (root / "assets/agent/passkey.js").read_text())
    # These are literal string bodies in the standalone clients, not evaluated templates.
    if any(value in page for value in ('"""', "`", "${", "\\")):
        raise ValueError("Page contains characters that need escaping in a client literal")
    outputs = {}
    for filename, prefix, suffix in (
        ("siwa_agent.py", 'PASSKEY_PAGE = """', '"""'),
        ("siwa-agent.mjs", 'const PASSKEY_PAGE = `', '`;'),
    ):
        path = root / "priv/static/agent" / filename
        source = path.read_text()
        start = source.index(prefix) + len(prefix)
        end = source.index(suffix, start)
        outputs[path] = source[:start] + page + source[end:]
    if args.cli:
        outputs[args.cli / "src/regents_cli/passkey.html"] = page
    for path, content in outputs.items():
        if args.check:
            if path.read_text() != content:
                raise SystemExit(f"Stale generated page: {path}")
        else:
            path.write_text(content)
        print(f"{'Checked' if args.check else 'Updated'} {path}")


if __name__ == "__main__":
    main()
