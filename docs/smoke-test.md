# Manual Smoke Test

`scripts/check.sh` covers the static surface only; it cannot exercise Colima,
SSH, or Docker. Run this on a Mac (Apple Silicon) before merging changes that
touch lifecycle, provisioning, SSH, or services. Use an account without devbox
state, or destroy the VM first.

## Static gate

```sh
scripts/check.sh     # must end with "All checks passed."
```

## Clean install

Before connecting, add `Include ~/.ssh/devbox.conf` at the top of
`~/.ssh/config`. If `~/.local/bin` is not on your `PATH`, use `./devbox` or add
it to `PATH` before running the commands below.

```sh
./devbox init           # answer the prompts; installs the devbox command
devbox start
devbox status
devbox connect        # workspace at /home/devbox/workspace
devbox exec id -un    # devbox
devbox exec sudo -n true   # must fail
devbox exec id -nG    # must not list docker
devbox auth status
devbox db info
```

Confirm:

- `ssh devbox true` works and `ssh -G devbox | grep -i forwardagent` reports
  `no`.
- Inspect the guest's mounts, not the host mount table:
  `devbox exec findmnt -T /home/devbox` and
  `devbox exec findmnt -T /home/devbox/workspace` should show the home on the
  Lima data disk rather than the small guest root filesystem.
- Confirm the guest has no host-shared filesystem mounts:
  `devbox exec bash -c 'if findmnt -rn -t virtiofs,9p,fuse.sshfs | grep -q .; then exit 1; fi'`.
- The guest cannot read the staged service credentials:
  `devbox exec cat /var/lib/devbox/services/env` must fail.

The guest keeps ordinary network access and can reach host-gateway services
unless the host/network is separately restricted. Agent host-boundary guidance
is policy, not network enforcement; ordinary external network use is allowed.

## Services on demand

```sh
devbox services status   # no containers running
devbox services start
devbox services status   # postgres and valkey healthy
devbox exec bash -c 'exec 3<>/dev/tcp/127.0.0.1/15432'
devbox services stop
devbox services status   # stopped again
```

After `devbox stop` and `devbox start`, confirm the services are still stopped
until `devbox services start` is run.

## Re-converge and teardown

```sh
grep -q '^Include ~/.ssh/devbox.conf$' ~/.ssh/config
devbox stop
devbox start              # provisioning is current; SSH alias is refreshed
devbox destroy            # type "devbox" to confirm
grep -q '^Include ~/.ssh/devbox.conf$' ~/.ssh/config  # persistent Include remains
[ ! -e ~/.ssh/devbox.conf ]                          # managed file removed
```

On an existing VM, run `devbox provision` once and confirm the readiness checks
pass and `ssh devbox true` still works.

The host scripts run under macOS `/bin/bash` 3.2, which CI does not cover, so
exercise `devbox init`, `devbox exec echo -t`, `devbox connect`, and
`devbox auth status` on the Mac as part of this run.

Host files are untouched by `devbox destroy`; the workspace and guest
credentials are gone with the VM.
