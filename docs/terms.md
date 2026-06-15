# Terms

Youty is a personal user-agent. It loads the same public web pages your
browser would, parses what it finds, and saves the result to a folder on
your Mac. AI search over what you save runs 100% on-device; nothing about
that result is ever sent anywhere.

These terms describe what you can expect from Youty and what is on you.
They are deliberately short.

## What Youty does

- Fetches the publicly-accessible page for a URL you give it (YouTube,
  Instagram, TikTok).
- Extracts transcripts, frames, and metadata from that page.
- Writes the result to the vault folder you pick.
- Indexes the vault locally so AI assistants you run can search it.

## What you can do with the output

The output — markdown notes, JPEG frames, the search index — is yours.
Read it, archive it, feed it into your own AI workflow, write a book
from it. Youty makes no claim on what you save.

## What you are responsible for

Each platform Youty supports has its own terms of service that govern
how its content may be accessed and used. By telling Youty to save a
video, you are asking Youty — your personal user-agent — to load and
parse a page on your behalf. You are responsible for whether that
access, and any subsequent use you make of the saved content, is
consistent with the terms of the platform that served it.

Specifically:

- **Instagram and TikTok** rate-limit, restrict, and may suspend
  accounts that exhibit automated-access patterns. Saving videos through
  Youty — which uses each platform's public web pages — may contribute
  to such patterns and could affect your account standing. Account
  consequences are between you and the platform. Youty cannot and does
  not provide indemnification.
- **YouTube's Terms of Service** restrict the extraction of content
  from its service. By using Youty to save a YouTube video, you are
  acknowledging this restriction and choosing to proceed on your own
  responsibility. The same caveat applies to every other platform Youty
  supports today and may support tomorrow.

Youty is built on the same legal posture as long-standing personal
user-agents like yt-dlp and IINA: a tool that loads pages you are
already entitled to view, and lets you decide what to do with what
those pages serve.

## What Youty does not do

- Phone home. There is no analytics, no telemetry, no crash reporting.
- Send your vault contents to Youty's authors or to anyone we control.
- Bypass paywalls, DRM, age gates, or any access controls. If a page
  is blocked for you in a browser, Youty cannot see it either.
- Re-host, distribute, or share any saved content. The vault is on
  your Mac; what leaves it leaves through your action.

For the complete network-traffic picture, see `docs/privacy.md`.

## No warranty

Youty is provided as-is, without any warranty of any kind. The authors
do not guarantee that it will work for any particular URL, that
extraction will continue to work after platforms change their pages, or
that the output is fit for any purpose. Use at your own risk.

## Liability

To the maximum extent permitted by applicable law, the authors are not
liable for any direct, indirect, incidental, special, or consequential
damages arising from your use of Youty — including but not limited to
loss of data, loss of access to any platform account, or any harm
arising from your use of saved content.

## Licence

Youty's source code is licensed under the MIT license. The bundled
third-party components carry their own licenses; see
`THIRD_PARTY_LICENSES.md` for the canonical list.

## Changes

These terms may be updated to reflect changes in Youty itself, in the
platforms Youty supports, or in the legal landscape around personal
user-agents. The latest version always lives at `docs/terms.md` in the
public repository.

## Contact

Bug reports and questions go through GitHub Issues; security
disclosures use GitHub's private security advisories. See `SECURITY.md`
for the disclosure process. The authors do not maintain a public
support email.
