# Product identity and compatibility

The current server-backed product in this repository is **Aurelia**. Its retired
name was Aurelia Home. **Aurelia Classic** is a separate local-only reference
application; it is not this server or a target for these migrations.

Do not rename persistent identifiers to match a cosmetic name change. The
following old values are compatibility inputs, not names to show in the UI:

- Legacy server configuration keys and environment variables are read after the
  current keys, so existing host configuration remains usable.
- The legacy Bonjour service type remains discoverable alongside the current
  service type, allowing connection to older servers.
- The legacy Keychain service/access group is needed to migrate stored profiles
  securely. A successfully migrated profile is removed from the old service;
  disconnect removes both representations rather than resurrecting the fallback.
- The legacy server data directory/database name is a migration source. Classic
  data is never read, copied, or modified by this migration.

`scripts/verify-product-names.sh` rejects retired names outside the specific
compatibility files and this document. Update its allowlist only for a necessary,
reviewed compatibility path, not to permit old labels in new UI or documentation.
