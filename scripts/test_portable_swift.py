#!/usr/bin/env python3
"""Run the actual Foundation-only Swift/XCTest suites on macOS or Linux.

This compiles production helper files directly, without application stubs or
model dependencies. It does not build or test the macOS app, AppKit, or AX.
Requires a Swift 6.2 toolchain with XCTest; pass --swiftc if it is not on PATH.
Only the test module import is removed from temporary copies of the suites.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "SmartInsertionTests": "Sources/Voice/Utils/SmartInsertion.swift",
    "PasteReadbackTests": "Sources/Voice/Utils/PasteReadback.swift",
    "CorrectionEvidenceTests": "Sources/Voice/Services/CorrectionEvidence.swift",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc", help="Swift compiler path (default: swiftc on PATH)")
    parser.add_argument("--suite", action="append", choices=SUITES, help="Select one suite; repeat to select several")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc)
    if compiler is None:
        parser.error("Swift compiler not found. Install Swift 6.2 and/or pass --swiftc /path/to/swiftc.")
    suites = args.suite or list(SUITES)

    with tempfile.TemporaryDirectory(prefix="flow-portable-swift-") as temp:
        directory = Path(temp)
        inputs: list[str] = []
        entries: list[str] = []
        test_count = 0
        for suite in dict.fromkeys(suites):
            source = ROOT / SUITES[suite]
            test = ROOT / "Tests/VoiceTests" / f"{suite}.swift"
            if not source.is_file() or not test.is_file():
                parser.error(f"Missing source or test for {suite}; run from a complete Flow checkout.")
            text = test.read_text(encoding="utf-8")
            imports = re.findall(r"^import (\w+)\s*$", text, re.MULTILINE)
            if set(imports) - {"Foundation", "XCTest"}:
                parser.error(f"{suite} is not a Foundation-only XCTest suite.")
            # Do not rewrite the tests or replace application dependencies.
            if text.count("@testable import Voice") != 1:
                parser.error(f"{suite} must have exactly one Voice module import.")
            text = text.replace("@testable import Voice", "")
            names = re.findall(r"^    func (test\w+)\(\)(?: throws)?\s*\{", text, re.MULTILINE)
            declarations = re.findall(r"\bfunc (test\w+)\s*\(", text)
            if not names or names != declarations:
                parser.error(f"{suite} has unsupported test signatures; update the portable runner explicitly.")
            copied = directory / test.name
            copied.write_text(text, encoding="utf-8")
            inputs.extend((str(source), str(copied)))
            entries.append("testCase([" + ",\n".join(f'("{name}", {suite}.{name})' for name in names) + "])")
            test_count += len(names)

        runner = directory / "main.swift"
        runner.write_text("import XCTest\nXCTMain([" + ",\n".join(entries) + "])\n", encoding="utf-8")
        executable = directory / "portable-tests"
        print(f"Compiling {test_count} tests from {len(entries)} Foundation-only suites; macOS app integration is not exercised.", flush=True)
        build = subprocess.run([compiler, "-swift-version", "5", *inputs, str(runner), "-o", str(executable)], check=False)
        if build.returncode:
            return build.returncode
        return subprocess.run([str(executable)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
