# Security policy

## Reporting a vulnerability

Found something concerning — an API-key leak, a privilege-escalation
path, a way to execute code via a saved bundle, anything in that
neighbourhood?

Use GitHub's **private security advisory** feature:
<https://github.com/legetdev/youty/security/advisories/new>. This
creates a confidential thread visible only to repository maintainers,
keeps the report off public Issues, and gives us a structured place to
coordinate a fix and a CVE if warranted. Please do not open a public
GitHub issue for security topics.

I'll acknowledge within 72 hours and aim to ship a fix within 14 days
for anything critical, longer for lower-severity issues.

## What's in scope

- The Mac app, the `youty` CLI, the Share Extension, the MCP server.
- Anything that touches the user's Keychain entries, cookies, or vault
  contents.
- Anything that lets a saved bundle (`video.md` or a JPEG) trigger
  unintended behaviour when opened by the app, CLI, or MCP server.

## What's not in scope

- Bugs in macOS, FFmpeg, or any other third-party software Youty links
  against — please report those upstream.
- Issues with Instagram, TikTok, or YouTube themselves.
- Social-engineering or phishing scenarios that don't involve a Youty
  code path.

## Disclosure

After a fix ships I'll credit you in the release notes by name or
handle if you'd like, or quietly if you'd rather.
