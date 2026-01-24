# Add Mutable Dependency

Adds a sibling submodule as a mutable dependency, exposing only its interfaces.

## Usage

```bash
.claude/commands/add-mutable-dependency.sh <repository>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `repository` | Yes | Repository URL or local path to the sibling submodule |

## Description

This command clones a sibling submodule into `lib/mutable/` and removes all implementation details, keeping only the `src/interfaces/` directory. This enforces the mutable dependency isolation principle where sibling submodules can only access each other's interfaces.

## Requirements

- The target repository must have a `src/interfaces/` directory
- The command must be run from the submodule root directory

## Workflow

1. Clones the repository to `lib/mutable/<repo-name>/`
2. Validates that `src/interfaces/` exists
3. Removes all source files except interfaces
4. Preserves only the interface contracts for use as dependency

## Examples

```bash
# Add a local sibling submodule
.claude/commands/add-mutable-dependency.sh ../token

# Add from a git URL
.claude/commands/add-mutable-dependency.sh https://github.com/org/token-submodule.git
```

## Notes

- If changes to the mutable dependency are needed, use the change request process
- Only interfaces and abstract contracts are exposed
- Implementation details are never available through mutable dependencies
