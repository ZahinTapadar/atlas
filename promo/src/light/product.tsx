import React from 'react';
import { AbsoluteFill, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { CATL, L } from './theme';
import { Card, Kicker, MacWindow, Paper, Pointer, Words, clamp, prog } from './kit';
import { ease } from '../kit';

const Side: React.FC<{ kicker: string; color?: string; title: string; sub: string; at?: number; width?: number }> = ({ kicker, color, title, sub, at = 0, width = 600 }) => {
  const f = useCurrentFrame();
  const k = prog(f, at, 16), s = prog(f, at + 18, 20);
  return (
    <div style={{ width }}>
      <div style={{ opacity: k, transform: `translateY(${(1 - k) * 10}px)` }}><Kicker color={color}>{kicker}</Kicker></div>
      <div style={{ marginTop: 22 }}><Words text={title} at={at + 6} size={68} align="left" /></div>
      <div style={{ marginTop: 18, fontSize: 28, lineHeight: 1.45, color: L.ink2, opacity: s, transform: `translateY(${(1 - s) * 12}px)`, fontWeight: 450 }}>{sub}</div>
    </div>
  );
};

/** Today: the window rises in perspective, then the camera settles on the verdict. */
export const TodayScene: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const rise = spring({ frame: f, fps, config: { damping: 22, mass: 1.2 } });
  const push = interpolate(f, [80, 170], [0, 1], { ...clamp, easing: ease });
  const scale = 0.62 + push * 0.5;
  const tilt = (1 - rise) * 26 + 6 * (1 - push);
  return (
    <Paper>
      <AbsoluteFill style={{ perspective: 2600, alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ transform: `translate(${push * 330}px, ${(1 - rise) * 520 + push * 250}px) scale(${scale}) rotateX(${tilt}deg) rotateY(${-6 * (1 - push)}deg)`, opacity: Math.min(1, rise * 1.5) }}>
          <MacWindow src={staticFile('today-light.webp')} width={1700} />
        </div>
      </AbsoluteFill>
      <div style={{ position: 'absolute', left: 120, bottom: 120, opacity: prog(f, 100, 18) }}>
        <Card style={{ padding: '34px 40px', maxWidth: 640 }}>
          <Side kicker="Today" color={L.on} title="One verdict leads." sub="Every few hours Claude reads your day and says, plainly, whether you're on track and what to do next." at={104} width={560} />
        </Card>
      </div>
    </Paper>
  );
};

