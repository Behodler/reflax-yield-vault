# Consider Change Requests

Reviews and displays incoming change requests from sibling submodules.

## Usage

```bash
.claude/commands/consider-change-requests.sh
```

## Arguments

None.

## Description

This command displays the contents of `SiblingChangeRequests.json`, which contains change requests that have been transferred from sibling submodules via the parent-level `pop-change-requests.sh` script. After reviewing, you should implement the requested changes using TDD principles.

## Workflow

1. Checks for the existence of `SiblingChangeRequests.json`
2. Displays the contents of the file
3. Prompts you to review and implement the changes

## Request Format

The `SiblingChangeRequests.json` file contains requests in this format:

```json
{
  "requests": [
    {
      "dependency": "this-submodule",
      "changes": [
        {
          "fileName": "IInterface.sol",
          "description": "Add method X to handle Y"
        }
      ]
    }
  ]
}
```

## Implementation Process

1. Run this command to view pending requests
2. For each request, follow TDD principles:
   - Write failing tests for the new interface method
   - Implement the interface change
   - Ensure tests pass
3. If a request cannot be implemented, document the issue
4. Clear the processed requests from the file
5. Commit and push changes so requesting submodules can update

## Examples

```bash
# Check for incoming change requests
.claude/commands/consider-change-requests.sh
```

## Notes

- Always implement changes using TDD principles
- Document any issues with requests that cannot be fulfilled
- After implementation, sibling submodules will run `update-mutable-dependency.sh` to pull your changes
