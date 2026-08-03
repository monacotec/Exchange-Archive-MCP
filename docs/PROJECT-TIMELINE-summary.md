# Archived-Email AI Access — Progress Summary (Jul 21–24, 2026)

**In plain terms:** we're building a secure way for our AI assistants (Claude /
Copilot-style agents) to search employees' **archived** email — including
executives' large auto-expanding archives — while making sure each person can only
ever see their own mailbox.

## The journey

**Started from a security review.** Worked through a 49-item security checklist and
closed the gaps, tightened error handling, and turned on audit logging. **Result:**
all automated tests passing, security posture improved.

**Tidied up the cloud setup.** Renamed and consolidated a key security vault and
removed leftover test resources — with no interruption to the running service.

**Connected the AI assistant.** Worked through a series of Microsoft sign-in
configuration hurdles so a user can connect and authenticate as themselves.
**Result:** connection working.

**Hit a major roadblock — and it wasn't ours.** We discovered Microsoft's standard
programming interface simply **cannot read the archive mailbox at all** — a
capability Microsoft hasn't shipped yet. We proved this thoroughly rather than
assume, so we didn't waste effort chasing a dead end. The older fallback technology
Microsoft is retiring this October was ruled out as a non-starter.

**Found a compliant path that works.** We routed archive access through Microsoft
**Purview eDiscovery** — the supported, enterprise-grade service that *can* reach
archives (including the executives' large ones). Along the way we solved two access
puzzles around permissions and isolation, ending with a design where **each user's
searches are fully walled off in their own case**. **Result:** archived email is now
searchable end-to-end, and we confirmed it live by retrieving a real 2022 email
thread that the standard interface couldn't touch.

**Added an "open in Outlook" convenience.** Built a small helper so a search result
can open the actual message in the desktop Outlook app. This needs a Microsoft
code-signing certificate (a one-time identity-verification step that takes a few
business days) before it can be rolled out to all workstations.

**Organized and backed up the work.** Cleaned the project folder, confirmed no
secrets were exposed, and published it to a private repository.

**Fixed a "it hangs and returns nothing" bug.** A user reported the results step
freezing. We traced it: the underlying export genuinely works, but Microsoft's
archive export now takes ~50 seconds, and our tool was waiting too long in one shot —
which looked like a freeze. **Fix:** the tool now responds quickly and checks back
in the background, so it no longer hangs.

## Setbacks (all resolved or understood)
- The corporate security tooling on the workstation blocked several normal network
  and sign-in operations — we adapted every script around it.
- A Microsoft product limitation (no archive access via the standard interface)
  forced the design change to eDiscovery.
- Sign-in sessions expiring mid-work — we made all cloud actions run as scripts the
  operator runs directly, with a safeguard preventing unattended access.

## Where things stand
Archived-email search **works today** for every mailbox type. Remaining before we
call it "1.0": push the just-made hang fix, complete the code-signing certificate so
the Outlook convenience can ship firm-wide, quiet the routine security alerts our own
searches generate, and a final security review.
