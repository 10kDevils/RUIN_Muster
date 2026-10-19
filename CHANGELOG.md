# RUIN Muster changelog

Versioning: the third number counts the meaningful changes made since the second number last went up.

## Unreleased

(nothing yet)

## 0.3.4 — 2026-10-19

RUIN Intel is retired and folded into Muster (needs RUIN Core 0.3.9). Muster already reacts to something happening in the world or plans a raid, which is what Intel was for.

1. **Sightings page (from Intel):** one button reports an enemy group, an under-attack call, a world boss, a rare, a buff drop or anything else, with your location. Every RUIN member gets an alert, an entry in the 30-minute feed and a pin on the world map and minimap that fades as it ages. Also `/muster spot <kind> [detail]` (and `/intel ...` still works) and two new key bindings (report enemy group, I'm under attack).
2. **Timers page (from Intel):** world boss kills and world buff drops, with "Now" and "drops in N minutes", shared with the org and re-sent to anyone who logs in.
3. **Find group:** boss, rare, enemy and under-attack sightings have a *Find group* button that lists you in RUIN Finder for that activity (needs Finder 0.3.2).
4. Rally points react to sightings directly, no separate addon needed. Your RUIN Intel reports and timers are copied across once. Old Intel versions still in the org are still understood.

## 0.3.3 — 2026-10-18

3 changes since 0.3.0 (needs RUIN Core 0.3.7). RUIN Warfront is retired: RUIN's world PvP runs on Overlord Forever, and the Warfront features Overlord has no match for move here.

1. Rally points: tick *Rally here* when posting an event, or type `/muster rally <name>` to call a rally right where you stand. The meeting place is pinned on everyone's world map and minimap from 3 hours before the start to 2 hours after, with its distance in the event list. When RUIN Intel reports enemies within about 300 yards, the rally is marked CONTESTED for 10 minutes and everyone is alerted.
2. Bounties (from Warfront): officers post a bounty on a rival guild or player with an optional reward (Bounties page, or `/muster bounty guild|player <name> (reward)`). Kill one, target the body and claim (`/muster claim`, or the new key binding); another RUIN member nearby confirms (`/muster confirm`). Practice mode covers bounties too.
3. New RUIN look (the Muster tab, part of the RUIN Gaming Companion App), Retail's interface number in the TOC, and a pointer to Overlord Forever for the faction-wide campaign, keeps, captures and Most Wanted.

## 0.3.0 — 2026-10-18

- Suite release: every RUIN addon moves to 0.3.0 together, bringing everything from the 0.2.x entries below. No further code changes.
- Needs RUIN Core 0.3.0.
- From now on a RUIN addon's 0.3.x number counts its own changes since this release.

## 0.2.6 — 2026-10-18

6 changes since 0.2.0:

Needs RUIN Core 0.2.6 or later.

1. Events have a description, a size, and how many tanks, healers and DPS are needed. The list shows have/need per role, and hovering shows details and who's coming.
2. Weekly events: tick Weekly and next week's event is posted once this week's starts.
3. Raid roster: officers auto-fill groups of five and a bench, move people by clicking, and send the roster. Members get an alert with their group, and reminders include it.
4. Soft reserves: one reserved item per player per event, with clashes counted.
5. Other modules can read open slots and upcoming events, so RUIN Finder lists events that need players and RUIN Codex plans raids into Muster.
6. The page is split into Events, Roster and Reserves, with role icons on the sign-up buttons.

## 0.2.0 — 2026-10-18

- Suite milestone: every RUIN addon moves to 0.2.0 together. No code changes since the last 0.1 release.
- With RUIN Core 0.2.0, this module's page opens in the new RUIN window with its own themed header: flickering torches and pennants.

## 0.1.2 — 2026-10-18

- Fixed: "Binding header RUIN was attempted to be loaded more than once". Each module now has its own section under Key Bindings, and all of its bindings load.
- Practice mode: while not connected to RUIN, anyone can post events to try the page. Practice events stay on your own screen.
- Practice mode switch: a "Practice mode" checkbox on the Muster page and /muster practice. Practice events and their sign-ups stay on your own screen, and switching practice off clears them.

## 0.1.0 — 2026-10-18

First proof of concept.
