# Contributing to fathom

Thank you for contributing! Please follow the guidelines below when submitting changes.

## Commit Messages

This repository uses [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <subject>
```

### Types

- `feat` — new feature or encoding support
- `fix` — bug fix
- `perf` — performance optimization
- `refactor` — code restructuring without changing behavior
- `docs` — documentation updates (`README.md`, `ROADMAP.md`, `CHANGELOG.md`, doc comments)
- `test` — adding or updating specs
- `build` — build config, `shard.yml`, or table generators (`tools/`)
- `ci` — GitHub Actions workflows or repository hooks
- `chore` — maintenance tasks and project configuration
- `style` — code formatting or whitespace changes

### Scopes (optional)

Common scopes: `bom`, `utf`, `single_byte`, `detector`, `tables`, `spec`, `bench`, `ci`.

### Rules

- Use the imperative mood in `<subject>` (e.g. `add ...`, not `added ...`).
- Keep the header line **72 characters or fewer** and without a trailing period.
- Mark breaking API changes with `!` after `<type>`/`(<scope>)` and/or a `BREAKING CHANGE:` footer.

### Examples

```text
feat(utf): add BOM-less UTF-32 detection
fix(detector): handle NUL-terminated UTF-8 strings
perf(single_byte): eliminate per-byte allocations
docs: update roadmap for 0.2.0
```

## Local Git Setup

Enable the repository commit template and `commit-msg` hook locally:

```sh
git config commit.template .gitmessage
git config core.hooksPath .githooks
```

## Development Checks

Before opening a pull request, ensure formatting, lint, specs, and docs pass:

```sh
crystal tool format --check
shards install && mkdir -p bin && crystal build -o bin/ameba lib/ameba/bin/ameba.cr  # once
bin/ameba
crystal spec
crystal docs
```
