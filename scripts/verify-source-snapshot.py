import hashlib
import json
import pathlib


def verify(root):
    root = root.resolve()
    manifest = json.loads((root / "SOURCE-SNAPSHOT.json").read_text(encoding="utf-8"))
    if manifest.get("format") != 1 or manifest.get("contains_git_history") is not False:
        raise ValueError("Invalid snapshot declaration")
    seen = set()
    for record in manifest["files"]:
        relative = pathlib.PurePosixPath(record["path"])
        if relative.is_absolute() or ".." in relative.parts or relative.as_posix() in seen:
            raise ValueError("Unsafe or duplicate snapshot path")
        seen.add(relative.as_posix())
        candidate = root.joinpath(*relative.parts)
        if candidate.is_symlink() or not candidate.resolve().is_relative_to(root) or not candidate.is_file():
            raise ValueError("Snapshot path missing or unsafe: " + relative.as_posix())
        data = candidate.read_bytes()
        if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError("Snapshot content mismatch: " + relative.as_posix())
    for directory in ("App", "AppTests", "Core/Sources", "Core/Tests", "UITests", "Examples", "scripts", ".github"):
        for candidate in (root / directory).rglob("*"):
            relative = candidate.relative_to(root)
            if candidate.is_symlink():
                raise ValueError("Unexpected symlink: " + relative.as_posix())
            if "__pycache__" in relative.parts and directory == "scripts":
                continue
            if candidate.is_file() and relative.as_posix() not in seen:
                raise ValueError("Unreviewed extra build input: " + relative.as_posix())
    return len(seen)


if __name__ == "__main__":
    try:
        print("Verified source-only snapshot:", verify(pathlib.Path(__file__).resolve().parents[1]), "files")
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(str(error))


