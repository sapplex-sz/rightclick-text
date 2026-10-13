#!/usr/bin/env python3
"""Exercise the actual production XPC requirement; never re-sign input bundles.

Usage: scripts/verify-xpc-signing.py RightClickText.app \
         --app-store-sample /Applications/Xcode.app --report /tmp/signing.json

The optional sample proves the App Store certificate branch with that sample's
own exact identifier; it does not claim our app has been processed by the store.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HOST_ID = "com.sapplex.RightClickText"
WORKER_ID = HOST_ID + ".CreationService"
TEAM_ID = "8D9AHY5YW8"


def run(arguments, *, check=True):
    result = subprocess.run(arguments, text=True, capture_output=True, timeout=240)
    if check and result.returncode:
        raise RuntimeError(f"Command failed: {arguments[0]}\n{result.stdout}{result.stderr}")
    return result


def identifier(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)["CFBundleIdentifier"]
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", value):
        raise ValueError("Unexpected bundle identifier")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--app-store-sample", type=Path)
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args()
    app = arguments.app.resolve()
    worker = app / "Contents/XPCServices/CreationService.xpc"
    if identifier(app) != HOST_ID or identifier(worker) != WORKER_ID:
        raise ValueError("Expected the production host and CreationService identifiers")

    report = {"timeUTC": datetime.now(timezone.utc).isoformat(),
              "host": str(app), "worker": str(worker), "checks": [],
              "source": "Sources/ServiceInterface/CreationServiceProtocol.swift",
              "reference": "https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements"}

    def check(label, path, requirement, accepts):
        result = run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, str(path)], check=False)
        # Exit 3 specifically means a valid signature failed the supplied requirement.
        # Syntax errors, missing inputs or invalid signatures must not pass negative tests.
        passed = result.returncode == (0 if accepts else 3)
        item = {"check": label, "passed": passed, "exitCode": result.returncode,
                "expectedAcceptance": accepts, "path": str(path), "requirement": requirement}
        if result.stderr.strip():
            item["diagnostic"] = result.stderr.strip()
        report["checks"].append(item)
        print(("PASS " if passed else "FAIL ") + label, flush=True)
        if not passed:
            raise RuntimeError(f"{label}: {result.stdout}{result.stderr}")

    try:
        with tempfile.TemporaryDirectory(prefix="rightclicktext-signature-") as temporary:
            temporary = Path(temporary)
            harness = temporary / "Requirement.swift"
            tool = temporary / "requirement"
            harness.write_text('''import Foundation
@main enum RequirementHarness {
    static func main() {
        let requirement = CreationServiceConfiguration.requirement(for: CommandLine.arguments[1])
        // Parse with the actual NSXPCConnection API, without resuming any connection.
        let connection = NSXPCConnection(serviceName: CreationServiceConfiguration.workerIdentifier)
        connection.setCodeSigningRequirement(requirement)
        print(requirement)
    }
}
''')
            run(["xcrun", "swiftc", "-swift-version", "5", "-strict-concurrency=complete", "-parse-as-library",
                 str(ROOT / report["source"]), str(harness), "-o", str(tool)])
            def requirement(bundle_id):
                return run([str(tool), bundle_id]).stdout.strip()
            host_requirement = requirement(HOST_ID)
            worker_requirement = requirement(WORKER_ID)
            check("production host accepts correct identity", app, host_requirement, True)
            check("production worker accepts correct identity", worker, worker_requirement, True)
            check("host rejected as worker", app, worker_requirement, False)
            check("worker rejected as host", worker, host_requirement, False)
            if "Developer ID Application:" in run(["codesign", "-dvv", str(app)]).stderr:
                check("Developer ID from wrong team rejected", app,
                      host_requirement.replace(TEAM_ID, "0000000000"), False)

            # Only this disposable compiled harness is ad-hoc signed. Inputs stay intact.
            run(["codesign", "--force", "--sign", "-", "--identifier", HOST_ID, str(tool)])
            check("same identifier with ad-hoc signature rejected", tool, host_requirement, False)

            if arguments.app_store_sample:
                sample = arguments.app_store_sample.resolve()
                sample_id = identifier(sample)
                sample_requirement = requirement(sample_id)
                store_marker = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
                check("sample is really signed by Mac App Store", sample, store_marker, True)
                check("App Store sample accepts its exact identifier", sample, sample_requirement, True)
                check("App Store sample rejected as production host", sample, host_requirement, False)
                report["appStoreSample"] = {"path": str(sample), "identifier": sample_id,
                    "limitation": "Validates certificate branch only; production app is not yet store-processed."}
            else:
                report["appStoreSample"] = "NOT TESTED: pass --app-store-sample to exercise the store branch"
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["error"] = str(error)
        raise
    finally:
        if arguments.report:
            arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("All requested XPC signing checks passed.", flush=True)


if __name__ == "__main__":
    main()
