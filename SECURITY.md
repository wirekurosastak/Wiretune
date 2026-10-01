# Security policy

## Reporting a vulnerability

Please do not report security problems in public issues. Use GitHub's private vulnerability reporting for this
repository (Security tab → "Report a vulnerability"). Include the affected version or commit, a description, and
steps to reproduce. You will get an acknowledgement, and the fix will be coordinated with you before disclosure.

## Supported versions

Only the latest release (or the default branch, before the first release) receives security fixes.

## Scope and deployment notes

- The server speaks plain HTTP by design. Run it behind a TLS-terminating reverse proxy or on a private network
  (VPN); see the README section "Security notes".
- Audio and cover requests may carry the access token in the query string (`?token=`) for players that cannot
  send headers. Treat access logs of those endpoints as sensitive.
- The signing key for access tokens is stored in the server's database inside its data directory. Anyone who can
  read that directory can mint tokens, so restrict its permissions.
- The artist-picture lookup contacts `api.deezer.com` from the client; set `WIRETUNE_NO_ARTIST_PICTURES=1` to
  disable it.