/** To-dos, live from Things: a row opens to its checklist, items tick off, a reason gets written. */
export const TodosScene: React.FC = () => {
  const f = useCurrentFrame();
  const rows = [
    { t: 'Organic Chemistry: read Chapter 7', p: 'Chemistry', done: true, m: '48m' },
    { t: 'Physics lab 4: analysis', p: 'Physics · Due Fri', done: false, m: '41m', open: true },
    { t: 'Problem set 3', p: 'Chemistry', done: false, reason: true },
    { t: 'Habit app: streak logic', p: 'Side projects', done: true, m: '1h 39m' },
  ];
  const list = ['Clean the data runs', 'Curve fit with numpy.polyfit', 'Error bars and residuals', 'Discussion section'];
  const openP = prog(f, 40, 22);
  const reasonText = 'Lab partner needed the analysis first, so I swapped them.';
  const typed = Math.round(interpolate(f, [120, 170], [0, reasonText.length], clamp));
  return (
    <Paper>
      <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 90, padding: '0 110px' }}>
        <Side kicker="Live from Things" color={L.accent} title="Open any to-do. Say why it slipped." sub="See the checklist inside each task, tick things off, and leave a reason. The next check-in reads it and judges fairly." at={4} width={620} />
        <Card style={{ width: 860, padding: '26px 28px', position: 'relative' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', padding: '0 8px 14px' }}>
            <div style={{ fontSize: 26, fontWeight: 700 }}>Today's to-dos</div>
            <div style={{ fontSize: 18, color: L.ink3 }}>2 of 4 done · live from Things</div>
          </div>
          {rows.map((r, i) => {
            const p = prog(f, 8 + i * 5, 16);
            const tick = r.t.startsWith('Problem') ? 0 : 1;
            return (
              <div key={r.t} style={{ opacity: p, transform: `translateY(${(1 - p) * 16}px)` }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '14px 14px', borderRadius: 16, background: r.open && openP > 0 ? L.raised : 'transparent' }}>
                  <div style={{ width: 26, height: 26, borderRadius: 13, flex: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center',
                    background: r.done ? L.on : 'transparent', border: r.done ? 'none' : `3px solid ${r.open ? L.mixed : '#b5b5bd'}`, color: '#fff', fontSize: 16, fontWeight: 900 }}>{r.done ? '✓' : ''}</div>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 23, fontWeight: 600, color: r.done ? L.ink3 : L.ink, textDecoration: r.done ? 'line-through' : 'none' }}>{r.t}</div>
                    <div style={{ fontSize: 17, color: L.ink3, marginTop: 2 }}>{r.p}</div>
                  </div>
                  {r.open && <div style={{ fontSize: 16, fontWeight: 700, padding: '3px 10px', borderRadius: 10, background: 'rgba(0,0,0,0.05)', color: L.ink2 }}>{2 + (f > 96 ? 1 : 0)}/4</div>}
                  {r.m && <div style={{ fontSize: 19, color: L.ink2, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>{r.m}</div>}
                  <div style={{ fontSize: 18, color: L.ink3, transform: `rotate(${r.open ? openP * 90 : 0}deg)` }}>›</div>
                </div>
                {r.open && (
                  <div style={{ overflow: 'hidden', maxHeight: openP * 230, opacity: openP, padding: '0 14px 0 56px' }}>
                    {list.map((c, j) => {
                      const doneNow = j < 2 || (j === 2 && f > 96);
                      const flash = j === 2 ? prog(f, 96, 10) : 0;
                      return (
                        <div key={c} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '7px 0', fontSize: 19, color: doneNow ? L.ink3 : L.ink, textDecoration: doneNow ? 'line-through' : 'none' }}>
                          <span style={{ width: 18, height: 18, borderRadius: 5, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, color: '#fff', fontWeight: 900,
                            background: doneNow ? L.on : 'transparent', border: doneNow ? 'none' : '2px solid #b5b5bd', transform: `scale(${1 + flash * 0.25 * (1 - flash)})` }}>{doneNow ? '✓' : ''}</span>{c}
                        </div>
                      );
                    })}
                  </div>
                )}
                {r.reason && f > 112 && (
                  <div style={{ margin: '0 14px 6px 56px', padding: '12px 16px', borderRadius: 14, border: `2px solid ${L.mixed}55`, background: '#fff8ec', fontSize: 19, color: L.mixed, fontWeight: 550 }}>
                    {reasonText.slice(0, typed)}<span style={{ opacity: f % 16 < 8 && typed < reasonText.length ? 1 : 0 }}>|</span>
                  </div>
                )}
                {i < rows.length - 1 && <div style={{ height: 1, background: L.hairline, margin: '2px 14px' }} />}
              </div>
            );
            void tick;
          })}
          <Pointer path={[{ f: 22, x: 820, y: 520 }, { f: 38, x: 805, y: 168 }, { f: 84, x: 805, y: 168 }, { f: 94, x: 72, y: 370 }, { f: 104, x: 72, y: 370 }, { f: 116, x: 360, y: 560 }]} clickAt={[38, 96]} />
        </Card>
      </AbsoluteFill>
    </Paper>
  );
};

