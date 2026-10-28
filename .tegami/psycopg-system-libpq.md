---
packages:
  hippo: patch
---

### Patroni uses the system libpq

Patroni's driver is the pure-Python `psycopg` on Debian's `libpq5` instead of the `psycopg-binary` wheel, which bundled its own copies of libpq, OpenSSL, Kerberos and LDAP built for CentOS 7, without license metadata.
