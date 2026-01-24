# Add Immutable Dependency

Adds an external library as an immutable dependency with full source code access.

## Usage

```bash
.claude/commands/add-immutable-dependency.sh <repository>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `repository` | Yes | Repository URL or local path to the external library |

## Description

This command clones an external library into `lib/immutable/` with full source code access. Immutable dependencies are external libraries (like OpenZeppelin) that don't change based on sibling requirements and provide full implementation access.

## Workflow

1. Clones the repository to `lib/immutable/<repo-name>/`
2. Full source code remains available for import

## Examples

```bash
# Add OpenZeppelin contracts
.claude/commands/add-immutable-dependency.sh https://github.com/OpenZeppelin/openzeppelin-contracts.git

# Add another external library
.claude/commands/add-immutable-dependency.sh https://github.com/foundry-rs/forge-std.git
```

## Notes

- Immutable dependencies provide full source code access
- These are external libraries that don't require the change request process
- Prefer OpenZeppelin for standard implementations (ERC20, Ownable, etc.)
