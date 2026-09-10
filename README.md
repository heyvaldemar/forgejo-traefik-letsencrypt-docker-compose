# Forgejo + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys Forgejo (self-hosted Git with issues, pull requests, packages and CI, community-governed and a fork of Gitea) behind Traefik with automatic Let's Encrypt TLS, with scheduled backups of the whole instance and a companion restore script.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose
cd forgejo-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create forgejo-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: FORGEJO_HOSTNAME, TRAEFIK_HOSTNAME,
#   TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.

# 4. Deploy
docker compose -f forgejo-traefik-letsencrypt-docker-compose.yml -p forgejo up -d

# 5. Create your account. There is no web installer and no default password.
docker compose -f forgejo-traefik-letsencrypt-docker-compose.yml -p forgejo \
  exec -u git forgejo forgejo admin user create \
  --admin --username YOUR_NAME --email you@example.com --random-password
```

Step 5 prints the password once. Sign in, change it, enable 2FA.

### Why there is no setup wizard

Forgejo ships a web installer, and most compose files leave it on. Between `up -d` and your first visit, whoever reaches the hostname first configures the instance and becomes its administrator — and a new hostname on a public IP is visited within minutes, by scanners that watch certificate transparency logs. `INSTALL_LOCK` is set here, so `/install` is closed before the first request arrives and the admin account is made from the CLI instead. CI asserts that the installer stays closed.

The same reasoning sets `DISABLE_REGISTRATION` and `REQUIRE_SIGNIN_VIEW`: this starts as a private instance, and opening either one is a decision you make, not a default you inherit.

### What success looks like

```bash
docker compose -f forgejo-traefik-letsencrypt-docker-compose.yml -p forgejo ps
curl -s "https://${FORGEJO_HOSTNAME}/api/healthz"
# {"status": "pass", … "database:ping": [{"status": "pass", …}]}
```

`ps` shows `forgejo` and `traefik` healthy, and `backups` running with no health check of its own.

### Common first-deploy issues

- **`mkdir /data/…: permission denied`, over and over, and the container never turns healthy.** Something is pointing a Forgejo path outside `/data/git` and `/data/gitea`. Those two are the only directories the image creates and hands to the uid it then runs as; `/data` itself stays root-owned. See the note below.
- **Clone URLs point at the wrong host.** `FORGEJO_HOSTNAME` is written into `ROOT_URL`, which is what every clone button and every notification link is built from. Changing it later invalidates URLs people already have.
- **A large push fails part way.** Traefik streams bodies and imposes no size limit, but its entry point gives you 60 seconds to send the whole request by default, and a big first push over a slow link exceeds that. This template sets that timeout to zero; if you have put another proxy or a tunnel in front, it has its own.
- **Cert issuance fails.** DNS has not propagated, or port 80 is not reachable from the internet.
- **Networks not found.** Step 2 was skipped.

## The database path is not a free choice

The compose file sets the SQLite file to `/data/gitea/forgejo.db`, and that is load-bearing. The image starts as root, creates `/data/git` and `/data/gitea`, chowns those two to the uid Forgejo runs as, and then drops to it. `/data` itself stays owned by root. A database path anywhere else under `/data` therefore cannot be created by the process that needs it: the container comes up, retries ten times with `mkdir /data/…: permission denied`, and the health check never turns green.

It works on a bind mount whose whole tree you chowned yourself, which is exactly why it is worth writing down. A setting that is correct on the maintainer's host and broken on a named volume is the kind that ships. (`gitea` in that path is a leftover from the fork, not a different code path.)

## SQLite, deliberately

Every other stateful template in this fleet runs PostgreSQL with a dump sidecar, which is right for an application with a hundred tables and concurrent writers. A Forgejo instance for a person or a small team is not that. SQLite is officially supported, it is what upstream tests, and choosing it removes an entire container, a second image pin to track, and a database version that has to stay in lockstep with whatever takes the dumps.

The cost is real and worth stating: SQLite is one writer at a time. At the point where several people are pushing simultaneously all day, move to PostgreSQL — Forgejo has a documented conversion, and the `FORGEJO__database__*` variables in the compose file are where it starts.

## Git over HTTPS, with SSH as an override

The base stack serves git over HTTPS through Traefik. That reuses the certificate that is already there, needs no second published port, and is the only transport that survives a tunnel or a proxy that terminates TLS in front of you.

What it does not give you is public-key authentication: over HTTPS git sends a token on every push, and a token in a credential helper is a password on disk. If you want keys, `git-over-ssh.override.yml` turns Forgejo's built-in SSH server on properly, published on 2222 rather than 22 — port 22 belongs to the host's own sshd, and taking it away from a machine you administer over SSH is a way to lose the machine.

```bash
docker compose \
  -f forgejo-traefik-letsencrypt-docker-compose.yml \
  -f git-over-ssh.override.yml \
  -p forgejo up -d
