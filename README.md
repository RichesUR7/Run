Run.sh

Portable System Health & Hardware Diagnostics

A lightweight Bash utility for inspecting system health, collecting hardware information, and identifying potential issues through read-only diagnostic checks.

""License: MIT" (https://img.shields.io/badge/License-MIT-green.svg)" (LICENSE)
"Language" (https://img.shields.io/badge/Language-Bash-blue.svg)
"Version" (https://img.shields.io/badge/version-1.1.0-orange.svg)

---

Features

- System Diagnostics — Collect basic system health information.
- Hardware Inspection — Identify available hardware information and diagnostic tools.
- Read-Only Design — Inspect system state without intentionally modifying system configuration.
- Quick Scan — Run a shorter diagnostic pass.
- JSON Output — Export results for automation and integration.
- Portable Design — Designed for Linux and Unix-like systems.
- Graceful Degradation — Report when checks cannot run because of missing tools, unsupported hardware, or insufficient permissions.
- Terminal Interface — Display diagnostic results and a summary of findings.

«Note: Available checks depend on the operating system, hardware, installed utilities, and user permissions. Not every diagnostic is supported on every platform.»

Supported Platforms

Platform| Support
Linux| Primary target
macOS| Compatibility testing required
FreeBSD| Compatibility testing required
Other BSD systems| Compatibility testing required
Raspberry Pi| Depends on operating system and hardware
Embedded Linux| Depends on available utilities and system configuration

Run.sh requires Bash. Some diagnostic checks may depend on platform-specific commands.

Platform compatibility should be confirmed through testing before being considered officially supported.

Requirements

- Bash
- Standard Unix command-line utilities
- Optional platform-specific diagnostic utilities for extended checks

Run the script as a regular user first. Use elevated privileges only when a particular diagnostic requires them.

Installation

Clone your repository:

git clone <your-repository-url>
cd <your-repository-directory>

Make the script executable:

chmod +x Run.sh

Usage

Run a full diagnostic scan

./Run.sh

Run a quick scan

./Run.sh --quick

Display help

./Run.sh --help

Display the version

./Run.sh --version

JSON Reports

Generate a JSON report:

./Run.sh --quick --plain --json report.json

Validate the report:

python3 -m json.tool report.json

JSON output can be used for automated testing, reporting, and integration with other tools.

«Privacy: Review reports before sharing them. They may contain host details, hardware information, software versions, or other identifying information.»

Understanding Results

Status| Meaning
🟢 "PASS"| The check completed without detecting the condition it was designed to identify.
🟡 "WARN"| A potential issue requiring review was detected.
🔴 "FAIL"| A check detected a condition classified as a failure.
🔵 "INFO"| Informational system data was collected.
⚪ "SKIP"| A check could not be performed or was not applicable.

A warning does not necessarily mean hardware is failing. A passing result does not guarantee that the system is free from problems.

A check may be skipped because a utility is missing, permissions are insufficient, hardware information is unavailable, or the check does not apply to the current system.

Safety and Security

Run.sh is designed for read-only diagnostics.

Its intended behavior is to:

- Inspect system and hardware information.
- Check the availability of diagnostic utilities.
- Report potential problems.
- Produce terminal or JSON output.

It should not automatically repair the system, change configuration, delete files, or modify firmware settings.

Review the script and its dependencies before running it on critical systems. Read-only behavior should be verified for every release.

Recommended Precautions

- Avoid running as root unless necessary.
- Download the script from a trusted source.
- Review the source code before execution.
- Do not automatically execute suggested repair commands.
- Review reports before sharing them.
- Test new releases in a non-production environment.

Troubleshooting

Permission denied

chmod +x Run.sh

Alternatively:

bash Run.sh

A diagnostic is skipped

A check may be skipped when:

- The operating system does not support it.
- A required command is unavailable.
- The hardware does not expose the relevant information.
- Additional permissions are required.
- The check is not applicable to the current device.

A skipped check should not automatically be interpreted as a hardware problem.

Validate JSON output

python3 -m json.tool report.json

If validation fails, include the relevant error and Run.sh version when reporting the issue.

Testing

Check Bash syntax:

bash -n Run.sh

Check the version and help output:

./Run.sh --version
./Run.sh --help

Run a quick scan:

./Run.sh --quick --plain

Test JSON generation:

./Run.sh --quick --plain --json report.json
python3 -m json.tool report.json

Test on each operating system you intend to support, including systems where optional diagnostic utilities are missing.

Roadmap

Potential future improvements:

- [ ] Expanded SMART storage diagnostics
- [ ] NVMe health and error reporting
- [ ] CPU, GPU, and drive temperature monitoring
- [ ] Battery health checks
- [ ] Raspberry Pi and ARM-specific diagnostics
- [ ] Improved macOS and BSD compatibility
- [ ] Additional security configuration checks
- [ ] Enhanced terminal dashboard
- [ ] HTML and PDF report generation
- [ ] Historical health comparisons
- [ ] Automated cross-platform tests
- [ ] Documented exit codes for automation

These are planned improvements, not claims that the features are already implemented.

Contributing

Contributions are welcome.

When submitting a change:

1. Describe the problem or proposed feature.
2. Identify the affected operating systems.
3. Test the change on the relevant platform.
4. Avoid unnecessary dependencies.
5. Preserve read-only behavior.
6. Document new command-line options.
7. Include example output where useful.

For bug reports, include:

- Run.sh version
- Operating system and version
- Bash version
- Command used
- Relevant output with sensitive information removed

License

Run.sh is distributed under the "MIT License" (LICENSE).

See the "LICENSE" file for the complete license text.

Disclaimer

Run.sh provides diagnostic information for troubleshooting and system maintenance. Its results are not a guarantee of hardware reliability, system security, or future performance.

Back up important data and consult qualified technical support when investigating critical hardware or security issues.

---

Project goal: Provide a lightweight, understandable, and portable diagnostic utility that helps users inspect their systems without unnecessary complexity or unintended system changes.
