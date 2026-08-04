# Voice Profiles, Capabilities, and Session Context

OpenAI native realtime sessions can be configured with a code-defined profile.
The profile is the single source of truth for the assistant's persona, concrete
tools, session context, and security policy. Synaptic compiles it into Realtime
instructions and function schemas; the same capabilities can also become Luna
tools with `Synaptic.Voice.Capability.to_tool/2`.

## Define a capability pack

```elixir
defmodule MyApp.Voice.CalendarPack do
  @behaviour Synaptic.Voice.CapabilityPack

  alias Synaptic.Voice.Capability

  def capabilities do
    [
      Capability.new!(%{
        name: "calendar_list_events",
        description: "List the caller's calendar events in a date range.",
        parameters: %{
          type: "object",
          properties: %{
            starts_at: %{type: "string"},
            ends_at: %{type: "string"}
          },
          required: ["starts_at", "ends_at"],
          additionalProperties: false
        },
        handler: &MyApp.Calendar.list_events/2,
        risk: :read_only,
        required_scopes: ["calendar:read"],
        limitations: ["does not create or modify events"]
      })
    ]
  end
end
```

A direct handler may accept `arguments` or `arguments, session_context`. Tool
names must be unique after all packs and individual capabilities are combined.
Individual capabilities may be added with `:capabilities` or removed with
`:disabled_capabilities`.

## Define the assistant profile

```elixir
defmodule MyApp.Voice.AssistantProfile do
  alias Synaptic.Voice.Profile

  def profile do
    Profile.new!(%{
      id: :customer_assistant,
      persona: %{
        name: "Ava",
        role: "customer scheduling assistant",
        purpose: "help the caller understand and manage their schedule",
        tone: "warm, concise, and professionally conversational",
        languages: ["en", "sk"],
        instructions: ["Confirm dates and time zones when ambiguous."],
        limitations: ["Never claim an appointment exists without a tool result."]
      },
      capability_packs: [MyApp.Voice.CalendarPack],
      context_schema: %{
        customer_name: %{classification: :safe, type: :string},
        timezone: %{classification: :safe, type: :string, required: true},
        customer_id: %{classification: :internal, type: :string}
      },
      security_policy: %{
        allowed_scopes: ["calendar:read", "calendar:write"]
      }
    })
  end
end
```

Context classifications are:

- `:safe`: may be included in model instructions.
- `:internal`: available to handlers but never placed in model instructions.
- `:restricted`: available only to application code and handlers, never placed
  in model instructions.

Supported context types are `:string`, `:integer`, `:number`, `:boolean`,
`:map`, and `:list`. Undeclared fields, invalid types, and missing required
fields reject session startup. Context lives only in the session process;
Synaptic does not persist it.

## Start an authorized session

```elixir
{:ok, %{session_id: session_id}} =
  Synaptic.Voice.start_session(MyWorkflow, %{},
    provider: :openai,
    mode: :realtime,
    experience: :realtime_2_1,
    response_mode: :native,
    profile: MyApp.Voice.AssistantProfile,
    session_context: %{
      customer_name: "Maya",
      timezone: "Europe/Warsaw",
      customer_id: "cust_123"
    },
    session_authorization: %{
      capabilities: :all,
      scopes: ["calendar:read"]
    }
  )
```

Supplying `profile:` automatically selects `experience: :realtime_2_1` unless
an explicit experience is provided. Keeping the experience visible is
recommended so the application records its intended compatibility contract.
Calls without a profile or experience retain legacy orchestrated behavior.

Only capabilities allowed by both the profile policy and session authorization
are exposed to Realtime. The execution gateway independently checks capability
authorization, required scopes, argument schemas, and confirmation before
calling application code. Model output cannot bypass that gateway.

## Confirmation for consequential actions

The framework always requires confirmation for `:external_action`,
`:sensitive`, and `:destructive` capabilities. Applications can tighten this
with `confirmation: :always` or `security_policy.force_confirmation`; they
cannot weaken the framework floor.

When `:capability_confirmation_required` is emitted, collect an explicit user
confirmation in the application and grant a single retry:

```elixir
:ok = Synaptic.Voice.approve_capability(session_id, "calendar_create_event")
```

Approval applies to the next invocation of that capability only. It is not
stored across calls or sessions.

## Security boundaries

- Keep authentication and source-system authorization in application code.
- Give every capability the narrowest required scopes and accurate risk level.
- Put secrets and stable customer identifiers in `:internal` or `:restricted`
  context, never `:safe` context.
- Treat model-visible context as untrusted data; never place executable
  instructions in customer fields.
- Return structured tool results and claim success only after the external
  system confirms it.
