# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

Design work covers two surfaces that share one identity: the product website (`docs/`, static HTML/CSS on GitHub Pages) and the native macOS app (SwiftUI, macOS 14+). The app follows macOS conventions (sidebar navigation, native controls, menu-bar extra, System Settings-style forms); the site is plain web.

## Users

Students and self-learners on a Mac who juggle study deadlines, coding or project work, and easy distractions (games, video, social media). They want an honest picture of where their day actually went, and timely, specific feedback on whether they're on track, without having to log anything by hand.

## Product Purpose

ATLAS records how time is actually spent on the Mac, automatically and privately, so that a scheduled Claude check-in can compare what happened with the day's calendar and priorities and say plainly whether the user is on track and what to do next. Success is the user changing course mid-day because the feedback was accurate and arrived in time, not a high "productivity score".

## Positioning

ATLAS only tracks; it never plans. Planning and judgment come from Claude, which reads ATLAS on a schedule through its own MCP server (`atlasctl mcp`) alongside the user's calendar and daily briefing. Everything stays on the Mac, and analysis runs on the user's existing Claude subscription rather than paid API usage. Uncertain or untracked time is shown as uncertain, never guessed.

## Operating Context

- The tracker runs all day in the background (menu-bar extra plus a main window with Dashboard, Timeline, Agent and Reports).
- Check-ins arrive from the "ATLAS Check-in" scheduled task in the Claude app at 9, 12, 15, 18 and 21 local time, and are also shown in ATLAS's dashboard and Agent panel.
- A separate "Daily Briefing" Claude routine sets the day's priorities each morning; check-ins compare against it and against Google Calendar.
- Typical day: classes or study blocks, coding, browser research, plus Steam games, YouTube, X, Reddit and Instagram as the main distractions.
- Setup involves granting macOS permissions (Accessibility, Chrome Automation, Calendar, Notifications) and optionally loading the Chrome extension by hand.

## Capabilities and Constraints

- Tracks foreground apps, window titles (with Accessibility), Chrome tabs (via Apple Events or the bundled extension), idle, away, lock and sleep. It never records keystrokes, screenshots, form contents or document contents.
- A deterministic local classifier sorts time into 14 categories (coding, research, reading, educational video, entertainment video, social media, gaming, communication, administrative, focused work, personal organization, break, idle, unclassified), each with a confidence level. Users correct items in the Timeline and can turn corrections into rules.
- Analysis windows count awake time only (default 3 hours). Automatic in-app analysis is off by default; check-ins provide the feedback, and "Analyze Now" stays available.
- `atlasctl` CLI and MCP tools: `get_activity_summary`, `get_current_activity`, `get_recent_checkins`, `record_checkin`.
- Calendar writes are governed by three authorization levels; ATLAS never moves shared events or events it didn't create.
- Distribution: build from source (`scripts/build-app.sh`), signed with the user's Apple Development certificate. There is no notarized download yet.
- Terminology: "check-in", "awake time", "unclassified", "passive (inferred)", "private mode", "exclusions".

## Brand Commitments

- Name: ATLAS (all caps).
- Icon: the user's own graphite-squircle icon (`Resources/Icon/source.png`, `docs/assets/icon.png`). It is binding. Its resemblance to MATLAB's logo has been flagged and the user chose to keep it.
- Voice: a direct, kind coach. Straight talk backed by minutes and specifics, no guilt-tripping, no fluff, like a friend who wants you to succeed.
- Design direction (chosen 2026-10-25): the premium native Mac standard, executed at full craft, with Things 3, Raycast, Linear and Arc as the finish bar. Custom window chrome is allowed; controls stay standard. The user explicitly rejected skeuomorphic, literal-metaphor renditions (for example a split-flap rail board).
- Tagline in use: "Know where your time actually goes."

## Evidence on Hand

- A working app and open-source code at https://github.com/ZahinTapadar/atlas (MIT).
- A live product site at https://zahintapadar.github.io/atlas/.
- Real check-in output exists, but it contains the user's personal activity and must not be published. The site uses illustrative sample data instead.
- Absent, and not to be fabricated: users, testimonials, download counts, benchmarks, press, pricing, or notarized releases.

## Product Principles

1. **Track honestly, never guess.** Uncertain, unclassified or untracked time is labeled as such and never presented as fact.
2. **The user's day stays theirs.** Local-first storage, explicit permissions, exclusions, and only compact summaries reach Claude, on the user's own plan.
3. **Feedback beats scoring.** A timely, specific check-in ("87 minutes of gaming during the physics block") is worth more than any productivity number.
4. **Coach, don't shame.** Breaks, meals and evening leisure are legitimate; flag waste fairly and always offer a concrete next step.
5. **Do one job.** ATLAS tracks; planning lives in Claude and the calendar.
