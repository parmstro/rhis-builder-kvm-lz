# MiniRHIS Network Rules

Purpose: single source of truth for network intent while editing scripts/roles.

## Rule 1: Internal service plane only

- All product services exposed to admins/users must bind to and be advertised on the internal network: 10.168.0.0/16.
- Primary UI and API endpoints:
  - Satellite: https://10.168.x.x/
  - AAP: https://10.168.x.x:9443/
  - IdM: https://10.168.x.x/ipa/ui/
- SSH access for managed nodes must use internal addresses (10.168.x.x).

## Rule 2: External/NAT plane is egress-only

- The 192.168.122.0/24 network on eth0 is external/NAT and is not for internal user-facing service endpoints.
- Use external/NAT for outbound connectivity only (examples):
  - access.redhat.com
  - console.redhat.com
  - cdn.redhat.com
  - quay.io
  - registry.redhat.io

## Rule 3: Satellite provisioning services stay internal

- DNS, DHCP, TFTP, PXE, and provisioning subnet ownership are internal-network responsibilities.
- Satellite provisioning interface and service addresses must remain on internal 10.168.0.0/16.

## Rule 4: Hostname and endpoint messaging

- Any generated banner/header/MOTD/help text must prefer internal FQDN/IP endpoints.
- Do not advertise 192.168.122.x endpoints as primary product access URLs.

## Rule 5: Change-control checks for future edits

When modifying scripts/roles, verify all of the following:

- No hardcoded product UI endpoint on 192.168.122.x
- AAP endpoint includes :9443 when appropriate
- Internal addresses remain the default for HOST_INT_IP, SAT_IP, AAP_IP, IDM_IP paths
- New docs/examples do not reintroduce external-only address guidance for service access

## Rule 6: CMDB secondary endpoint target

- Preferred secondary CMDB endpoint target: 10.168.128.4.
- If/when implemented, keep this endpoint internal-only and document ownership/interface on Satellite.
