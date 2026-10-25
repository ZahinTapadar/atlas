import React from 'react';
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from 'remotion';
import { C, CAT, MONO } from './theme';
import { Eyebrow, Ground, Out, Rise, Shot, ease, useIn, useSpring } from './kit';

const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

// 1 · Icon and wordmark ────────────────────────────────────────────────
export const Intro: React.FC = () => {
  const f = useCurrentFrame();
  const icon = useSpring(4, 14);
  const word = useIn(22, 26);
  const glow = interpolate(f, [0, 60], [0, 1], clamp);
  return (
    <Ground>
      <Out at={78}>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', gap: 44, flexDirection: 'column' }}>
          <div style={{ position: 'relative' }}>
            <div style={{ position: 'absolute', inset: -80, borderRadius: '50%', background: `radial-gradient(circle, rgba(92,141,255,${0.28 * glow}), transparent 65%)` }} />
            <Img src={staticFile('icon.png')} style={{ width: 240, transform: `scale(${0.6 + icon * 0.4}) rotate(${(1 - icon) * -8}deg)`, opacity: icon, position: 'relative' }} />
          </div>
          <div style={{ fontSize: 64, fontWeight: 700, letterSpacing: `${0.6 - word * 0.32}em`, opacity: word, transform: `translateY(${(1 - word) * 16}px)` }}>ATLAS</div>
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 2 · The question ─────────────────────────────────────────────────────
export const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const second = f > 62;
  const counter = Math.round(interpolate(f, [66, 100], [0, 41], clamp));
  return (
    <Ground hue="rgba(255,107,107,0.07)">
      <Out at={130}>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 28, padding: '0 200px' }}>
          {!second ? (
            <Out at={52} dur={10}>
              <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center' }}>
                <Rise text="Where did today actually go?" size={112} start={4} />
              </AbsoluteFill>
            </Out>
          ) : (
            <>
              <Rise text={`${counter} app switches.`} size={104} start={64} stagger={0} />
              <Rise text="Two hours you meant to study." size={104} start={84} color={C.ink3} />
            </>
          )}
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 3 · Today: the window rises, then pushes into the verdict ─────────────
export const Today: React.FC = () => {
  const f = useCurrentFrame();
  const rise = useSpring(0, 20, 1.1);
  const push = interpolate(f, [70, 170], [0, 1], { ...clamp, easing: ease });
  const scale = 0.78 + push * 0.62;
  const tx = push * 380;
  const ty = (1 - rise) * 500 + push * 260;
  const tilt = (1 - rise) * 22;
  const cap = useIn(96, 22);
  return (
    <Ground>
      <Out at={198}>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', perspective: 2400 }}>
          <div style={{ transform: `translate(${tx}px, ${ty}px) scale(${scale}) rotateX(${tilt}deg)`, opacity: Math.min(1, rise * 1.4) }}>
            <Shot src={staticFile('today-dark.webp')} width={1600} />
          </div>
        </AbsoluteFill>
        <Caption o={cap} eyebrow="Today" title="One verdict leads." sub="Every three hours Claude reads your day and tells you, plainly, how it's going." />
      </Out>
    </Ground>
  );
};

const Caption: React.FC<{ o: number; eyebrow: string; title: string; sub?: string }> = ({ o, eyebrow, title, sub }) => (
  <div style={{ position: 'absolute', left: 110, bottom: 100, maxWidth: 820, padding: '34px 40px 38px', borderRadius: 30, background: C.surface,
    backdropFilter: 'blur(24px)', border: `1px solid ${C.hairline}`, boxShadow: '0 30px 80px -20px rgba(0,0,0,0.7)', opacity: o, transform: `translateY(${(1 - o) * 30}px)` }}>
    <Eyebrow>{eyebrow}</Eyebrow>
    <div style={{ fontSize: 64, fontWeight: 700, letterSpacing: '-0.035em', lineHeight: 1.04, marginTop: 14 }}>{title}</div>
    {sub && <div style={{ fontSize: 27, color: C.ink2, lineHeight: 1.38, marginTop: 14, fontWeight: 500 }}>{sub}</div>}
  </div>
);

// 4 · Verdict cards, built live ────────────────────────────────────────
const verdicts = [
  { word: 'On track', color: C.onTrack, glyph: '✓', head: '1h 39m of focused coding, gaming held to 16 minutes.', next: 'Finish the physics lab analysis before the 16:30 tutorial.' },
  { word: 'Mixed', color: C.mixed, glyph: '◐', head: 'Good start on chemistry, then 40 minutes drifted into YouTube.', next: 'Close the browser and do problem set 3, questions 1–4.' },
  { word: 'Off track', color: C.offTrack, glyph: '!', head: '70 minutes of gaming during the revision block.', next: 'Quit the game. 25 minutes on Chapter 7, then reassess.' },
];

export const Verdicts: React.FC = () => {
  const f = useCurrentFrame();
  const title = useIn(0, 20);
  return (
    <Ground>
      <Out at={168}>
        <div style={{ position: 'absolute', top: 120, width: '100%', textAlign: 'center', opacity: title, transform: `translateY(${(1 - title) * 20}px)` }}>
          <Eyebrow>Check-ins</Eyebrow>
          <div style={{ fontSize: 76, fontWeight: 700, letterSpacing: '-0.04em', marginTop: 14 }}>A coach, not a scold.</div>
        </div>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', paddingTop: 170 }}>
          {verdicts.map((v, i) => {
            const at = 14 + i * 52;
            const p = interpolate(f, [at, at + 26], [0, 1], { ...clamp, easing: ease });
            const leave = i < 2 ? interpolate(f, [at + 38, at + 50], [0, 1], { ...clamp, easing: ease }) : 0;
            const typed = Math.round(interpolate(f, [at + 8, at + 34], [0, v.head.length], clamp));
            return (
              <div key={v.word} style={{ position: 'absolute', width: 1180, padding: '44px 52px', borderRadius: 32, background: `linear-gradient(180deg, ${v.color}1f, ${v.color}0d)`,
                border: `1.5px solid ${v.color}40`, opacity: p * (1 - leave), transform: `translateY(${(1 - p) * 60 - leave * 40}px) scale(${1 - leave * 0.06})` }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 22 }}>
                  <div style={{ width: 62, height: 62, borderRadius: 31, background: v.color, color: C.ground, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 36, fontWeight: 800 }}>{v.glyph}</div>
                  <div style={{ fontSize: 84, fontWeight: 700, color: v.color, letterSpacing: '-0.04em' }}>{v.word}</div>
                  <div style={{ marginLeft: 'auto', fontFamily: MONO, fontSize: 28, color: C.ink3 }}>{['12:00', '15:00', '18:00'][i]}</div>
                </div>
                <div style={{ fontSize: 36, fontWeight: 600, marginTop: 24, minHeight: 46 }}>{v.head.slice(0, typed)}</div>
                <div style={{ display: 'inline-flex', gap: 16, alignItems: 'center', marginTop: 26, padding: '16px 24px', borderRadius: 18, background: 'rgba(0,0,0,0.3)', fontSize: 28, fontWeight: 600 }}>
                  <span style={{ color: v.color }}>→</span>{v.next}
                </div>
              </div>
            );
          })}
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 5 · The day ribbon fills in ─────────────────────────────────────────
const ribbon: string[] = [
  'idle', 'idle', 'reading', 'reading', 'reading', 'reading', 'reading', 'eduVideo', 'eduVideo', 'focused', 'comms', 'idle',
  'coding', 'coding', 'coding', 'coding', 'coding', 'coding', 'research', 'coding', 'coding', 'coding', 'coding', 'social',
  'idle', 'idle', 'gaming', 'gaming', 'coding', 'coding', 'coding', 'coding', 'research', 'reading', 'reading', 'idle',
];
const legend = [['Coding', 'coding', '2h 20m'], ['Reading', 'reading', '1h 10m'], ['Research', 'research', '20m'], ['Gaming', 'gaming', '20m'], ['Social', 'social', '10m']] as const;

export const Ribbon: React.FC = () => {
  const f = useCurrentFrame();
  const title = useIn(0, 20);
  const cell = 38, gap = 8;
  return (
    <Ground>
      <Out at={168}>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 80 }}>
          <div style={{ textAlign: 'center', opacity: title, transform: `translateY(${(1 - title) * 20}px)` }}>
            <Eyebrow>Tracking</Eyebrow>
            <div style={{ fontSize: 76, fontWeight: 700, letterSpacing: '-0.04em', marginTop: 14 }}>Every ten minutes, accounted for.</div>
            <div style={{ fontSize: 30, color: C.ink2, marginTop: 16, fontWeight: 500 }}>Apps, sites and idle time, classified on your Mac. No screenshots, no keystrokes.</div>
          </div>
          <div style={{ display: 'flex', gap }}>
            {ribbon.map((k, i) => {
              const p = interpolate(f, [16 + i * 2.2, 30 + i * 2.2], [0, 1], { ...clamp, easing: ease });
              const color = (CAT as Record<string, string>)[k];
              return <div key={i} style={{ width: cell, height: 96, borderRadius: 10, background: k === 'idle' ? '#1c1c20' : color, opacity: 0.25 + p * 0.75,
                transform: `scaleY(${0.3 + p * 0.7})`, boxShadow: k === 'idle' ? 'none' : `0 0 ${p * 30}px ${color}33` }} />;
            })}
          </div>
          <div style={{ display: 'flex', gap: 48 }}>
            {legend.map(([name, key, time], i) => {
              const p = useIn(100 + i * 6, 18);
              return (
                <div key={name} style={{ display: 'flex', alignItems: 'center', gap: 14, fontSize: 28, opacity: p, transform: `translateY(${(1 - p) * 14}px)` }}>
                  <span style={{ width: 16, height: 16, borderRadius: 8, background: (CAT as Record<string, string>)[key] }} />
                  <span style={{ fontWeight: 600 }}>{name}</span>
                  <span style={{ color: C.ink3, fontFamily: MONO, fontSize: 24 }}>{time}</span>
                </div>
              );
            })}
          </div>
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 6 · The loop: one check-in updates everything ──────────────────────
const nodes = [
  { label: 'Things', detail: '3 of 6 done · 1 added', x: -560, y: -230, color: '#4b8ef7', icon: '☑' },
  { label: 'Calendar', detail: 'Next · Problem set 3 · 6:15 PM', x: 560, y: -230, color: '#ff6b6b', icon: '▦' },
  { label: 'Email', detail: 'ATLAS · On track · 15:00', x: -560, y: 230, color: '#f5b342', icon: '✉' },
  { label: 'Your phone', detail: 'Reminder at 6:15 PM', x: 560, y: 230, color: '#3dd68c', icon: '◉' },
];

export const Loop: React.FC = () => {
  const f = useCurrentFrame();
  const title = useIn(0, 20);
  const core = useSpring(10, 14);
  const pulse = (f % 45) / 45;
  return (
    <Ground hue="rgba(61,214,140,0.08)">
      <Out at={198}>
        <div style={{ position: 'absolute', top: 96, width: '100%', textAlign: 'center', opacity: title, transform: `translateY(${(1 - title) * 20}px)` }}>
          <Eyebrow>The loop</Eyebrow>
          <div style={{ fontSize: 76, fontWeight: 700, letterSpacing: '-0.04em', marginTop: 14 }}>Every check-in closes the loop.</div>
        </div>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', paddingTop: 130 }}>
          <svg width={1920} height={900} style={{ position: 'absolute', top: 180 }} viewBox="-960 -450 1920 900">
            {nodes.map((n, i) => {
              const p = interpolate(f, [40 + i * 14, 70 + i * 14], [0, 1], { ...clamp, easing: ease });
              const len = Math.hypot(n.x, n.y);
              const dot = ((f - 70 - i * 14) / 40) % 1;
              return (
                <g key={n.label}>
                  <line x1={0} y1={0} x2={n.x * 0.78} y2={n.y * 0.78} stroke="rgba(255,255,255,0.18)" strokeWidth={2} strokeDasharray={len} strokeDashoffset={len * (1 - p)} />
                  {p >= 1 && <circle cx={n.x * 0.78 * dot} cy={n.y * 0.78 * dot} r={6} fill={n.color} opacity={1 - dot * 0.4} />}
                </g>
              );
            })}
          </svg>
          <div style={{ position: 'absolute', top: '50%', marginTop: 65 - 110, width: 220, height: 220, borderRadius: 60, background: C.raised,
            border: `1.5px solid ${C.hairline}`, display: 'flex', alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 10,
            transform: `scale(${core})`, boxShadow: `0 0 0 ${pulse * 40}px rgba(61,214,140,${0.18 * (1 - pulse)})` }}>
            <Img src={staticFile('icon.png')} style={{ width: 110 }} />
            <div style={{ fontSize: 22, fontWeight: 600, color: C.ink2 }}>Check-in</div>
          </div>
          {nodes.map((n, i) => {
            const p = useSpring(52 + i * 14, 16);
            return (
              <div key={n.label} style={{ position: 'absolute', top: '50%', left: '50%', width: 420, padding: '26px 30px', borderRadius: 26, background: C.surface,
                border: `1.5px solid ${C.hairline}`, transform: `translate(calc(-50% + ${n.x}px), calc(-50% + ${n.y + 65}px)) scale(${0.8 + p * 0.2})`, opacity: p,
                boxShadow: '0 30px 70px -25px rgba(0,0,0,0.8)' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
                  <div style={{ width: 52, height: 52, borderRadius: 15, background: `${n.color}26`, color: n.color, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 28 }}>{n.icon}</div>
                  <div style={{ fontSize: 34, fontWeight: 700, letterSpacing: '-0.02em' }}>{n.label}</div>
                </div>
                <div style={{ fontSize: 24, color: C.ink2, marginTop: 14, fontWeight: 500 }}>{n.detail}</div>
              </div>
            );
          })}
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 7 · The rest of the app, three screens fanned ───────────────────────
export const Screens: React.FC = () => {
  const f = useCurrentFrame();
  const title = useIn(0, 20);
  const drift = interpolate(f, [0, 180], [0, -40]);
  const shots = [
    { src: 'timeline-dark.webp', label: 'Timeline', x: -560, r: -6 },
    { src: 'checkins-dark.webp', label: 'Check-ins', x: 0, r: 0 },
    { src: 'reports-dark.webp', label: 'Reports', x: 560, r: 6 },
  ];
  return (
    <Ground>
      <Out at={168}>
        <div style={{ position: 'absolute', top: 110, width: '100%', textAlign: 'center', opacity: title }}>
          <Rise text="Look back. Spot the pattern." size={76} start={2} />
        </div>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', paddingTop: 180, perspective: 2600 }}>
          {shots.map((s, i) => {
            const p = useSpring(14 + i * 9, 18, 1);
            const front = i === 1;
            return (
              <div key={s.src} style={{ position: 'absolute', transform: `translate(${s.x * p}px, ${(1 - p) * 300 + drift * (front ? 1 : 0.5)}px) rotateY(${s.r * -p}deg) rotateZ(${s.r * 0.25 * p}deg) scale(${front ? 1 : 0.86})`,
                opacity: p, zIndex: front ? 2 : 1 }}>
                <Shot src={staticFile(s.src)} width={820} />
                <div style={{ textAlign: 'center', marginTop: 26, fontSize: 30, fontWeight: 600, color: front ? C.ink : C.ink2 }}>{s.label}</div>
              </div>
            );
          })}
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 8 · Local-first ──────────────────────────────────────────────────────
export const Private: React.FC = () => {
  const lock = useSpring(4, 12);
  const rows = ['SQLite on your Mac', 'No cloud account', 'Claude via your own subscription', 'Open source · MIT'];
  return (
    <Ground hue="rgba(139,139,245,0.09)">
      <Out at={128}>
        <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 40 }}>
          <div style={{ width: 120, height: 120, borderRadius: 36, background: C.raised, border: `1.5px solid ${C.hairline}`, display: 'flex', alignItems: 'center', justifyContent: 'center', transform: `scale(${lock})` }}>
            <svg width={56} height={56} viewBox="0 0 24 24" fill="none" stroke={C.ink} strokeWidth={2} strokeLinecap="round"><rect x="4" y="11" width="16" height="10" rx="3" /><path d="M8 11V7a4 4 0 0 1 8 0v4" /></svg>
          </div>
          <Rise text="Your day stays on your Mac." size={92} start={10} />
          <div style={{ display: 'flex', gap: 18, marginTop: 10 }}>
            {rows.map((r, i) => {
              const p = useIn(40 + i * 7, 18);
              return <div key={r} style={{ padding: '16px 26px', borderRadius: 999, border: `1.5px solid ${C.hairline}`, background: C.surface, fontSize: 26, fontWeight: 600, color: C.ink2,
                opacity: p, transform: `translateY(${(1 - p) * 16}px)` }}>{r}</div>;
            })}
          </div>
        </AbsoluteFill>
      </Out>
    </Ground>
  );
};

// 9 · Outro ────────────────────────────────────────────────────────────
export const Outro: React.FC = () => {
  const icon = useSpring(2, 15);
  const url = useIn(46, 22);
  return (
    <Ground>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 36 }}>
        <Img src={staticFile('icon.png')} style={{ width: 180, transform: `scale(${icon})` }} />
        <Rise text="Track honestly. Act on it." size={104} start={14} />
        <div style={{ fontFamily: MONO, fontSize: 32, color: C.ink2, opacity: url, transform: `translateY(${(1 - url) * 12}px)`, padding: '14px 28px', borderRadius: 999, border: `1.5px solid ${C.hairline}` }}>
          zahintapadar.github.io/atlas
        </div>
        <div style={{ position: 'absolute', bottom: 60, fontSize: 20, color: C.ink3, opacity: url }}>Free for macOS · Sample data shown</div>
      </AbsoluteFill>
    </Ground>
  );
};
