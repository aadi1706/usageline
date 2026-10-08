"""Print a markdown summary of a Trivy JSON report. Usage: trivy_summary.py <report.json> <image>"""

import collections
import json
import sys


def main(report_path: str, image: str) -> None:
    report = json.load(open(report_path))
    rows = [v for r in report.get("Results", []) for v in (r.get("Vulnerabilities") or [])]
    count = collections.Counter((v["Severity"], bool(v.get("FixedVersion"))) for v in rows)

    print(f"### Trivy scan: `{image}`")
    print()
    print("| Severity | Total | Fix available | No fix yet |")
    print("| --- | ---: | ---: | ---: |")
    for sev in ("CRITICAL", "HIGH"):
        fixable, unfixed = count[(sev, True)], count[(sev, False)]
        print(f"| {sev} | {fixable + unfixed} | {fixable} | {unfixed} |")

    fixable_rows = [v for v in rows if v.get("FixedVersion")]
    if fixable_rows:
        print()
        print("Vulnerabilities with a fix available:")
        print()
        print("| Severity | ID | Package | Installed | Fixed in |")
        print("| --- | --- | --- | --- | --- |")
        for v in sorted(fixable_rows, key=lambda v: (v["Severity"] != "CRITICAL", v["VulnerabilityID"])):
            print(
                f"| {v['Severity']} | {v['VulnerabilityID']} | {v['PkgName']} "
                f"| {v['InstalledVersion']} | {v['FixedVersion']} |"
            )


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
