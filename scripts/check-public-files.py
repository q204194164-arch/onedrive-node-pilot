#!/usr/bin/env python3
"""Review only tracked/staged publishable files; never print matched secret values."""
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
allowed = {
    ".gitignore", "README.md", "LICENSE", "PRIVACY.md", "CONTRIBUTING.md", "SECURITY.md", "build.sh",
    "Sources/App.swift", "Sources/Engine.swift", "Sources/LaunchWatcher.swift",
    "Tests/EngineTests.swift", "Tests/ProbeCLI.swift", "Tests/IsolationCLI.swift",
    "docs/images/app.png",
    "scripts/test.sh", "scripts/check-public-files.py", ".github/workflows/ci.yml",
}
files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
patterns = {
    "personal home path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "GitHub credential": re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    "credential URL": re.compile(r"https?://[^/\s]+:[^/@\s]+@"),
    "subscription credential": re.compile(r"[?&](?:token|key|password|secret)=[A-Za-z0-9_%+/-]{8,}", re.I),
    "JWT": re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
}
failures = []
for name in filter(None, files):
    if name not in allowed:
        failures.append(f"{name}: outside public allowlist")
        continue
    if name == "docs/images/app.png":
        if not (root / name).read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            failures.append(f"{name}: expected PNG screenshot")
        continue  # Screenshot content must also be reviewed visually before publication.
    content = (root / name).read_text(encoding="utf-8")
    for label, pattern in patterns.items():
        if pattern.search(content):
            failures.append(f"{name}: {label}")
if failures:
    raise SystemExit("Public-file check failed:\n" + "\n".join(failures))
print(f"Public-file check passed ({len(list(filter(None, files)))} tracked files). Review the diff manually too.")
