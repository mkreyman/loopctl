# Contributing to loopctl

Thank you for your interest in contributing to loopctl.

## Getting Started

1. Check [GitHub Issues](https://github.com/mkreyman/loopctl/issues) for open items
2. Fork the repository and create a feature branch
3. Follow the setup instructions in [README.md](README.md#local-development)
4. Run the full quality gate before submitting: `mix precommit`

## Quality Standards

All contributions must pass:

- `mix compile --warnings-as-errors` -- Zero compiler warnings
- `mix format --check-formatted` -- Consistent formatting
- `mix credo --strict` -- Static analysis
- `mix dialyzer` -- Type checking
- `mix test` -- Full test suite with 100% pass rate

## Reporting Issues

Please use [GitHub Issues](https://github.com/mkreyman/loopctl/issues) to report bugs or request features. Include reproduction steps and relevant error output when possible.
