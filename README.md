# RUIN Muster

Events for the whole org: raid nights, PvP pushes and leveling groups, with role sign-ups, role limits, weekly repeats, a raid roster and soft reserves.

Part of the **RUIN Gaming Companion App**. Requires **RUIN Core** (0.3.15 or later). With **RUIN Finder** installed, events that still need players appear on the Finder board, and a sighting's *Find group* button lists you there; **RUIN Codex** can plan raids into Muster.

## The experience
- **Where it lives:** the Muster tab in the RUIN window (Events, Roster, Reserves, Bounties, Sightings, Timers), `/muster`, and key bindings to open Muster, claim a bounty kill, report an enemy group and call for help.
- **Rally points:** tick *Rally here* when posting an event, or type `/muster rally <name>` to call a rally where you stand right now. Everyone sees the meeting place pinned on the world map and minimap from 3 hours before the start to 2 hours after, with its distance in the event list. An enemy sighting within about 300 yards mark it CONTESTED for 10 minutes. `/muster pins` hides the pins.
- **Sightings (formerly RUIN Intel):** one button reports an enemy group, an under-attack call, a world boss, a rare, a buff drop or anything else, with your location. Every RUIN member gets an alert and a pin on the world map and minimap that fades over 30 minutes. `/muster spot <kind> [detail]` (or `/intel ...`) does the same from chat. Boss, rare and enemy rows have a *Find group* button that lists you in RUIN Finder.
- **Timers:** world boss kills and world buff drops (`/muster timer songflower`, `/muster timer dragonslayer 5`), shared with the org. Respawn windows are Classic's, as a guide.
- **Bounties:** officers put a price on a rival guild or player (Bounties page, or `/muster bounty guild|player <name> (reward)`). Kill one, target the body and press *Claim kill on target* (`/muster claim` or the key binding); another RUIN member nearby confirms (`/muster confirm`). You can't confirm your own kill.
- **World PvP:** the faction-wide campaign, keeps, captures and Most Wanted belong to **Overlord Forever**, which RUIN uses instead of its old Warfront addon. The Bounties page opens Overlord when it's installed.
- **Posting (officers, and the ranks your guild's officers allow under Options → Org → Guild settings; needs RUIN Core 0.3.17):** press *New event* above the list, then fill in the title, type and size; pick the day from the list (today and the next two weeks, shown like *Thu 10/22*) and type the hour and minute with AM or PM (your own time); add an optional description and how many tanks, healers and DPS are needed (filled in from the size), and *Weekly* to repeat it.
- **Signing up:** the role buttons sign you up, X withdraws. Each event shows have/need per role; hover it for the description and who's coming.
- **Weekly events:** once a weekly event starts, next week's is posted by itself.
- **Roster (officers):** *Auto-fill* spreads tanks and healers across groups of five and sends anyone past the size to the bench. Click a name to move it, then *Send roster*; members get an alert with their group.
- **Soft reserves:** sign up, then shift-click an item (or type its name) on the Reserves page. Everyone sees who reserved what, and clashes are counted.
- **Reminders:** an alert 15 minutes before an event you signed up for, with your group.
- **Practice mode:** tick *Practice mode* on the Events page or type `/muster practice` to post and sign up alone; practice events stay on your screen.

## What it shares with RUIN
Events officers post (with descriptions, sizes, needs and rally points), sign-ups with role and soft reserve, rosters, bounties, kill claims with where they happened, and confirmations.

## Notes
Times are stored as one moment and shown in each player's local time.
