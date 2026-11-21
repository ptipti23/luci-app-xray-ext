# Contributing to Xray Extender

Thank you for taking the time to help improve Xray Extender. Bug reports, careful testing, documentation improvements, and focused pull requests are welcome.

## Before opening an issue

- Check existing issues and discussions for a similar report or request.
- Use the latest available project version when practical, and mention the exact version you tested.
- For a bug, try to identify the smallest set of steps that reproduces it.
- Never include passwords, UUIDs, subscription URLs, private keys, tokens, or other sensitive values in an issue or pull request. Sanitize logs and configuration excerpts before sharing them.

## Bug reports

A useful bug report includes:

- OpenWrt version and target/device architecture.
- Xray version.
- `luci-app-xray` version, if relevant.
- Xray Extender version.
- What you expected to happen and what actually happened.
- Reproduction steps and relevant sanitized logs.
- Whether the problem also occurs with custom hooks or other non-default configuration.

Please distinguish between problems in Xray itself, the upstream LuCI Xray application, OpenWrt, and Xray Extender when the evidence makes that possible. It is fine not to know which component is responsible; include the observations instead of guessing.

## Feature requests

Describe the problem the feature would solve, the expected behavior, and any alternatives you have considered. A concrete use case is more helpful than prescribing a particular implementation.

## Pull requests

Keep changes focused. A pull request should explain:

1. What changed.
2. Why the change is needed.
3. Which components or files are affected.
4. How the change was tested.
5. Any compatibility implications or known limitations.

Prefer small, reviewable changes over unrelated cleanup. Preserve existing behavior unless a change is intentional and documented.

## Technical guidelines

- Follow the existing Lua, JavaScript, C, shell, and ucode style in the files you edit.
- Keep OpenWrt's constrained environments in mind. Avoid adding heavyweight runtime dependencies without a clear reason.
- Check Lua syntax with the available Lua compiler or interpreter where applicable.
- Build the package for the relevant OpenWrt target when possible.
- Test changes on a device or a representative test environment before claiming runtime compatibility.
- Keep upstream compatibility patches narrow and guarded where appropriate.
- Prefer documented configuration options and supported extension hooks over hard-coded changes to generated configuration when that is practical.
- Do not include temporary files, generated build output, device-specific configuration, or secrets in commits.

## Compatibility and testing

Xray Extender interacts with OpenWrt, LuCI, and Xray. A change that works on one target or Xray version may not work on another. State the exact environment tested and avoid implying broader compatibility than the tests establish.

For changes involving daemon behavior, ubus/RPC, gRPC, outbound generation, subscriptions, or failover, describe the relevant test path and include sanitized logs when useful.

## Licensing

The repository README currently contains a WTFPL notice. There is no separate `LICENSE` file. If you need clarification about the intended licensing of a contribution, please contact the maintainer before submitting it.
