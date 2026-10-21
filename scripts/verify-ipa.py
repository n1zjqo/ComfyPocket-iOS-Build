import pathlib
import plistlib
import struct
import sys
import zipfile


def require(condition, message):
    if not condition:
        raise SystemExit("IPA verification failed: " + message)


def main():
    ipa = pathlib.Path(sys.argv[1])
    require(ipa.is_file(), "file missing")
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "ZIP CRC mismatch")
        names = archive.namelist()
        require(all(not name.startswith("/") and ".." not in pathlib.PurePosixPath(name).parts for name in names), "unsafe ZIP path")
        apps = [name for name in names if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        require(len(apps) == 1, "expected exactly one app inside Payload")
        info = plistlib.loads(archive.read(apps[0]))
        require(info.get("CFBundleIdentifier") == "com.ray.comfypocket", "unexpected bundle ID")
        require(info.get("MinimumOSVersion") == "15.0", "deployment target must be 15.0")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "simulator build is not installable on iPhone")
        app = apps[0].removesuffix("Info.plist")
        binary = archive.read(app + info["CFBundleExecutable"])
        require(len(binary) >= 32, "executable is empty")
        magic, cpu, subtype, filetype, count, command_bytes, flags, reserved = struct.unpack_from("<8I", binary)
        require(magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 2, "expected arm64 device Mach-O executable")
        offset = 32
        has_signature = False
        minimum = None
        for index in range(count):
            require(offset + 8 <= len(binary), "truncated load commands")
            command, size = struct.unpack_from("<2I", binary, offset)
            require(size >= 8 and offset + size <= len(binary), "invalid load command")
            if command == 0x1D:
                has_signature = True
            if command == 0x32:
                platform, minimum, sdk, tools = struct.unpack_from("<4I", binary, offset + 8)
                require(platform == 2, "Mach-O target is not iOS device")
            if command == 0x25:
                minimum = struct.unpack_from("<I", binary, offset + 8)[0]
            offset += size
        require(has_signature, "Mach-O is not signed")
        require(minimum == 15 << 16, "Mach-O minimum OS is not 15.0")
        require(any(name.startswith(app + "_CodeSignature/") for name in names), "app resource signature missing")
        require(app + "Assets.car" in names, "compiled asset catalog missing")
        print("Verified IPA structure, arm64 device executable, signature presence, and minimum iOS 15.0.")
        print("This does not prove successful installation or device runtime behavior.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException, struct.error, KeyError, ValueError) as error:
        raise SystemExit("IPA verification failed: " + str(error)) from error
