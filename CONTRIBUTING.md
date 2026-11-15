# Contributing

Run `mise install` and `mise run check` before proposing a change.
Tests use temporary repositories, fake API credentials and a loopback HTTP
server. They do not call paid providers. Avoid testing against valuable changes.

## Testing Actions Before a Push

`mise run check` runs the same commands as CI on the host.
`mise run ci-list` checks workflow discovery without
requiring a running container engine. With Docker running, execute one Linux
matrix entry before pushing:

```sh
mise run ci-local
```

The default is Neovim 0.12.6. Select another matrix version with
`AI_COMMITPLAN_NVIM_VERSION=0.11.0 mise run ci-local`; repeat with `0.11.5`
and `0.12.0` for the remaining versions. The tasks require act and Docker in PATH.
They disable the Docker socket mount inside the runner because the tests do not
need Docker themselves. The tasks do not start virtual machines, select Docker
contexts or manage the container engine; Docker must already be running.
The first run downloads a runner image.
The task uses the community-maintained `catthehacker/ubuntu:act-latest` runner
image recommended by the act documentation, not an official GitHub image.
The task uses Docker's native architecture by default. Set
`--container-architecture linux/amd64` as an extra act argument only if the
engine supports that
architecture or has emulation configured. A native ARM64 run does not test the
hosted AMD64 runner architecture.
Docker cannot reproduce a macOS GitHub
runner; those jobs still need macOS host tests and eventually a hosted run.
`act` also differs in permissions, concurrency and GitHub context. A successful
local run reduces surprises but does not establish full hosted CI equivalence.
See the [act usage guide](https://nektosact.com/usage/index.html) and
[runner limitations](https://nektosact.com/not_supported.html).

The current preparation passed host checks on macOS and the complete act
workflow on native Linux ARM64 with Neovim 0.12.6. Hosted AMD64 and macOS GitHub
runners still need their first remote run. No GitHub token is required by the
plugin tests.

## Review Expectations

Keep the provider protocol, plan validation and Git execution boundaries clear.
Fixes that affect staging or execution need a regression test in a temporary
repository. Include the plugin revision, Neovim version and a minimal synthetic
reproduction in bug reports. Do not include private diffs or credentials.

Use Conventional Commit messages. Describe behavior and validation in pull
requests. Do not disable commit hooks, signing or plan validation as a workaround.

The project uses the [MIT license](LICENSE). Contributions are provided under
the same license. Public publication remains a separate maintainer decision.
