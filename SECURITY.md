# Security Policy

## Supported Versions

Only the latest release of CoreAudioTapKit receives security fixes. If you are
on an older version, update before reporting.

## Reporting a Vulnerability

Please do not open a public issue for security problems.

Instead, use GitHub's private vulnerability reporting for this repository:
https://github.com/CJStanfield/CoreAudioTapKit/security/advisories/new

You can expect an acknowledgement within 72 hours. Once a fix is available and
released, the advisory will be published with credit to the reporter unless you
ask otherwise.

## Scope

CoreAudioTapKit is a macOS audio forwarding library built on Core Audio process
taps. Reports are especially welcome for:

- Memory safety issues in the audio callback path
- Privilege or entitlement misuse
- Any way a consuming app could be made to capture audio outside the tap's
  configured scope
