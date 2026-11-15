# ai-commitplan.nvim

Development preview: plan atomic Conventional Commits, rearrange Git hunks,
and regenerate messages while keeping reviewed groups fixed.

## Requirements

Neovim >= 0.11, Git, curl and a configured AI endpoint. No aichat dependency.
This is a preparation snapshot extracted from local_config, not a published
release. The dotfiles currently retain their own copy; changes must be synced
until extraction and consumer migration are completed.

## Local Installation

Example for lazy.nvim; replace the directory with this checkout:

```lua
{
  dir = "/absolute/path/to/ai-commitplan",
  name = "ai-commitplan.nvim",
  cmd = "AICommit",
  config = function()
    require("ai_commitplan").setup({
      provider = "anthropic",
      endpoint = "https://api.anthropic.com/v1",
      model = "your-provider-model",
      api_key_env = "ANTHROPIC_API_KEY",
    })
  end,
}
```

`provider = "openai_compatible"` uses streamed Chat Completions and an endpoint
including `/v1`. `provider = "anthropic"` uses non-streaming Messages with
`x-api-key` and `anthropic-version: 2023-06-01`. Both need a model.
`setup({})` discovers local oMLX settings and a loaded model.
`api_key` accepts a string or function; `api_key_env` overrides it.
`connect_timeout` defaults to 5 seconds and `idle_timeout` to 120 seconds.
Run `:checkhealth ai_commitplan` to inspect local prerequisites.

## Workflow

Run `:AICommit` and inspect each hunk in the preview.

- `m`: edit a message field.
- `M`: move the selected unit to another or new commit.
- `r`: regenerate all messages for the current fixed groups.
- `e`: edit the entire plan as JSON.
- `Ctrl-S`: save JSON edits and return to review; from review, confirm commits.
- `q`: discard JSON edits or close the review.
- `Tab`: switch between plan and diff preview.

Invalid responses leave the current plan intact. Every unit must occur exactly
once. New/deleted/binary/mode-only files are indivisible. Modified text files
use original Git hunks. Initial commits and unresolved conflicts are unsupported.

## Data and Git Behavior

Diffs and file context are sent to the configured endpoint. Choose the endpoint
according to your repository's confidentiality requirements. Keys are passed in
exclusive mode-0600 temporary curl header files and removed after the request.

Execution checks HEAD, staged changes and the working-tree snapshot first. It
then resets staging and stages each group before committing. Hooks and signing
remain enabled. A failure stops the sequence; earlier commits remain and staged
changes may need manual inspection. There is no automatic rollback. Avoid
concurrent Git changes during execution. Review all proposed messages and groups.

## Validation and Release Preparation

Run `zsh tests/ai-commit.zsh` and `stylua --check lua plugin tests/ai-commit.lua`.
Tests use temporary repositories and mocked model responses; they do not call a
paid API. A real Claude-compatible endpoint has not yet been tested.
The local HTTP transport fixture runs with
`NVIM_AI_COMMIT_TEST=1 nvim --headless -u NONE -i NONE -l tests/ai-commit-http.lua`
from the repository root. It opens a loopback socket and exercises real curl,
the Messages request body and authentication headers without API credentials.

Before publishing: complete the consumer migration, choose a license, add CI,
test real providers and interactive UI, and exercise commit-hook and signing
failures. No license grant has been selected for this preparation snapshot.