/** Check-ins: verdict cards arrive as a history rail. */
export const CheckinsScene: React.FC = () => {
  const f = useCurrentFrame();
  const items = [
    { v: 'On track', c: L.on, g: '✓', t: '9:00', h: '1h 39m of focused coding, gaming held to 16 minutes.' },
    { v: 'Mixed', c: L.mixed, g: '~', t: '12:00', h: 'Chemistry started well, then 40 minutes drifted into YouTube.' },
    { v: 'Off track', c: L.off, g: '!', t: '15:00', h: '70 minutes of gaming during the revision block.' },
    { v: 'On track', c: L.on, g: '✓', t: '18:00', h: 'Back on it: problem set done in one 85-minute block.' },
  ];
  return (
    <Paper>
      <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 90, padding: '0 110px' }}>
        <Side kicker="Check-ins" color={L.mixed} title="A coach, not a scold." sub="Straight talk backed by minutes, and always a concrete next step. Every verdict is kept, so you see how the day turned." at={4} width={600} />
        <div style={{ width: 860, position: 'relative' }}>
          <div style={{ position: 'absolute', left: 27, top: 30, bottom: 30, width: 3, background: L.hairline, transformOrigin: 'top', transform: `scaleY(${prog(f, 6, 60)})` }} />
          {items.map((it, i) => {
            const p = prog(f, 14 + i * 16, 20);
            return (
              <div key={i} style={{ display: 'flex', gap: 24, alignItems: 'flex-start', marginBottom: 22, opacity: p, transform: `translateX(${(1 - p) * 60}px)` }}>
                <div style={{ width: 56, height: 56, borderRadius: 28, background: it.c, color: '#fff', fontSize: 28, fontWeight: 900, flex: 'none',
                  display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: `0 0 0 8px ${L.ground}` , transform: `scale(${0.6 + p * 0.4})` }}>{it.g}</div>
                <Card style={{ flex: 1, padding: '20px 26px', borderRadius: 22, background: `linear-gradient(180deg, ${it.c}10, #ffffff)` }}>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 14 }}>
                    <span style={{ fontSize: 30, fontWeight: 800, color: it.c, letterSpacing: '-0.02em' }}>{it.v}</span>
                    <span style={{ fontSize: 20, color: L.ink3, fontVariantNumeric: 'tabular-nums' }}>{it.t}</span>
                  </div>
                  <div style={{ fontSize: 22, fontWeight: 550, marginTop: 6 }}>{it.h}</div>
                </Card>
              </div>
            );
          })}
        </div>
      </AbsoluteFill>
    </Paper>
  );
};

