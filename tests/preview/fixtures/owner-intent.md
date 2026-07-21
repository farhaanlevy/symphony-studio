# Copy evidence hash

Add a compact, keyboard-accessible `Copy evidence hash` action to the Run
Detail evidence section.

Acceptance criteria:

- Render the action only when a current evidence-manifest hash exists.
- Copy the exact displayed hash without making a network request.
- Announce success or failure through an accessible status message.
- Prevent duplicate activation while the copy operation is pending.
- Add focused deterministic tests for visible, unavailable, success, failure,
  keyboard, and repeated-activation behavior.
- Do not change authentication, credentials, persistence, migrations,
  infrastructure, tracker lifecycle, or broad layout.
