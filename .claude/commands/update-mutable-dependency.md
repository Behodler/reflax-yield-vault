# Update Mutable Dependency

Updates a mutable dependency to pull the latest interface changes from the source repository.

## Usage

```bash
.claude/commands/update-mutable-dependency.sh <dependency-name>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `dependency-name` | Yes | Name of the mutable dependency directory in `lib/mutable/` |

## Description

This command updates an existing mutable dependency by pulling the latest changes from its source repository, then re-applies the interface-only filtering. Use this after a sibling submodule has implemented your change requests.

## Requirements

- The dependency must already exist in `lib/mutable/`
- The updated repository must maintain a `src/interfaces/` directory

## Workflow

1. Reverts any local changes in the dependency directory
2. Pulls the latest changes from the remote
3. Validates that `src/interfaces/` still exists
4. Removes all source files except interfaces
5. Preserves only the updated interface contracts

## Examples

```bash
# Update the token dependency
.claude/commands/update-mutable-dependency.sh token

# Update after change request was implemented
.claude/commands/update-mutable-dependency.sh oracle
```

## Typical Use Case

1. You added a change request to `MutableChangeRequests.json`
2. User ran `pop-change-requests.sh` to transfer requests
3. Target submodule implemented the changes
4. Run this command to pull the updated interfaces
5. Continue development with the new interface methods

## Notes

- This will discard any local modifications in the dependency
- Only interfaces are preserved after the update
- Run this after sibling submodules have addressed your change requests