/** Reports, built live: filters, the balance bar, bars rising, the focus map sweeping. */
export const ReportsScene: React.FC = () => {
  const f = useCurrentFrame();
  const groups: [string, string, number][] = [['Work', CATL.coding, 12.8], ['Learning', CATL.research, 3.7], ['Reading', CATL.reading, 6.5], ['Video', CATL.entertainment, 1.6], ['Games', CATL.gaming, 3.2], ['Social', CATL.social, 1.4]];
  const filter = f > 120 ? 'Productive' : 'Everything';
  const productive = ['Work', 'Learning', 'Reading'];
  const days = [[2.4, 1.1, 1.3, 0.5, 0.8, 0.3], [3.2, 0.6, 1.8, 1.1, 0, 0.4], [2.2, 0.4, 0.5, 0.2, 2.2, 0.5], [3.4, 0.6, 1.3, 0, 0, 0.3], [1.0, 0.5, 1.5, 0.7, 0.2, 0.3], [2.4, 0.9, 1.1, 0.2, 0.9, 0.4], [3.0, 0.7, 1.4, 0.1, 0.2, 0.2]];
  const total = groups.reduce((s, g) => s + g[2], 0);
  const bal = prog(f, 20, 40);
  const share = Math.round(interpolate(f, [20, 60], [0, 77], clamp));
  return (
    <Paper>
      <AbsoluteFill style={{ padding: '90px 120px', flexDirection: 'column', gap: 34 }}>
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <div style={{ opacity: prog(f, 0, 14) }}><Kicker color={L.accent}>Reports</Kicker></div>
            <div style={{ marginTop: 18 }}><Words text="See the pattern, not just the day." at={4} size={64} align="left" /></div>
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            {['Everything', 'Productive', 'Distractions'].map((c, i) => {
              const on = c === filter;
              return <div key={c} style={{ padding: '12px 22px', borderRadius: 999, fontSize: 22, fontWeight: 650, opacity: prog(f, 10 + i * 4, 14),
                background: on ? L.ink : L.surface, color: on ? '#fff' : L.ink2, boxShadow: on ? 'none' : '0 0 0 1px rgba(17,17,19,0.1)', transition: 'none' }}>{c}</div>;
            })}
          </div>
        </div>
        <Card style={{ padding: '26px 32px' }}>
          <div style={{ fontSize: 34, fontWeight: 750, letterSpacing: '-0.02em' }}>
            29h 56m engaged, <span style={{ color: L.on }}>{share}%</span> <span style={{ color: L.ink2 }}>of it on work, learning and reading.</span>
          </div>
          <div style={{ display: 'flex', gap: 4, marginTop: 18, height: 22, width: `${bal * 100}%`, overflow: 'hidden', borderRadius: 8 }}>
            {groups.map(([n, c, v]) => (
              <div key={n} style={{ flex: v, background: c, opacity: filter === 'Productive' && !productive.includes(n) ? 0.15 : 0.78, borderRadius: 6 }} />
            ))}
          </div>
          <div style={{ display: 'flex', gap: 26, marginTop: 14, fontSize: 18, color: L.ink2 }}>
            {groups.map(([n, c, v]) => <span key={n} style={{ display: 'flex', alignItems: 'center', gap: 8, opacity: filter === 'Productive' && !productive.includes(n) ? 0.4 : 1 }}>
              <span style={{ width: 10, height: 10, borderRadius: 5, background: c }} />{n} <span style={{ color: L.ink3 }}>{Math.round(v / total * 100)}%</span></span>)}
          </div>
        </Card>
        <div style={{ display: 'flex', gap: 30, flex: 1 }}>
          <Card style={{ flex: 1.25, padding: '24px 30px', display: 'flex', flexDirection: 'column' }}>
            <div style={{ fontSize: 22, fontWeight: 700 }}>Day by day</div>
            <div style={{ flex: 1, display: 'flex', alignItems: 'flex-end', gap: 26, padding: '14px 10px 0', borderBottom: `2px solid ${L.hairline}` }}>
              {days.map((d, i) => {
                const p = prog(f, 40 + i * 5, 26);
                return (
                  <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column-reverse', gap: 3, height: '100%', justifyContent: 'flex-start' }}>
                    {d.map((v, j) => (
                      <div key={j} style={{ height: `${(v / 7) * 100 * p}%`, background: groups[j][1], borderRadius: 6,
                        opacity: filter === 'Productive' && !productive.includes(groups[j][0]) ? 0.12 : 0.75 }} />
                    ))}
                  </div>
                );
              })}
            </div>
            <div style={{ display: 'flex', gap: 26, padding: '10px 10px 0', fontSize: 17, color: L.ink3 }}>
              {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d) => <div key={d} style={{ flex: 1, textAlign: 'center' }}>{d}</div>)}
            </div>
          </Card>
          <Card style={{ flex: 1, padding: '24px 30px' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}>
              <div style={{ fontSize: 22, fontWeight: 700 }}>When you focus</div>
              <div style={{ fontSize: 18, color: L.ink2, opacity: prog(f, 110, 14) }}>Peak: Tuesdays, 10 AM</div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(14, 1fr)', gap: 5, marginTop: 18 }}>
              {Array.from({ length: 7 * 14 }).map((_, k) => {
                const d = Math.floor(k / 14), h = k % 14;
                const v = Math.max(0, Math.sin((h - 2) / 2.2) * 0.8 + Math.cos(d * 1.3 + h / 3) * 0.35 - (h > 10 ? 0.4 : 0) + (d === 1 && h === 3 ? 0.9 : 0));
                const p = prog(f, 56 + (d + h) * 2.2, 10);
                const peak = d === 1 && h === 3 && f > 110;
                return <div key={k} style={{ height: 30, borderRadius: 6, background: v > 0.05 ? `rgba(17,17,19,${(0.08 + Math.min(1, v) * 0.82) * p})` : L.track,
                  boxShadow: peak ? `0 0 0 3px ${L.on}` : 'none' }} />;
              })}
            </div>
          </Card>
        </div>
        <Pointer path={[{ f: 90, x: 1700, y: 300 }, { f: 112, x: 1505, y: 132 }, { f: 150, x: 1505, y: 132 }]} clickAt={[116]} />
      </AbsoluteFill>
    </Paper>
  );
};
