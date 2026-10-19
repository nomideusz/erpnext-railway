# Deploy and Host ERPNext 16 on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/erpnext-16?referralCode=sLjDXb&utm_medium=integration&utm_source=button&utm_campaign=erpnext-16)

[ERPNext](https://erpnext.com/) is the open-source ERP built on the Frappe framework: accounting, invoicing, inventory, buying and selling, manufacturing, projects, CRM and a website, all in one database with no per-user fees. This template runs ERPNext v16 the way `bench setup production` runs it on a server, with nightly backups and upgrades handled for you.

## About Hosting ERPNext 16

The stack is three pieces: ERPNext, a private MariaDB, and a Railway bucket for backups.

- **Everything Frappe runs, in one service.** nginx on the public port, gunicorn, the socket.io realtime server, background workers, the scheduler, and Redis for the cache and job queue. They all need the same `sites/` folder, and a Railway volume attaches to one service, so they run together. Live updates, progress bars and notifications work out of the box, and jobs still queued at a redeploy run after it.
- **Locked down from the first second.** The site is created on first boot with a generated `Administrator` password, never `admin`/`admin`. Public sign-up is off, MariaDB has no public proxy, and the realtime server only accepts connections from your own domain.
- **Nightly backups.** Every night at 03:00 UTC the database, the public and private files and the site config go to the bundled bucket, one tar per weekday, so the last 7 days are always there. `erpnext-restore` puts one back, into this deployment or a new one.
- **Upgrades that migrate themselves.** The first boot of a new ERPNext version backs up the database and runs `bench migrate` before serving the site.

## Common Use Cases

- Accounting, invoicing and stock for a small business, with no per-user fees
- Manufacturing with BOMs, work orders and job cards for a workshop or small factory
- A self-hosted ERP to evaluate ERPNext as an Odoo alternative, with real backups from day one

## Dependencies for ERPNext 16 Hosting

- MariaDB 11.8 (included, private network only)
- A Railway bucket for backups (included)

### Deployment Dependencies

- [ERPNext documentation](https://docs.frappe.io/erpnext)
- [Template source on GitHub](https://github.com/two-workspaces/erpnext)

### Implementation Details

**Sign in** at your ERPNext service's Railway domain as `Administrator` with the `ERPNEXT_ADMIN_PASSWORD` value from the ERPNext service's Variables tab. The first boot creates the site, so give it a minute or two. The setup wizard then asks for your country, currency, company and fiscal year, and loads the matching chart of accounts. Change the password afterwards; the variable is only read on first boot.

**Memory.** About 400 MB for ERPNext and 250 MB for MariaDB once set up. On plans that give a service less than 2 GB, the template runs 1 web worker (4 threads) and 1 background worker, and it works within 512 MB. For more users, raise `ERPNEXT_WEB_WORKERS` and `ERPNEXT_BG_WORKERS`.

**Backups and restore.** Backups appear in the Backups bucket as `erpnext-Mon.tar` … `erpnext-Sun.tar`. For an extra one before a risky change, run `erpnext-backup` in a `railway ssh` session on the ERPNext service. To restore, run `erpnext-restore Mon` there (or `erpnext-restore /path/to/backup.tar`), then restart the service. It replaces the site's database and files and brings over the site's encryption key, so saved passwords (email accounts, integrations) keep working in a new deployment too.

**Email.** Railway only allows outbound SMTP on the Pro plan, and ERPNext sends mail over SMTP. On Pro, add an outgoing account under Email Account. On other plans ERPNext can't send email, so set new users' passwords yourself (User → Set New Password) instead of emailing invitations.

**Custom domain.** Add it in the ERPNext service's Settings → Networking, then set `ERPNEXT_URL` to `https://your.domain` so links in emails and PDFs use it.

**Other Frappe apps.** The image has Frappe and ERPNext only. Frappe's Docker setup installs apps such as HRMS when the image is built, not at runtime, so they need a custom image: build one with frappe_docker's `apps.json` and put it in this repo's `FROM` line.

## Why Deploy ERPNext 16 on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying ERPNext 16 on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
