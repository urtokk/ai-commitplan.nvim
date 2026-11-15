# Contributing

Run `mise install` and `mise run check` before proposing a change.
Tests use temporary repositories, fake API credentials and a loopback HTTP
server. They do not call paid providers. Avoid testing against valuable changes.

Keep the provider protocol, plan validation and Git execution boundaries clear.
Fixes that affect staging or execution need a regression test in a temporary
repository. Include the plugin revision, Neovim version and a minimal synthetic
reproduction in bug reports. Do not include private diffs or credentials.

Use Conventional Commit messages. Describe behavior and validation in pull
requests. Do not disable commit hooks, signing or plan validation as a workaround.

License selection is pending; do not solicit third-party contributions or
publish this repository until the maintainer has selected a license.
