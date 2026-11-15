# ai-commitplan.nvim

Development preview: plan atomic Conventional Commits, rearrange Git hunks,
and regenerate messages while keeping reviewed groups fixed.

## Requirements

Targets Neovim >= 0.11, Git, curl and a configured AI endpoint.
The CI matrix covers 0.11.0, 0.11.5, 0.12.0 and 0.12.6 on Linux and macOS.
This is a public development preview, not a stable release. Review generated
messages and groups before committing. Real-provider and interactive UI checks
are still incomplete; see [release preparation](RELEASING.md).

## Installation

Install directly from GitHub with lazy.nvim:

```lua
{
  "urtokk/ai-commitplan.nvim",
  main = "ai_commitplan",
  cmd = "AICommit",
  keys = { { "<leader>gA", "<cmd>AICommit<cr>", desc = "AI commit plan" } },
  opts = { provider = "omlx" },
}
```

Choose another provider through `opts` as described below. No GitHub login is
required to install the public repository.

### Local Development

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

Restart Neovim to pick up checkout changes. The plugin does not configure Git
authentication.

### Provider Configuration

`provider = "openai_compatible"` uses streamed Chat Completions and an endpoint
including `/v1`. `provider = "anthropic"` uses non-streaming Messages with
`x-api-key` and `anthropic-version: 2023-06-01`.
`setup({})` discovers local oMLX settings and a loaded model.
`api_key` accepts a string or function; `api_key_env` overrides it.
`connect_timeout` defaults to 5 seconds and `idle_timeout` to 120 seconds.
Run `:checkhealth ai_commitplan` to inspect local prerequisites.

## Model Selection

- `model = "model-id"` fixes the model and skips the picker.
- `models = { "small-model", "larger-model" }` opens a picker for each new plan.
  This is the recommended way to restrict cloud choices to supported chat models
  and your preferred cost range. No request generates a plan until you choose.
- Without either option, Anthropic/OpenAI-compatible providers request `/models`
  and show the returned IDs for explicit selection. If discovery is unsupported,
  configure `models`. Discovery currently uses the first response page and does
  not infer prices, capabilities or a "best" model.
- oMLX defaults to the largest already-loaded local language model when no
  configured model is present. Ollama uses the largest loaded local model with
  confirmed completion capability, skipping embedding and identified remote
  models. Neither backend loads a different model for discovery.
  Other OpenAI-compatible servers use the same picker rules as cloud APIs.

Example with a curated cloud model list (replace IDs with your provider's IDs):

```lua
require("ai_commitplan").setup({
  provider = "anthropic",
  models = { "your-small-model", "your-larger-model" },
  api_key_env = "ANTHROPIC_API_KEY",
})
```

Cancel the picker to stop generation. Message regeneration keeps the model chosen
for that plan. Listing model IDs is not a pricing estimate; provider billing
still applies to generation.

### Local Ollama

```lua
require("ai_commitplan").setup({
  provider = "ollama",
  -- endpoint = "http://127.0.0.1:11434/v1", -- default
  -- model = "your-installed-model", -- optional fixed choice
})
```

Start Ollama independently. The plugin uses `/api/ps` and `/api/show` for loaded
model discovery, and `/v1/chat/completions` for generation. Size means reported
model bytes, not a quality score. If no suitable model is loaded, the
installed-model picker appears. Selecting an unloaded model can cause Ollama to
load it during generation. No model is downloaded automatically.
Use `models = { ... }` for a curated picker instead of auto-selection.
Ollama cloud endpoints should use `openai_compatible` with explicit model choices.

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

Run `mise install` and `mise run check` for all lint and test checks.
The Git tests can also run independently with `bash tests/run.sh`.
Tests use temporary repositories and mocked model responses; they do not call a
paid API. A real Claude-compatible endpoint has not yet been tested.
The local HTTP transport fixture runs with
`NVIM_AI_COMMIT_TEST=1 nvim --headless -u NONE -i NONE -l tests/ai-commit-http.lua`
from the repository root. It opens a loopback socket and exercises real curl,
the Messages and Chat Completions request bodies, authentication headers and
SSE decoding without API credentials.

Hook rejection, signing failures and failures after an earlier successful commit
are covered with real Git processes. See [release preparation](RELEASING.md)
for remaining manual checks, [contributing](CONTRIBUTING.md) for development,
[changelog](CHANGELOG.md) for changes and `:help ai-commitplan` for editor help.
The contributing guide includes local GitHub Actions testing with `act`.

## License

[MIT](LICENSE), copyright 2026 Torben Diegel.
