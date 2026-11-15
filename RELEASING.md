# Release Preparation

The private remote is `https://github.com/urtokk/ai-commitplan.nvim`. The verified
source has been pushed with maintainer approval. No tag, public visibility change
or release has been created. Public publication and tagging remain separate
maintainer decisions.

## Completed Locally

- Separate configuration and provider modules with a small public API.
- Headless tests for plan edits, fixed-group regeneration and actual Git staging.
- Real curl requests against a local Anthropic HTTP fixture.
- Hook rejection, signing failure and a partially successful commit sequence.
- Pinned CI actions, read-only permissions and disabled persisted credentials.
- CI matrix for Neovim 0.11.0, 0.11.5, 0.12.0 and 0.12.6 on Linux and macOS.
  All eight jobs passed in hosted run `43730537206` after the first private push.
- Local installation instructions, support boundaries and data-handling notes.
- Complete local act workflow on native Linux ARM64 with Neovim 0.12.6.

## Local Test Evidence

On 2026-11-15, the headless plan/staging suite, real hook/signing/partial-failure
tests and curl-based Anthropic/OpenAI transport fixtures passed on macOS arm64
with Neovim 0.11.0, 0.11.5, 0.12.0 and 0.12.6. The 0.11 tests exposed a binary
string hashing incompatibility; the fingerprint now base64-encodes its input.
This does not establish Linux compatibility or replace real provider/UI checks.
The complete act workflow subsequently passed on native Linux ARM64 with Neovim
0.12.6. After the approved first private push, hosted run `43730537206` passed
all eight Ubuntu/macOS matrix jobs. The local_config consumer also tests actual
Lazy loading, command/keymap registration and option application in an isolated
Neovim session without AI requests.

## Before the First Public Preview

### Completed Publication Checks

On 2026-11-15, Gitleaks 8.30.1 scanned all three existing commits across all refs
and the current working tree, with default rules and inline allow comments
disabled. Both scans reported no leaks. The configured author email was also
confirmed in the maintainer's existing public repositories. MIT was selected
and the complete license text added. Re-scan after subsequent changes; this
static check cannot guarantee that every possible secret has been detected.

### Remaining Checks

- MIT license selected; the complete text names Torben Diegel as copyright holder.
- Keep `mise run check`, the container smoke test and hosted CI matrix green.
- Exercise a real OpenAI-compatible and a real Anthropic-compatible endpoint.
  Record provider/model/version, without credentials or confidential diffs.
- Review the UI interactively on the minimum Neovim version, including cancelling
  dialogs, invalid edits, moving the last unit and editing multiline bodies.
- Re-check new history and documentation for private information before publishing.
- Replace local installation paths with the approved repository URL.
- Review any outstanding limitations, then create an explicitly approved preview
  tag. Do not advertise a stable release before the manual checks pass.

## Known Boundaries

Commit sequences are not atomic: earlier commits remain if a later hook or
signature fails. The index remains available for inspection. Concurrent Git
operations are unsupported. Original Git hunks cannot be subdivided in the UI.
Messages API output is non-streaming; Responses API is unsupported.
No availability, response-time or feature-completion commitment is made.
