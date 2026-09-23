# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.4] - 2026-09-23

### Fixed

- **CI had never run the restore script.** The test restored with its own
  copy of the commands. The script read `DATA_PATH` and `DATA_BACKUPS_PATH`
  from the shell that ran it rather than from `.env` or the stack, so a path
  set in `.env` was not the one it listed or cleared, and it cleared with
  `rm -rf dir/*`, which leaves every dotfile of the newer state in place. It
  now takes every path and name from the running backups container, accepts
  the backup file name as an argument, starts the application again whatever
  happens, and CI runs it: a file written before a backup and deleted after it
  must be back once that backup is restored.

### Changed

- **The freshness check has its own workflow, Pin Freshness.** It ran inside Deployment Verification, whose badge is the one at the top of this README. Across the fleet, nine red runs in ten were a pin one version behind - which the fleet's triage moves within the day - and a reader cannot tell that from a stack that does not boot. The badge now says whether the stack boots. The job itself is unchanged.

## [1.0.3] - 2026-09-21

### Security

- **`traefik:3.7` was rebuilt upstream**; the pin moved from `sha256:1c32e7c36820…` to `sha256:24841fe2de73…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.2] - 2026-09-19

### Security

- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:365499d9dccb…` to `sha256:5291449c3df7…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.1] - 2026-09-18

### Changed

- **`codeberg.org/forgejo/forgejo:16.0.4` moved to `codeberg.org/forgejo/forgejo:16.0.5`.** The freshness check reported the lag; the deploy job booted the stack on the new image before this landed.

### Security

- **`traefik:3.7` was rebuilt upstream**; the pin moved from `sha256:f86a2cab1b5c…` to `sha256:1c32e7c36820…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.
- **`alpine:3.22` was rebuilt upstream**; the pin moved from `sha256:14358309a308…` to `sha256:365499d9dccb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.0.0] - 2026-09-10

First release. A production deployment of Forgejo behind Traefik, built to the
fleet standard established in
[keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Added

- **Forgejo 16.0 behind Traefik with Let's Encrypt TLS.** Three images pinned
  by `tag@sha256:<digest>` in the compose `x-images` block: the server,
  Traefik, and a plain alpine for the backups sidecar.
- **No web installer, and no default password.** Forgejo ships an installer and
  most compose files leave it on, which means whoever reaches a new hostname
  first configures the instance and becomes its administrator. On a public IP
  that is minutes, not days: scanners watch certificate transparency logs.
  `INSTALL_LOCK` is set, the admin is created from the CLI, and CI asserts that
  `/install` stays closed. Registration is disabled and nothing is visible
  without signing in, so this starts private and opens by decision.
- **A `git push` that is not cut off by the proxy.** Traefik gives an entry
  point 60 seconds to read an entire request body by default, and a first push
  of a large repository over a domestic uplink goes past that; packing one
  server-side can likewise take minutes before the first byte of the response.
  Both timeouts are lifted here, and the idle timeout is raised to ten minutes.
  Deliberately absent: a Buffering middleware. Traefik streams bodies unless
  you attach one, so attaching it with zero limits would turn buffering on with
  no size ceiling — the opposite of the intent. Measured on this stack against
  a response that takes four seconds to produce: 0.03s to the first byte
  without it, 4.15s with it.
- **A `git push` proven in CI, not asserted.** The deploy job creates an admin
  from the CLI, creates a repository through the API, pushes a commit carrying
  a 5 MB blob over HTTPS through Traefik, requires the API to report that exact
  commit on `main`, and then clones it back and checks that the commit and the
  whole blob came with it.
- **SQLite, deliberately**, against the fleet's own PostgreSQL pattern. It is
  officially supported and it is what upstream tests; choosing it removes a
  container, a second image pin, and a database version that would have to stay
  in lockstep with whatever takes the dumps. The cost is stated rather than
  hidden: SQLite is one writer at a time, and the README says where the line
  is and how to cross it.
- **Git over SSH as an opt-in override file.** The base stack serves git over
  HTTPS, which needs no second published port and survives a proxy that
  terminates TLS. `git-over-ssh.override.yml` turns the built-in server on for
  people who want public keys, published on 2222 rather than 22 — port 22
  belongs to the host's own sshd — and spells out the difference between
  `SSH_LISTEN_PORT` and `SSH_PORT`, which is the setting people get wrong.
- **A backup loop that reads its own archive back before naming it a backup.**
  Each cycle writes `.partial`, verifies it with `tar -tzf`, and only then
  renames. BusyBox tar returns exit code 1 both for "a file changed while I
  read it" and for "I could not write the output at all", so the exit code
  alone would rename an empty file into place and log it as OK.
- **A restore script that stops the server first**, because SQLite is written
  on every push and every page view.
- **Deployment Verification workflow.** shellcheck and actionlint, Trivy scans
  of all three images, a daily freshness check against Codeberg, and the deploy
  job described above followed by eight backup and restore scenarios.
- **`update.sh`**, container hardening on every service, resource limits and
  reservations on all three, and a sixty-second `stop_grace_period`: SQLite
  tolerates a hard kill far worse than it looks, and a push interrupted
  mid-transaction can leave a repository the database references and the disk
  does not have.

### Notes

- **The database file must live under `/data/gitea`, and that is not
  cosmetic.** The image starts as root, creates `/data/git` and `/data/gitea`,
  chowns those two to the uid Forgejo then runs as, and leaves `/data` itself
  owned by root. A database path anywhere else under `/data` cannot be created
  by the process that needs it: the container comes up, retries ten times with
  `mkdir /data/…: permission denied`, and never turns healthy. It works on a
  bind mount whose whole tree was chowned by hand, which is exactly why it is
  written down — a setting that is fine on the maintainer's host and broken on
  a named volume is the kind that ships. Found by this template's own first
  boot.
- **The health probe isolates the first `status` before matching it.**
  `/api/healthz` reports one overall verdict and then one per component;
  matching `"pass"` anywhere in that document goes green on a body whose top
  line reads `fail` and whose cache happens to be fine. CI asserts the overall
  status and `database:ping` by name.
- **The post-restore check asks for a repository, not for a status code.**
  Forgejo starts perfectly well on an empty database — that is what a fresh
  install is — so a check that only asks whether it answers would pass a
  restore that lost everything.
- **An archive taken a moment before a push cannot contain what the push
  delivered.** The first CI run failed on exactly that: the newest archive on
  disk predated `receive-pack` by two seconds, and a test that asked the newest
  archive for the repository reported it missing. The workflow now stamps the
  backup directory after the push and waits for the next archive, and
  `/data/git/repositories` is asserted only there — the generic suite runs on
  instances that legitimately have no repositories yet, where that directory
  does not exist.
- **The commit is not in the database the instant `git push` returns.** The
  branch is written a moment later, and asking immediately gets a null back
  from a push that entirely succeeded. CI waits rather than calling that a
  failure.
- **There is no Buffering middleware, and that is the point.** The first draft
  of this file carried one with every limit set to `0`, on the belief that
  Traefik buffers by default and that zero turns it off. Both halves are wrong:
  Traefik streams bodies unless a Buffering middleware is attached, attaching
  one is what turns buffering on, and `0` on its limits means *no size
  ceiling*. Measured against a response that takes four seconds to produce,
  0.03s to the first byte without it and 4.15s with it. It never reached a
  release here; it did reach one in the Jellyfin template the same day, fixed
  there in v1.0.1.

[Unreleased]: https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
