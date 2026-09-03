# Security

## Reporting a vulnerability

Two projects meet in this repository, and they take reports in different places.

**This packaging** — the snapcraft recipe, the wrapper scripts, the hooks, the
confinement profile. Report it privately through GitHub's private vulnerability
reporting on this repository: *Security* → *Report a vulnerability*. Please do
not open a public issue or pull request for it.

**Apache Cassandra itself** — anything in the software this snap packages.
Report it to the ASF Security Team at `security@apache.org`, following the
process at <https://www.apache.org/security/>. Do not open a public issue for it,
here or upstream.

If it is not obvious which side a problem falls on, report it here and it will be
forwarded.

## Confinement

The snap is strictly confined. The daemon does not run as root: `_daemon_` is
declared as a `system-username`, and `start-wrapper.sh` execs Cassandra through
`setpriv --clear-groups --reuid _daemon_ --regid _daemon_`. The same applies to
the `bin/` tools exposed as apps.

Beyond `network` and `network-bind`, the interfaces requested are all
observational (`hardware-observe`, `system-observe`, `mount-observe`) or needed
to signal Cassandra's own processes (`process-control`). Logs are exposed to
other snaps read-only, through a `content` slot over
`$SNAP_COMMON/var/log/cassandra`.

## JRE hardening

The snap does not ship a JDK. It builds a minimal runtime with `jlink`,
containing only the modules Cassandra needs, which keeps a good deal of code —
and several historically awkward subsystems — out of the image entirely. Notably
the image has `java.compiler` (the `javax.tools` API, which the bundled ECJ
implements) but not `jdk.compiler`, so there is no `javac` in the snap.

The module list was derived by running `jdeps` over the release's own jars,
and adding only the essential missing runtime modules.

```bash
jdeps --multi-release 17 --ignore-missing-deps --print-module-deps \
  --class-path 'lib/*' lib/*.jar
```

### Trust store

`jlink` takes `cacerts` from `java.base.jmod`, which carries upstream OpenJDK's
own CA bundle: the JDK's `lib/security/cacerts` symlink into
`/etc/ssl/certs/java` is **not** followed. The recipe therefore overwrites the
generated `cacerts` with the distro trust store, so the runtime tracks Ubuntu's
CA set and there is exactly one trust store in the snap.
