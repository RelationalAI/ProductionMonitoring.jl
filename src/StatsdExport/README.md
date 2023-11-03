# StatsdExport

This package contains the StatsdExporter backend to be used with the `Metrics` package.

`Metrics` allows you to define metrics registries which can be used to instrument code. To expose the tracked metrics, they have to be sent to a backend. The StatsdExporter is used to periodically send UDP messages to the statsd backend.

Please also cf. `Metrics` for more information and detailed usage instructions.
