"""Builds the plugin into a single model file, with no Roblox toolchain installed.

The source tree is read the way a sync tool reads it: the entry point becomes
the root script, a directory becomes a module with its siblings as children,
and every other source file becomes a module of its own.

Run it with no argument to write into the local Studio plugins folder, or pass
a path to write elsewhere. A real toolchain is the better answer once the
project needs one; this exists so a teammate can build without installing any.
"""

import hashlib
import os
import sys
from pathlib import Path
from xml.sax.saxutils import escape

SOURCE_DIR = Path(__file__).parent / "src"
ENTRY = "init.server.luau"
MODULE_ENTRY = "init.luau"
PLUGIN_NAME = "StudioActivityLogger"


class Referent:
    """Hands out the unique ids the model format requires."""

    def __init__(self):
        self.next = 0

    def take(self) -> str:
        self.next += 1
        return f"RBX{self.next}"


def default_output() -> Path:
    """Names the file to write when the caller names none."""
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "Roblox" / "Plugins" / f"{PLUGIN_NAME}.rbxmx"
    return Path.home() / "Documents" / "Roblox" / "Plugins" / f"{PLUGIN_NAME}.rbxmx"


def item(class_name: str, name: str, source: str, referent: str, children: str = "") -> str:
    """Renders one instance, and whatever it contains, in the model format."""
    return (
        f'<Item class="{class_name}" referent="{referent}">'
        "<Properties>"
        f'<string name="Name">{escape(name)}</string>'
        f'<ProtectedString name="Source">{escape(source)}</ProtectedString>'
        "</Properties>"
        f"{children}"
        "</Item>"
    )


def build_directory(directory: Path, referents: Referent) -> str:
    """Renders every child of one directory, ignoring its own entry point."""
    parts = []

    for path in sorted(directory.iterdir()):
        if path.is_dir():
            entry = path / MODULE_ENTRY
            if not entry.exists():
                raise SystemExit(f"directory without {MODULE_ENTRY}: {path}")
            parts.append(
                item(
                    "ModuleScript",
                    path.name,
                    entry.read_text(encoding="utf-8"),
                    referents.take(),
                    build_directory(path, referents),
                )
            )
        elif path.suffix == ".luau" and path.name not in (ENTRY, MODULE_ENTRY):
            parts.append(
                item("ModuleScript", path.stem, path.read_text(encoding="utf-8"), referents.take())
            )

    return "".join(parts)


def count_modules(directory: Path) -> int:
    """Counts the modules written, for the line printed at the end."""
    return sum(1 for path in directory.rglob("*.luau") if path.name != ENTRY)


def build() -> str:
    """Renders the whole plugin as one model document."""
    entry_path = SOURCE_DIR / ENTRY
    if not entry_path.exists():
        raise SystemExit(f"missing entry point: {entry_path}")

    referents = Referent()
    root_referent = referents.take()
    children = build_directory(SOURCE_DIR, referents)
    root = item("Script", PLUGIN_NAME, entry_path.read_text(encoding="utf-8"), root_referent, children)
    return f'<roblox version="4">{root}</roblox>'


def main() -> None:
    """Writes the plugin where the caller asked for it, and says where that was.

    A checksum is written beside it, because the installer refuses to install a
    file it cannot verify.
    """
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else default_output()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(build(), encoding="utf-8")

    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    checksum = output.with_name(output.name + ".sha256")
    checksum.write_text(digest + "  " + output.name + "\n", encoding="utf-8")

    print(
        f"wrote {output} ({output.stat().st_size} bytes, "
        f"1 script + {count_modules(SOURCE_DIR)} modules)"
    )
    print(f"wrote {checksum}")


if __name__ == "__main__":
    main()
