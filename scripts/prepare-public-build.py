import argparse
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIRECTORIES = ("App", "AppTests", "Core/Sources", "Core/Tests", "UITests", "Examples", "scripts")
FILES = (".gitattributes", ".gitignore", ".github/workflows/build-ios.yml", "Core/Package.swift", "project.yml", "LICENSE", "THIRD_PARTY.md", "SECURITY.md", "PUBLIC-BUILD-README.md")
EXTENSIONS = {".swift", ".json", ".png", ".plist", ".entitlements", ".py", ".sh", ".txt"}
PATTERNS = {
    "credential": re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "personal-path": re.compile(r"[A-Za-z]:[\\/](?:Users|五视图|新建文件夹)[\\/]|/" + r"Users/[^/\s]+/"),
    "credential-url": re.compile(r"https?://[^/\s:@]+:[^/\s@]+@"),
}


def source_files():
    selected = {ROOT / relative for relative in FILES}
    for directory in DIRECTORIES:
        for candidate in (ROOT / directory).rglob("*"):
            relative = candidate.relative_to(ROOT)
            if candidate.is_file() and candidate.suffix in EXTENSIONS and not any(part in {".build", "build", "__pycache__", ".git"} for part in relative.parts):
                selected.add(candidate)
    for candidate in sorted(selected):
        if candidate.is_symlink() or not candidate.resolve().is_relative_to(ROOT):
            raise SystemExit("Source symlink or path escape rejected")
        if not candidate.is_file():
            raise SystemExit("Missing source: " + str(candidate.relative_to(ROOT)))
    return sorted(selected)


def scan(files):
    findings = []
    for candidate in files:
        if candidate.suffix == ".png":
            continue
        contents = candidate.read_text(encoding="utf-8")
        for category, pattern in PATTERNS.items():
            for match in pattern.finditer(contents):
                if category == "credential-url" and candidate.relative_to(ROOT).as_posix() == "Core/Tests/ComfyCoreTests/ComfyCoreTests.swift" and match.group(0) == "https://" + "user:password@":
                    continue
                findings.append({"path": candidate.relative_to(ROOT).as_posix(), "line": contents.count("\n", 0, match.start()) + 1, "category": category})
    return findings


def main():
    parser = argparse.ArgumentParser(description="Prepare a reviewed, history-free source snapshot. Does not create a repository, commit, push, or run Actions.")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    target = args.output.resolve()
    if target == ROOT or target.is_relative_to(ROOT) or ROOT.is_relative_to(target):
        raise SystemExit("Use a new, separate snapshot directory")
    if target.exists() and (not target.is_dir() or any(target.iterdir())):
        raise SystemExit("Output must be absent or an empty directory; nothing was overwritten")
    selected = source_files()
    findings = scan(selected)
    if findings:
        print(json.dumps({"status": "blocked", "findings": findings}, ensure_ascii=False, indent=2))
        raise SystemExit(1)
    target.mkdir(parents=True, exist_ok=True)
    for candidate in selected:
        destination = target / candidate.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        data = candidate.read_bytes()
        destination.write_bytes(data if candidate.suffix == ".png" else data.replace(b"\r\n", b"\n"))
    (target / "README.md").write_bytes((ROOT / "PUBLIC-BUILD-README.md").read_bytes().replace(b"\r\n", b"\n"))
    records = [{"path": candidate.relative_to(target).as_posix(), "bytes": candidate.stat().st_size, "sha256": hashlib.sha256(candidate.read_bytes()).hexdigest()} for candidate in sorted(target.rglob("*")) if candidate.is_file()]
    manifest = {"format": 1, "purpose": "reviewed-source-only-build-snapshot", "contains_git_history": False, "checks": "common credential and personal-path patterns; manual review still required", "files": records}
    (target / "SOURCE-SNAPSHOT.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "prepared-not-published", "files": len(records), "output": str(target)}, ensure_ascii=False))


if __name__ == "__main__":
    main()

