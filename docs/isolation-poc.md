# Experimental Isolation POC

`devbox isolation-poc` is an opt-in Phase 1 experiment. It does not change the
normal `devbox` profile, its mounts, Docker context, SSH alias, configuration,
or data. It creates only the separate Colima profile `devbox-isolation-poc` and
uses a separate Docker CLI configuration for its Colima context.

The command is deliberately fail-closed: before it renders, creates, or starts
that profile, it requires the following `.env` values and validates them:

```sh
export DEVBOX_ISOLATION_POC_INTERFACE="en0"
export DEVBOX_ISOLATION_POC_DNS="1.1.1.1,1.0.0.1"
export DEVBOX_ISOLATION_POC_DENY_TARGETS="10.0.0.10:443,10.0.0.11:8443"
```

It requires exactly Colima 0.10.3. It also requires `COLIMA_HOME` to be unset
or `$HOME/.colima`, and `LIMA_HOME` to be unset or
`$HOME/.colima/_lima`. Every Colima invocation pins both generated Lima state
to that latter path and Docker CLI state to the POC-specific configuration, so
neither can be redirected to normal devbox state.

`DEVBOX_ISOLATION_POC_INTERFACE` must name an existing macOS interface.
`DEVBOX_ISOLATION_POC_DNS` is a comma-separated list of routable IPv4
resolvers and cannot reuse a resolver currently reported by macOS.
`DEVBOX_ISOLATION_POC_DENY_TARGETS` is a nonempty comma-separated list of
IPv4-and-TCP-port pairs. Do not use an arbitrary closed port: each target must
be a service known to be reachable from an unfiltered reference host, but
denied to the POC by the external network policy.

## External prerequisites

This POC does **not** configure a firewall, VLAN, switch, router, or cloud
network policy. An operator must arrange the bridged interface and enforce the
deny policy outside the VM. In particular, the selected VLAN/firewall policy
must permit DHCP, the configured DNS resolvers, and public HTTPS egress while
blocking the exact TCP deny targets. Verify that policy independently before
using a successful TCP refusal/timeout as evidence.

Colima may ask for administrator authorization to install/use its supported
`socket_vmnet` bridge helper. Do not substitute unsupported Lima or Colima
configuration to bypass that prompt.

## What it configures and checks

The POC uses Colima 0.10.3's supported `network.mode: bridged`,
`network.interface`, `network.address`, and `network.dns` settings with a VZ
VM and Docker runtime. It explicitly disables auto activation, Colima SSH
configuration edits, SSH-agent forwarding, and Colima port forwarding. It
omits `mounts` entirely: in Colima 0.10.3 an explicit `mounts: []` means mount
the host home directory, while an omitted value produces no host mount.

Run the experiment and its checks together:

```sh
devbox isolation-poc
```

To re-run checks against an already-running POC without creating or starting
anything, use:

```sh
devbox isolation-poc check
```

The checks inspect the generated profile and Lima configuration, then verify
inside the guest that no virtiofs/9p/SSHFS host mount exists, the guest has a
non-loopback IPv4 route, only the configured DNS resolvers appear in
`/etc/resolv.conf`, public HTTPS works, every supplied deny target rejects a
TCP connection, and Docker is running.

## Strict result on Colima 0.10.3

Colima 0.10.3 always adds Lima's `user-v2` network to its generated Lima
configuration, even when `network.mode: bridged` adds the external bridge.
There is no supported Colima 0.10.3 configuration or CLI option that removes
that network. The POC detects it and fails its final strict precondition rather
than claiming isolation. The other guest checks still run to expose their
results, but they do not turn this into a passing isolation result.

The generated-Lima topology check is specific to Colima 0.10.3; the POC
rejects all other Colima versions rather than applying this literal `user-v2`
check to an unvalidated topology.

This is an experimental feasibility result, not a replacement for the normal
development VM or a claim of external firewall enforcement.
