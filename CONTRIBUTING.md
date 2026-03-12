# Contributing

Thanks for your interest in improving the IMAP to Gmail Migration Toolkit.

## Reporting issues

If you encounter a problem during migration, please include:
- Your OS (macOS version / Linux distribution)
- Whether you're using Docker or native imapsync
- The exit code from imapsync (check watchdog logs)
- Relevant log output (sanitize any email addresses or credentials)

## Submitting changes

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run the test harness: `cd migrate/test && ./harness.sh`
5. Submit a pull request

## Code style

- Shell scripts: POSIX-compatible where possible, Bash 4+ when needed
- Use `set -euo pipefail` in Bash scripts
- Keep scripts self-contained -- avoid external dependencies beyond standard Unix tools
- Test new watchdog behavior by adding scenarios to `migrate/test/scenarios/`

## Security

- Never commit credentials, passwords, or API keys
- Use `~/.imapsync/credentials/` for credential storage
- Passwords should be passed via files, never command-line arguments

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
