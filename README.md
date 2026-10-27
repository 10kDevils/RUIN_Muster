# RUIN Muster

Events for the whole org: raid nights, PvP pushes and leveling groups, with role sign-ups, role limits, weekly repeats, a raid roster and soft reserves.

Part of the **RUIN Gaming Companion App**. Requires **RUIN Core** (0.3.15 or later). With **RUIN Finder** installed, events that still need players appear on the Finder board, and a sighting's *Find group* button lists you there; **RUIN Codex** can plan raids into Muster.

## The experience
- **Where it lives:** the Muster tab in the RUIN window (Events; Plan with Groups and Squads; Loot with Reserves and Drops; Wanted with Most Wanted and Bounties; Sightings), `/muster`, and key bindings to open Muster, claim a bounty kill, report an enemy group and call for help.
- **Rally points:** tick *Rally here* when posting an event, or type `/muster rally <name>` to call a rally where you stand right now. Everyone sees the meeting place pinned on the world map and minimap from 3 hours before the start to 2 hours after, with its distance in the event list. An enemy sighting within about 300 yards mark it CONTESTED for 10 minutes. `/muster pins` hides the pins.
- **Sightings (formerly RUIN Intel):** one button reports an enemy group, an under-attack call, a world boss, a rare, a buff drop or anything else, with your location. Every RUIN member gets an alert and a pin on the world map and minimap that fades over 30 minutes. `/muster spot <kind> [detail]` (or `/intel ...`) does the same from chat. Boss, rare and enemy rows have a *Find group* button that lists you in RUIN Finder.
- **Timers** moved to RUIN Finder (Finder → Timers) in 0.4.1; `/muster timer` passes on to it.
- **Most Wanted (Wanted tab):** when an enemy player kills a RUIN member, that member's RUIN tells the org who did it (from the game's death recap, or the enemy player near you who had you targeted). The list ranks the killers of RUIN members this week, with their guild, victims and where; officers can post a bounty from a row. A Most Wanted player's nameplate showing up near you raises a warning. *Slayers* counts RUIN members' honorable kills, and *Recent* shows the latest deaths and kills.
- **War Room:** pick an event and plan it as an operation: add squads (up to 25 of up to 40) or press *Auto squads* (tanks and healers spread first), give each an objective, move players between squads and make one the leader. Everyone signed up sees their orders at the top of the tab, and the reminder names their squad. Afterwards the event's leaders write the after-action report.
- **Loot:** the event's leaders note who got what (main spec, off spec, bank, disenchant, points and a note); drops your group loots appear under *Recent drops*, one click fills the form. Members press *I want this* for the drop they hope for; *Wishes* shows them, *This season* each player's loot count and points over 90 days.
- **Bounties:** officers put a price on a rival guild or player (Bounties page, or `/muster bounty guild|player <name> (reward)`). Kill one, target the body and press *Claim kill on target* (`/muster claim` or the key binding); another RUIN member nearby confirms (`/muster confirm`). You can't confirm your own kill.
- **World PvP:** the faction-wide campaign, keeps and captures belong to **Overlord Forever**, which RUIN uses instead of its old Warfront addon. The Bounties page opens Overlord when it's installed.
- **Posting (officers, and the ranks your guild's officers allow under Settings → Org → Guild settings; needs RUIN Core 0.3.17):** press *New event* above the list, then fill in the title, type and size; pick the day from the list (today and the next two weeks, shown like *Thu 10/22*) and type the hour and minute with AM or PM (your own time); add an optional description and how many tanks, healers and DPS are needed (filled in from the size), and *Weekly* to repeat it.
- **Signing up:** the role buttons sign you up, X withdraws. Each event shows have/need per role; hover it for the description and who's coming.
- **Weekly events:** once a weekly event starts, next week's is posted by itself.
- **Roster (officers):** *Auto-fill* spreads tanks and healers across groups of five and sends anyone past the size to the bench. Click a name to move it, then *Send roster*; members get an alert with their group.
- **Soft reserves:** sign up, then shift-click an item (or type its name) on the Reserves page. Everyone sees who reserved what, and clashes are counted.
- **Reminders:** an alert 15 minutes before an event you signed up for, with your group.
- **Practice mode:** tick *Practice mode* on the Events page or type `/muster practice` to post and sign up alone; practice events stay on your screen.

## What it shares with RUIN
Events officers post (with descriptions, sizes, needs, rally points, squads and after-action reports), sign-ups with role and soft reserve, rosters, bounties, kill claims with where they happened, and confirmations; who killed you (when an enemy player did) and enemy players you killed, with the zone; loot notes and the drop you hope for.

## Notes
Times are stored as one moment and shown in each player's local time.
