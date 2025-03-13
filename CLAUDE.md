# CLAUDE.md - Agent SDK Development Guide

## Common Commands
- `make sync` - Install dependencies with uv
- `make lint` - Run ruff linter checks
- `make format` - Format code with ruff
- `make mypy` - Run type checker
- `make tests` - Run all tests
- `uv run pytest tests/test_file.py::test_function_name` - Run single test
- `make build-docs` - Build documentation
- `make serve-docs` - Serve docs locally

## Code Style Guidelines
- **Imports**: standard library → third-party → internal (sorted by ruff)
- **Formatting**: 100 char line length, Google-style docstrings
- **Types**: Strict typing, mypy in strict mode, proper use of Optional/generics
- **Naming**: PascalCase classes, snake_case functions/variables, UPPER_SNAKE_CASE constants
- **Errors**: Custom exceptions derived from AgentsException with descriptive messages
- **Testing**: Pytest with fixtures, descriptive test names, mocks model calls by default