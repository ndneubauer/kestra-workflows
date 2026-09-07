# Network inspector certificate authorities

Place PEM-encoded certificate-authority files used to verify the internal APIs
in this directory. They are mounted read-only into the Kestra container.

The preflight workflow looks for:

- `opnsense-ca.pem`
- `wazuh-ca.pem`
- `wazuh-indexer-ca.pem`

If a file is absent, the workflow uses the container's normal system trust
store. Do not place private keys, API keys, passwords, or client certificates
in this directory.
