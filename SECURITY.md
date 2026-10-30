# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

Use GitHub's private vulnerability reporting: on [BCYAYAY14/bluebox](https://github.com/BCYAYAY14/bluebox), open the **Security** tab and choose **Report a vulnerability**. Only the maintainer sees the report, and the fix can be discussed and credited there before anything is public.

Please include:

- the Bluebox version (Settings › About) and platform (iPhone, iPad or Mac, and the OS version);
- what an attacker needs (a link the user opens, a malicious add-on, a Supabase project they control, a position on the network, …);
- steps to reproduce, and what happens;
- anything you used to test it (a fake add-on or backend is ideal).

You should get an answer within a week. Fixes ship in the next release, and the release notes say what was fixed once users can update.

## Supported versions

Only the latest release gets security fixes. Bluebox updates itself on the Mac and through the AltStore, SideStore and FlareStore source on iPhone and iPad.

## Scope

In scope: the app (iPhone, iPad, Mac), the Mac updater, the Supabase SQL in `Bluebox/Backend/supabase`, and how Bluebox talks to add-ons, debrid services, Jellyfin, Trakt and subtitle sites.

Out of scope: problems in a third-party add-on, debrid service or Supabase itself (report those to their owners), and content you choose to stream.

## Verifying a Mac download

Every Mac release is signed with the self-signed **Bluebox Open Source** certificate, SHA-1 `8DA48EE5DF68786C0B40A9D6689453892A1F75D0`. The built-in updater installs only an app signed with it. To check a download by hand:

```bash
codesign -v --strict --deep -R='identifier "app.bluebox.Bluebox.mac" and certificate leaf = H"8da48ee5df68786c0b40a9d6689453892a1f75d0"' /Applications/Bluebox.app
```

The certificate isn't notarized by Apple (that needs a paid Developer ID), so macOS asks before the first launch.
