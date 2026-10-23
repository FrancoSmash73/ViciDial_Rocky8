# Apache config (Oliver, applied 2026-10-22)

Reference copies of the live `/etc/httpd` files; the repo does not deploy them (Part 4 only edits stock `ssl.conf` cert paths).

- `vicidial.conf` -> `/etc/httpd/conf.d/vicidial.conf` (:80 vhost, logging only + `Include`)
- `vicidial-common.inc` -> `/etc/httpd/vicidial-common.inc` (shared Alias/Directory blocks for ViciDial, HulkPhone, CRM, portal)
- `ssl.conf.campaignvoiceservices.diff` -> changes to stock `/etc/httpd/conf.d/ssl.conf` (:443 vhost): Let's Encrypt cert `campaignvoiceservices.com`, ServerName/Alias, DocumentRoot, `Include` of the shared file, redacted `vicidial_ssl_access.log`, `TransferLog` disabled and `ssl_request_log` made conditional (both logged password GET params).

Cert: `certbot certonly --webroot -w /var/www/html/campaignvoiceservices -d campaignvoiceservices.com -d www.campaignvoiceservices.com --cert-name campaignvoiceservices.com`
(`callbakz.ddns.net` excluded: resolves to the relay's nginx, HTTP-01 cannot validate from here.)
