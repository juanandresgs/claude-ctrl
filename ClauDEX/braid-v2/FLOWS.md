# braid-v2 Canonical Flows

## 1. Adopt the Current Live Loop

Use this when a worker is already running and you want to bring it under
runtime-owned supervision.

```text
detect live endpoint
  -> create bundle
  -> adopt worker session
  -> create worker seat
  -> spawn local supervisor session
  -> create supervisor seat
  -> create supervision_thread
  -> start controller watch
```

Key rule:
- adopt does not reset the worker; it attaches runtime authority around it

## 2. Spawn a Fresh Supervised Loop

Use this when the parent seat wants a clean child loop.

```text
parent seat requests child bundle
  -> spawn_request recorded
  -> controller provisions child bundle
  -> transport adapter spawns worker session
  -> transport adapter spawns supervisor session
  -> seats and threads created
  -> policy engine prompt packs injected
  -> child bundle becomes active
```

Key rule:
- spawn is runtime-owned; shell launchers are adapters only

## 3. Recursive Opposite-Direction Spawn

This is the case you called out explicitly.

Starting point:

- one meta-supervisor or dispatcher seat is already active
- it is supervising the current coding loop

Goal:

- that same seat opens another Claude Code loop with its own plan and its own
  local supervisor, while continuing to monitor the original loop

```text
meta dispatcher seat
  -> bundle spawn(child)
  -> child worker session created
  -> child supervisor session created
  -> child supervision_thread created
  -> parent supervision_thread points at child bundle
  -> controller watches:
       - original bundle
       - child bundle
       - parent dispatcher
```

The parent does not need to manually bounce between panes. It reads one runtime
tree and acts on explicit review artifacts and findings.

## 4. Review Wakeup

```text
worker produces review_artifact
  -> artifact stored as pending
  -> controller sees pending artifact
  -> controller wakes consuming supervisor seat
  -> supervisor consumes artifact
  -> artifact marked consumed
```

Key rule:
- wake on artifact, not on arbitrary stop-hook turn boundaries

## 5. Timeout and Retry

```text
dispatch_attempt pending/delivered
  -> timeout window exceeded
  -> controller writes finding if needed
  -> controller applies retry policy
      - retry once
      - reopen supervisor
      - or spawn repair bundle
```

Key rule:
- retries are bounded and recorded

## 6. Soak Monitoring

Use soak mode to observe a config or harness under real use.

```text
bundle marked soak_loop
  -> observer seat samples health and traces
  -> controller opens findings for repeated anomalies
  -> repair policy decides:
       observe_only
       propose_repair
       bounded_auto_repair
```

If `bounded_auto_repair` is enabled, the fix should be a normal child repair
bundle, not a hidden script restart.

## 7. Native Harness Approval Prompt

This is the screenshot scenario.

```text
worker is executing a live attempt
  -> harness opens edit approval / trust / permission prompt
  -> adapter records interaction_gate
  -> seat becomes blocked
  -> controller suppresses further dispatches to that seat
  -> controller routes gate:
       child supervisor
       parent dispatcher
       user only if policy requires
  -> gate resolved
  -> attempt resumes or fails explicitly
```

Key rule:
- do not treat this as either healthy work or terminal idle

## 8. Breakglass Gate Escalation

Use this when a gate cannot be answered locally but also should not collapse
directly to the user boundary.

```text
interaction_gate opened
  -> controller classifies gate and asks policy for route
  -> policy returns:
       auto_allow
       auto_deny
       escalate_to_parent
       escalate_to_dispatcher
       escalate_to_user
  -> gate_escalation_request recorded
  -> supervising seat or user reviews bounded context
  -> policy emits approval_grant or denial
  -> adapter consumes grant and resolves gate
  -> trajectory records request, decision, consume, result, and expiry if unused
```

Key rules:
- grants are narrow temporary exception leases, not generic bypasses
- unresolved escalations remain typed blocked state, not healthy progress

## 9. Repair In Situ

This is the behavior needed after the cutover config is deemed stable enough
for live soak.

```text
finding opened during soak
  -> controller selects repair policy
  -> repair_action recorded
  -> child repair bundle spawned
  -> repair bundle proposes or applies bounded fix
  -> result returned as review_artifact
  -> parent supervisor decides whether to continue soak
```

Key rule:
- repairs happen in the same architecture as normal work

## 10. Archive a Dead Bundle

```text
bundle unhealthy and terminal
  -> no progress window
  -> worker exited or unrecoverable
  -> repair budget exhausted
  -> controller archives bundle
  -> open finding if escalation needed
```

Key rule:
- do not leave dead bundles marked active
