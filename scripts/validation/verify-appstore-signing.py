#!/usr/bin/env python3
"""Check App Store certificate consistency, including codeless resource bundles."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def certificate(bundle, directory):
    prefix = str(directory / "certificate")
    Path(prefix + "0").unlink(missing_ok=True)
    run("codesign", "-d", "--extract-certificates=" + prefix, str(bundle))
    return Path(prefix + "0").read_bytes()


def is_codeless(bundle):
    for info in [bundle / "Contents/Info.plist", bundle / "Info.plist"]:
        if info.exists() and "CFBundleExecutable" in plistlib.loads(info.read_bytes()):
            return False
    macho = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for path in bundle.rglob("*"):
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in macho:
                    return False
    return True


def has_signature(bundle):
    directories = [bundle / "Contents/_CodeSignature", bundle / "_CodeSignature"]
    return any(path.is_file() for directory in directories for path in directory.rglob("*"))


def verify(app):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")))
    certificates = profile["DeveloperCertificates"]
    report = {"app": str(app), "passed": False, "resource_bundles": [], "errors": []}
    with tempfile.TemporaryDirectory(prefix="pageflow-signing-check-") as scratch:
        directory = Path(scratch)
        if certificate(app, directory) not in certificates:
            report["errors"].append("App signer is absent from its provisioning profile")
        report["profile_certificate_sha256"] = [hashlib.sha256(value).hexdigest() for value in certificates]
        for bundle in sorted((app / "Contents/Resources").rglob("*.bundle")):
            signed = subprocess.run(["codesign", "-d", str(bundle)], capture_output=True)
            item = {"path": str(bundle.relative_to(app))}
            if signed.returncode == 0:
                run("codesign", "--verify", "--strict", str(bundle))
                item["signed"] = True
                item["certificate_matches_profile"] = certificate(bundle, directory) in certificates
                if not item["certificate_matches_profile"]:
                    report["errors"].append(item["path"] + ": signer is absent from provisioning profile")
            elif not has_signature(bundle) and is_codeless(bundle):
                item.update(signed=False, covered_by_app_resource_seal=True)
            else:
                report["errors"].append(item["path"] + ": invalid or unsigned executable bundle")
            report["resource_bundles"].append(item)
    report["passed"] = not report["errors"]
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        report = verify(args.app.resolve())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        report = {"passed": False, "errors": [str(error)]}
    text = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
