# Harbor Companion

Native Android companion for [Harbor](https://github.com/harborstremio/harbor) —
browse and control a Harbor instance over the LAN. A pure client of Harbor's
existing beta remote surface (`ws://<ip>:11471/api/remote`, proto 1); zero
changes to Harbor.

Flutter (stable) + Riverpod. Five-tab shell (Remote / Search / Home / My Stuff /
Profile) with a connect-first empty state on first run.

See `docs/agents/` for how the repo is run, and the issue tracker (#1, #13) for
the destination, spec, and decisions.
