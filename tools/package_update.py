"""Package a built app for the Suixinjie updater."""

from argparse import ArgumentParser
from pathlib import Path
from plistlib import load
from struct import unpack
from zipfile import ZIP_DEFLATED, ZipFile


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "windows"))
    parser.add_argument("app", type=Path, help="A macOS .app or the Windows build output directory")
    parser.add_argument("--output", type=Path, default=Path("build/releases"))
    args = parser.parse_args()

    if args.platform == "macos":
        executable = "Contents/MacOS/Suixinjie"
        entries = ("Contents/Info.plist", executable,
                   "Contents/Resources/AppIcon.icns", "Contents/_CodeSignature/CodeResources")
        with (args.app / entries[0]).open("rb") as plist:
            info = load(plist)
        if info.get("CFBundleIdentifier") != "app.suixinjie.macos" or info.get("CFBundleExecutable") != "Suixinjie":
            parser.error("the app bundle identifier or executable does not match Suixinjie")
        with (args.app / executable).open("rb") as binary:
            magic, cpu = unpack("<II", binary.read(8))
        architecture = {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(cpu)
        if magic != 0xFEEDFACF or architecture is None:
            parser.error("the app must contain a thin arm64 or x86_64 executable")
        name = "Suixinjie-macos-" + architecture + ".zip"
        prefix = "随心截.app/"
    else:
        entries = ("Suixinjie.exe", "Suixinjie.exe.config")
        name = "Suixinjie-windows.zip"
        prefix = ""

    for entry in entries:
        source = args.app / entry
        if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
            parser.error(f"missing regular file {source}")

    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / name
    with ZipFile(archive, "w", ZIP_DEFLATED) as zip_file:
        for entry in entries:
            zip_file.write(args.app / entry, prefix + entry)
    print(archive)


if __name__ == "__main__":
    main()
