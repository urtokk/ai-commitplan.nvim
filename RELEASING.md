# Release Preparation

This repository has no remote or release automation. Preparing it does not
publish it. Publishing, pushing and tagging require a separate maintainer action.

## Completed Locally

- Separate configuration and provider modules with a small public API.
- Headless tests for plan edits, fixed-group regeneration and actual Git staging.
- Real curl requests against a local Anthropic HTTP fixture.
- Hook rejection, signing failure and a partially successful commit sequence.
- Pinned CI actions, read-only permissions and disabled persisted credentials.
- CI matrix for Neovim 0.11.0, 0.11.5, 0.12.0 and 0.12.6 on Linux and macOS.
  This is a configured matrix, not evidence of successful hosted CI runs.
- Local installation instructions, support boundaries and data-handling notes.

## Local Test Evidence

On 2026-11-15, the headless plan/staging suite, real hook/signing/partial-failure
tests and curl-based Anthropic/OpenAI transport fixtures passed on macOS arm64
with Neovim 0.11.0, 0.11.5, 0.12.0 and 0.12.6. The 0.11 tests exposed a binary
string hashing incompatibility; the fingerprint now base64-encodes its input.
This does not establish Linux compatibility or replace real provider/UI checks.

## Before the First Public Preview

- Select a license and add its complete text with the correct copyright holder.
- Run `mise run check` and the GitHub matrix after a remote is explicitly approved.
- Exercise a real OpenAI-compatible and a real Anthropic-compatible endpoint.
  Record provider/model/version, without credentials or confidential diffs.
- Review the UI interactively on the minimum Neovim version, including cancelling
  dialogs, invalid edits, moving the last unit and editing multiline bodies.
- Review Git history, author email and documentation for private information.
- Replace local installation paths with the approved repository URL.
- Review any outstanding limitations, then create an explicitly approved preview
  tag. Do not advertise a stable release before the manual checks pass.

## Known Boundaries

Commit sequences are not atomic: earlier commits remain if a later hook or
signature fails. The index remains available for inspection. Concurrent Git
operations are unsupported. Original Git hunks cannot be subdivided in the UI.
Messages API output is non-streaming; Responses API is unsupported.
No availability, response-time or feature-completion commitment is made.
