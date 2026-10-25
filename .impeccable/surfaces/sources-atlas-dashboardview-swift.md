---
version: 1
slug: "sources-atlas-dashboardview-swift"
primary_target: "Sources/ATLAS/DashboardView.swift"
related_targets: ["Sources/ATLAS/AtlasApp.swift","Sources/ATLAS/TimelineView.swift","Sources/ATLAS/AgentView.swift","Sources/ATLAS/ReportsView.swift"]
---

# ATLAS macOS app — main window

Scope: the native macOS app window (Today, Timeline, Check-ins, Reports, Settings, setup sheet, menu-bar extra). Visitor mode: Operate.
Audience and job: a student mid-day glancing up to learn "am I on track right now?", then where today went. Used many times a day, for seconds at a time; occasionally longer for corrections in Timeline.
Constraints: fully custom window chrome allowed; controls stay standard macOS controls; light and dark follow the system; nothing playful or gamified.
Proof and content: real tracked data only; screenshots for the website come from a synthetic demo mode that is labeled as sample data.

## Direction contract

THESIS: The premium native Mac standard at the finish of Things 3, Raycast, Linear and Arc. Refuses the cards-in-a-grid analytics dashboard: one verdict leads, and everything else is supporting evidence set with typographic hierarchy instead of boxes.

OWN-WORLD: Graphite neutrals tinted from the icon, ink near-black or near-white as the brand colour, verdict colours (green, amber, red) as the only saturated fields, and category colours used only as data. SF Pro with tabular numerals; continuous-corner panels (radius 16–20), capsule chips, hairline separators, a borderless inset sidebar.

STORY: Open the window, read the verdict in under two seconds, see what you're doing now, glance at the shape of the day, act on the next step.

FIRST VIEWPORT: Hidden title bar. A 232-pt inset sidebar on the left: icon, ATLAS, Today, Timeline, Check-ins, Reports, and a tracking pill at the bottom. Main area: a date and a live current-activity capsule at the top; then a full-width verdict panel tinted by state, with a 40-pt verdict word, the check-in summary and "Next:" line; then the day ribbon with hour ticks; then two columns, time by category and focus figures.

FORM: Canon (the category standard, chosen by the user over the roll). seed: c89a7e322d302559

Signature interaction: the day ribbon. Hovering a cell reveals its time, app and category, and the current cell breathes softly while tracking.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