```

That file explains the one setting people get wrong: `SSH_LISTEN_PORT` is what the server binds inside the container, `SSH_PORT` is what Forgejo writes into the clone URLs it shows you, and the second must be the port on the **host** or every clone command the web UI offers is wrong.

## Forgejo Actions

Enabled, which means the feature exists in the UI; nothing runs until you register a runner, and adding one later needs no change to this file. The runner polls outward and waits for work, so it needs no inbound connection and no public address of its own — which is why it is safe to run one on a laptop.

## Updating

`./update.sh` moves this checkout to the latest release tag — a combination this repository's CI has booted, upgraded from the previous release on the same volumes, and proven with a real push — and then runs `docker compose up -d`. It refuses to cross a major version unattended, refuses to run over local changes, and names any variable that became required since your version before anything has moved. `./update.sh --dry-run` says what would happen.

If you run with the SSH override, add it to your own `up` command after the update: `update.sh` starts the base file only.

## Supply chain trust

Three images pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block:

- [`codeberg.org/forgejo/forgejo`](https://codeberg.org/forgejo/-/packages/container/forgejo/versions): the server, latest stable (16.0)
- [`traefik`](https://hub.docker.com/_/traefik): reverse proxy
- [`alpine`](https://hub.docker.com/_/alpine): the backups sidecar, which needs tar and nothing else

`git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. Nested defaults need Docker Compose v2.5 or newer (2022).

The daily `check-pin-freshness` job re-resolves each pin against its registry and compares the pinned Forgejo version against the latest release. It asks Codeberg, because that is where Forgejo is developed and there is no GitHub mirror to ask. Note the two spellings while reading that job: the git tags carry a leading `v` (`v16.0.4`), the container tags do not (`16.0.4`). GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Create the admin account immediately after deploy** (step 5 above) and enable 2FA on it.
- [ ] **Regenerate the Traefik dashboard hash.** The one in `.env.example` is a placeholder.
- [ ] **Host-mount the backup volume.** By default the archives land in a named volume: if the host dies, they die with it.
- [ ] **Decide about registration** before you hand the hostname out. It is closed by default.
- [ ] **Put something in front of it if the repositories describe your infrastructure.** A self-hosted git instance often ends up holding the configuration of the machine it runs on, and then a single login form is the only thing between that and the internet. An identity-aware proxy in front is the usual answer; note that it breaks `git clone` and `git push` over HTTPS unless you also issue a service token, while browsing works untouched.
- [ ] **Set a mailer** if you want notifications and password resets. Nothing here configures one, and Forgejo will not tell you it is missing until someone needs it.

## Backups and restore

The `backups` container archives `/data` on a loop — a 30-minute warm-up, a 24-hour interval, 7-day retention, all overridable in `.env`. That is the whole instance: the git repositories, the SQLite database holding users, issues, pull requests, tokens and webhooks, `app.ini`, avatars, attachments and the LFS store.

It is worth being clear about what this is protecting and what it is not. The commits are already on every machine that has cloned them — that is what git is. What only exists here is everything around them: who the users are, what the issues say, which pull requests were reviewed, and the instance configuration itself.

Each archive is written to a `.partial` name, **read back with `tar -tzf`**, and only then renamed. The read-back is not decoration: BusyBox tar, which is what an alpine image ships, returns exit code 1 both for "a file changed while I was reading it" and for "I could not write the output at all". Trusting the exit code alone renames an empty file into place and calls it a backup. This loop refuses to.

Restore with the interactive script:

```bash
chmod +x ./*.sh
./forgejo-restore-data.sh
```

It stops Forgejo first: SQLite is written on every push and every page view, and replacing the file under a running process is how a database ends up half old and half new. Afterwards, check **Site Administration → Repositories**, which reports any repository the database knows about and the disk does not.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults: the same values CI boots the stack under. What moves these numbers is not how many users you have — it is `git gc` on a large repository and the code indexer, both of which are bursty. Override any of them in `.env` and the override survives every `git pull`. If a service is OOM-killed, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`. The reverse proxy and the backups sidecar run with `cap_drop: [ALL]` and add back only what they need. Forgejo keeps the default capability set on purpose: its entrypoint sets up `/data` as root before dropping to an unprivileged uid, and a wrong guess there is a boot loop in production rather than a hardening win.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/forgejo-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck and actionlint, Trivy scans of all three pinned images, the daily freshness check, and a deploy job that boots the stack with ephemeral credentials.

That deploy job does not stop at a status code. It requires the health endpoint to report the **database** as passing by name, an anonymous visitor to be refused both the repository listing and the repository search API, `/install` to be closed, an admin to be creatable from the CLI, the API to accept that account, a repository to be created, **a real `git push` carrying a 5 MB blob to go through Traefik**, the API to report that exact commit on `main`, and a fresh clone to come back with the same commit and the whole blob. Then eight backup and restore scenarios, and finally Forgejo answering again on the data directory the restore replaced underneath it — with the repository that was pushed before the backup still in it, at the commit it was pushed at.

That last pair is the point. Forgejo starts perfectly well on an empty database; that is what a fresh install is. Asking only whether it answers would pass a restore that lost everything.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the smoke test. Three scenarios carry the weight. The archive must contain `data/git/repositories` and the SQLite database by name, not merely a directory. The restore roundtrip writes a file, waits for the archive that contains it, deletes it, restores, and asserts it came back. The failure test blocks the destination the loop is about to write to and asserts the loop says FAILED and leaves nothing behind that is named like a backup and does not open.

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

Run it on a staging copy, not on production: it stops the server and empties the data directory.

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- The web installer is locked before the first request; the admin account is created from the CLI.
- Registration is closed and nothing is visible without signing in, by default.
- The built-in SSH server is off unless you opt into the override file.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
