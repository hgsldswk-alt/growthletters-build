"""Copy named xcresult attachments into the paths used by the listing tools."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

LANGS = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-write", "02-letters", "03-read", "04-book", "05-import", "06-reminder")
PAID = "paid-01-paywall"
EXPECTED = {f"store-{language}-{scene}" for language in LANGS for scene in SCENES} | {PAID}
SHOT = re.compile(r"^(store-(?:zh-Hans|zh-Hant|en)-\d{2}-[a-z-]+|paid-01-paywall)(?=[_.]|$)")


def export_names(source, output, review=None):
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    found = {}
    for test in manifest:
        for item in test["attachments"]:
            match = SHOT.match(item.get("suggestedHumanReadableName", ""))
            if not match or match[1] not in EXPECTED:
                continue
            file = item["exportedFileName"]
            if Path(file).name != file or Path(file).suffix.lower() != ".png":
                raise ValueError(f"Invalid screenshot attachment: {file}")
            if match[1] in found:
                raise ValueError(f"Duplicate screenshot attachment: {match[1]}")
            found[match[1]] = source / file

    missing = EXPECTED - found.keys()
    if missing:
        raise ValueError("Missing screenshots: " + ", ".join(sorted(missing)))
    for name, path in found.items():
        with path.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                raise ValueError(f"Invalid PNG screenshot: {name}")
    output.mkdir(parents=True, exist_ok=True)
    for name, path in found.items():
        shutil.copy2(path, output / f"{name}.png")
    if review:
        review.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(found[PAID], review)
    return len(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcresult", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--review-destination", type=Path)
    args = parser.parse_args()
    args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.resolve().parent) as temporary:
        source = Path(temporary)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.xcresult),
                        "--output-path", str(source)], check=True)
        count = export_names(source, args.output, args.review_destination)
    print(f"Exported {count} screenshots to {args.output}")


if __name__ == "__main__":
    main()
