---
packages:
  hippo: minor
---

### Apps connect on their own network

Apps join the `hippo-clients` network and reach Postgres through HAProxy (`haproxy:5000` for the primary, `:5001` for the replicas). The cluster network `hippo` is no longer attachable, so apps can't reach etcd or Patroni's REST API, and Patroni only accepts state-changing REST calls (restart, failover, configuration, …) from cluster members.

Both networks are encrypted: traffic between nodes goes over IPsec, so IP protocol 50 (ESP) must be allowed between them.
