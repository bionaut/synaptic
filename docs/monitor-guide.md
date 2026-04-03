# Synaptic Monitor

The Synaptic monitor is a dev-only browser UI for watching workflows, services,
instances, router calls, step activity, and recent events in one place.

It supports two modes:

- embedded inside an existing Phoenix app
- standalone on its own port, in the same BEAM node as the Synaptic runtime

The current MVP is:

- single-node only
- in-memory only
- read-only
- intended for development, demos, and workflow debugging

## What It Shows

The monitor currently helps you inspect:

- active and recent runs
- current step and step history
- router / agent call relationships
- service, instance, task reference, and workflow topology
- recent activity log with timestamps
- input and output payloads for steps and router calls
- waiting states, retries, and errors
- LLM and MCP summary events when telemetry is present

## Core Setup

Enable the monitor core in your host application config:

```elixir
config :synaptic, Synaptic.Monitor,
  enabled: config_env() == :dev,
  history_limit: 500,
  retention_ms: 300_000
```

That is enough to start the monitor runtime automatically when `:synaptic`
boots, because Synaptic starts monitor children from
`Synaptic.Application`.

If the monitor is disabled:

- `Synaptic.Monitor.snapshot/0` returns an empty snapshot
- `Synaptic.Monitor.recent_events/1` returns `[]`
- `Synaptic.Monitor.capture/1` becomes inert

## Embedded Phoenix Setup

Use this when your project already has a Phoenix app and you want the monitor
available under a dev route such as `/dev/synaptic`.

Keep the standalone viewer disabled:

```elixir
config :synaptic, Synaptic.Monitor.Web,
  enabled: false,
  port: 4050
```

Mount the embeddable LiveView in your router:

```elixir
if Application.compile_env(:my_app, :dev_routes) do
  import Phoenix.LiveView.Router

  scope "/dev" do
    pipe_through :browser
    live "/synaptic", Synaptic.Monitor.Web.Live
  end
end
```

Then start your app as usual:

```bash
mix phx.server
```

Open:

- `http://localhost:4000/dev/synaptic`

Notes:

- `Synaptic.Monitor.Web.Live` is only compiled when Phoenix LiveView is
  available.
- The monitor page subscribes to the Synaptic monitor bus and updates live.

## Standalone Setup

Use this when your app is headless or when you want the monitor on a dedicated
port.

Enable the standalone viewer:

```elixir
config :synaptic, Synaptic.Monitor.Web,
  enabled: config_env() == :dev,
  port: 4050
```

Then start your app normally. Synaptic will boot the monitor endpoint
automatically.

Open:

- `http://localhost:4050`

The standalone viewer runs in the same BEAM node as your application and reads
monitor state directly.

### Manual Start In IEx

If you prefer not to auto-start the standalone viewer, leave
`Synaptic.Monitor.Web` disabled and start it manually:

```elixir
{:ok, _viewer} = Synaptic.Monitor.Web.start_link(port: 4050)
```

This is useful when:

- you only want the monitor sometimes
- you are validating a Phoenix app like `tmp/voice_lab`
- you are experimenting in `iex`

## Existing Project Checklist

For an existing project using Synaptic:

1. Enable `Synaptic.Monitor` in `dev`.
2. Decide whether you want embedded or standalone mode.
3. If embedded, mount `Synaptic.Monitor.Web.Live` in your Phoenix router.
4. If standalone, enable `Synaptic.Monitor.Web` or start it manually.
5. Start the app and run a workflow.
6. Open the monitor and select the active run from the sidebar.

## Example: Existing Phoenix App

```elixir
# config/dev.exs
config :synaptic, Synaptic.Monitor,
  enabled: true,
  history_limit: 500,
  retention_ms: 300_000

config :synaptic, Synaptic.Monitor.Web,
  enabled: false
```

```elixir
# lib/my_app_web/router.ex
if Application.compile_env(:my_app, :dev_routes) do
  import Phoenix.LiveView.Router

  scope "/dev" do
    pipe_through :browser
    live "/synaptic", Synaptic.Monitor.Web.Live
  end
end
```

Then:

```bash
mix phx.server
```

Open `http://localhost:4000/dev/synaptic`.

## Example: Voice Lab

The internal example app at `tmp/voice_lab` already includes monitor config:

- `tmp/voice_lab/config/config.exs`

Run it:

```bash
cd tmp/voice_lab
iex -S mix phx.server
```

Then either:

- open the app and start using it, if standalone monitor is enabled in config
- or start the standalone monitor manually in IEx:

```elixir
{:ok, _viewer} = Synaptic.Monitor.Web.start_link(port: 4050)
```

Open:

- app: `http://localhost:4000`
- monitor: `http://localhost:4050`

## Payload Inspection

The monitor includes `Input` and `Output` buttons on:

- activity log events
- step history entries

Clicking either opens a modal with the captured payload.

Current payload coverage is best for:

- workflow step execution
- routed agent / service calls
- wait / resume / failure transitions

LLM and MCP events currently emphasize summaries and metrics more than raw
provider payloads.

## Troubleshooting

### The monitor page is empty

Check that:

- `config :synaptic, Synaptic.Monitor, enabled: true` is set for the current env
- the app was restarted after enabling it
- a workflow has actually been started

For long-running Phoenix sessions, changing config and running `recompile` is
not enough if the Synaptic application already booted without monitor children.
Restart the app.

### Standalone monitor does not start

The standalone endpoint needs Phoenix plus an HTTP adapter. Synaptic will use:

- `Plug.Cowboy` when available
- otherwise `Bandit.PhoenixAdapter`

If neither is available, `Synaptic.Monitor.Web.start_link/1` will raise with a
clear message.

### The monitor crashes on errors or exception structs

This should now be handled safely. Exception values are normalized for browser
rendering and JSON snapshots so failed runs remain visible instead of taking
down the page.

### Voice workflows show runs, not a rich agent mesh

That is expected when the app runs direct workflows rather than routing through
Synaptic services with `AgentRouter`. In that case the most useful views are:

- run focus
- step history
- activity log
- payload inspection

## Public APIs

Core APIs:

- `Synaptic.Monitor.snapshot/0`
- `Synaptic.Monitor.entity/2`
- `Synaptic.Monitor.recent_events/1`
- `Synaptic.Monitor.subscribe/0`
- `Synaptic.Monitor.unsubscribe/0`

Web APIs:

- `Synaptic.Monitor.Web.Live`
- `Synaptic.Monitor.Web.start_link/1`
- `Synaptic.Monitor.Web.child_spec/1`
