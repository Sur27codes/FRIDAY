# Security Policy

## Reporting a vulnerability

If you find a security issue in this project, please open a private report via GitHub's "Report a vulnerability" feature on this repository, or contact the author directly through the links on the [profile README](https://github.com/Sur27codes). Please do not open a public issue for security reports.

## Secrets policy

- Provider API keys and other credentials are stored in the macOS Keychain only. They are never committed to this repository, written to `.env` files, or printed to logs or diagnostics.
- If you believe a secret was ever committed to this repository's history, please report it privately rather than opening a public issue, so it can be rotated before disclosure.
