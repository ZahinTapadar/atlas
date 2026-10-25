import React from 'react';
import { AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { CATL, L } from './theme';
import { Card, Kicker, Paper, Pointer, Words, clamp, prog } from './kit';
import { ease } from '../kit';
import { MONO } from '../theme';

const Lead: React.FC<{ kicker: string; color: string; title: string; sub: string; width?: number }> = ({ kicker, color, title, sub, width = 600 }) => {
  const f = useCurrentFrame();
  const k = prog(f, 0, 16), s = prog(f, 20, 20);
  return (
    <div style={{ width }}>
      <div style={{ opacity: k }}><Kicker color={color}>{kicker}</Kicker></div>
      <div style={{ marginTop: 22 }}><Words text={title} at={6} size={68} align="left" /></div>
      <div style={{ marginTop: 18, fontSize: 28, lineHeight: 1.45, color: L.ink2, opacity: s, transform: `translateY(${(1 - s) * 12}px)` }}>{sub}</div>
    </div>
  );
};

/** The check-in email, on a phone: a notification drops in, then the designed email scrolls. */
export const EmailScene: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const phone = spring({ frame: f - 4, fps, config: { damping: 18, mass: 1 } });
  const notif = prog(f, 26, 14) * (1 - prog(f, 64, 12));
  const scroll = interpolate(f, [78, 170], [0, -250], { ...clamp, easing: ease });
  const ribbon = ['#2f6bff', '#2f6bff', '#0b8bc6', '#0b8bc6', '#5e9e10', '#2f6bff', '#2f6bff', '#2f6bff', '#e2600f', '#2f6bff', '#0f9f98', '#0f9f98', '#7c4ddb', '#2f6bff', '#2f6bff', '#0b8bc6', '#2f6bff', '#2f6bff'];
  const D = { bg: '#0e0e10', card: '#1a1a1e', ink: '#f4f4f6', ink2: '#a1a1aa', on: '#3dd68c' };
  return (
    <Paper tint="rgba(22,128,74,0.08)">
      <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 140, padding: '0 120px' }}>
        <Lead kicker="On your phone" color={L.on} title="Every check-in lands in your inbox." sub="A designed email with your scorecard, animated charts, to-dos and next step. Plus a calendar nudge when it's time to start." />
        <div style={{ position: 'relative', transform: `translateY(${(1 - phone) * 700}px) rotate(${(1 - phone) * 6}deg)` }}>
          <div style={{ width: 430, height: 880, borderRadius: 70, background: '#0b0b0d', padding: 14, boxShadow: '0 80px 160px -50px rgba(17,17,19,0.55), 0 0 0 2px #2a2a30' }}>
            <div style={{ width: '100%', height: '100%', borderRadius: 56, overflow: 'hidden', background: D.bg, position: 'relative' }}>
              <div style={{ position: 'absolute', top: 14, left: '50%', marginLeft: -60, width: 120, height: 34, borderRadius: 17, background: '#000', zIndex: 5 }} />
              <div style={{ transform: `translateY(${scroll}px)`, padding: '80px 22px 30px', fontFamily: 'system-ui', color: D.ink }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, color: D.ink2 }}><b style={{ letterSpacing: 3, color: D.ink }}>ATLAS</b><span>Mon · 3:00 PM</span></div>
                <div style={{ marginTop: 14, borderRadius: 22, padding: 20, background: 'linear-gradient(180deg, rgba(61,214,140,0.16), rgba(61,214,140,0.05))', border: '1px solid rgba(61,214,140,0.3)' }}>
                  <div style={{ fontSize: 34, fontWeight: 800, color: D.on, letterSpacing: -1 }}>On track</div>
                  <div style={{ fontSize: 16, fontWeight: 600, marginTop: 8, lineHeight: 1.35 }}>1h 39m of focused coding, gaming held to 16 minutes.</div>
                  <div style={{ marginTop: 12, padding: 12, borderRadius: 12, background: 'rgba(0,0,0,0.3)', fontSize: 14, fontWeight: 600 }}>→ Finish the lab analysis before the 4:30 tutorial.</div>
                </div>
                <div style={{ fontSize: 15, fontWeight: 700, margin: '20px 4px 10px' }}>Scorecard</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                  {[['77%', 'on work, learning, reading', D.on], ['4 days', 'focus streak', D.on], ['3', 'on-track in a row', D.ink], ['Tue', 'best day this week', D.ink]].map(([v, l, c], i) => (
                    <div key={i} style={{ background: D.card, borderRadius: 14, padding: 12 }}>
                      <div style={{ fontSize: 22, fontWeight: 800, color: c as string }}>{v}</div>
                      <div style={{ fontSize: 11.5, color: D.ink2, marginTop: 4 }}>{l}</div>
                    </div>
                  ))}
                </div>
                <div style={{ fontSize: 15, fontWeight: 700, margin: '20px 4px 10px' }}>The day so far</div>
                <div style={{ background: D.card, borderRadius: 14, padding: 14, display: 'flex', gap: 4, alignItems: 'flex-end', height: 70 }}>
                  {ribbon.map((c, i) => <div key={i} style={{ flex: 1, height: `${interpolate(f, [90 + i * 2, 102 + i * 2], [30, 100], clamp)}%`, background: c, borderRadius: 3, opacity: 0.85 }} />)}
                </div>
                <div style={{ fontSize: 15, fontWeight: 700, margin: '20px 4px 10px' }}>Today's to-dos</div>
                <div style={{ background: D.card, borderRadius: 14, padding: '6px 14px' }}>
                  {[['Read Chapter 7', true], ['Lab 4 analysis', false], ['Problem set 3', false]].map(([t, d], i) => (
                    <div key={i} style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '10px 0', borderTop: i ? '1px solid #2a2a30' : 'none', fontSize: 14,
                      color: d ? D.ink2 : D.ink, textDecoration: d ? 'line-through' : 'none' }}>
                      <span style={{ width: 14, height: 14, borderRadius: 7, background: d ? D.on : 'transparent', border: d ? 'none' : '2px solid #6e6e78' }} />{t as string}
                    </div>
                  ))}
                </div>
                <div style={{ fontSize: 15, fontWeight: 700, margin: '20px 4px 10px' }}>Day by day</div>
                <div style={{ background: D.card, borderRadius: 14, padding: 14, display: 'flex', gap: 10, alignItems: 'flex-end', height: 130 }}>
                  {[0.5, 0.7, 0.55, 0.8, 0.4, 0.65, 0.75].map((h, i) => (
                    <div key={i} style={{ flex: 1, height: `${h * 100 * interpolate(f, [130 + i * 3, 148 + i * 3], [0.1, 1], clamp)}%`, borderRadius: 4,
                      background: 'linear-gradient(180deg, #7c4ddb 0 18%, #0f9f98 18% 40%, #2f6bff 40%)', opacity: 0.85 }} />
                  ))}
                </div>
              </div>
              <div style={{ position: 'absolute', top: 60, left: 12, right: 12, borderRadius: 22, padding: '14px 16px', background: 'rgba(250,250,252,0.94)', color: '#111',
                boxShadow: '0 20px 40px -10px rgba(0,0,0,0.5)', transform: `translateY(${(1 - notif) * -140}px)`, opacity: notif, display: 'flex', gap: 12, alignItems: 'center' }}>
                <Img src={staticFile('icon.png')} style={{ width: 40, borderRadius: 10 }} />
                <div><div style={{ fontSize: 14, fontWeight: 700 }}>ATLAS · On track · 3:00 PM</div><div style={{ fontSize: 13, color: '#55555d' }}>1h 39m of focused coding. Next: lab analysis.</div></div>
              </div>
            </div>
          </div>
        </div>
      </AbsoluteFill>
    </Paper>
  );
};

/** Choosing when: hours toggle on and off, then pause and skip. */
export const ScheduleScene: React.FC = () => {
  const f = useCurrentFrame();
  const hours = ['6 AM', '7 AM', '8 AM', '9 AM', '10 AM', '11 AM', '12 PM', '1 PM', '2 PM', '3 PM', '4 PM', '5 PM', '6 PM', '7 PM', '8 PM', '9 PM', '10 PM', '11 PM'];
  const base = new Set(['9 AM', '12 PM', '3 PM', '6 PM', '9 PM']);
  const sel = new Set(base);
  if (f > 46) sel.add('11 AM');
  if (f > 64) sel.delete('6 PM');
  const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  const pause = prog(f, 96, 18);
  return (
    <Paper>
      <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 100, padding: '0 110px' }}>
        <Lead kicker="Your schedule" color={L.accent} title="You decide when it checks in." sub="Pick the hours and days. Pause for a busy week, skip just the next one, or run a check-in right now." />
        <Card style={{ width: 860, padding: '30px 34px', position: 'relative' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ fontSize: 22, fontWeight: 700 }}>Days</div>
            <div style={{ display: 'flex', gap: 8 }}>
              {days.map((d, i) => {
                const on = !(i >= 5 && f > 78);
                return <div key={i} style={{ width: 52, height: 44, borderRadius: 12, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 20, fontWeight: 700,
                  background: on ? L.accent : L.raised, color: on ? '#fff' : L.ink2, boxShadow: on ? 'none' : '0 0 0 1px rgba(17,17,19,0.08)' }}>{d}</div>;
              })}
            </div>
          </div>
          <div style={{ height: 1, background: L.hairline, margin: '22px 0' }} />
          <div style={{ fontSize: 22, fontWeight: 700, marginBottom: 16 }}>Times</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6, 1fr)', gap: 10 }}>
            {hours.map((h, i) => {
              const on = sel.has(h);
              const p = prog(f, 4 + i * 1.2, 12);
              return <div key={h} style={{ height: 52, borderRadius: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 19, fontWeight: 650,
                background: on ? L.accent : L.raised, color: on ? '#fff' : L.ink2, opacity: p, transform: `scale(${0.85 + p * 0.15})`,
                boxShadow: on ? '0 10px 20px -10px rgba(47,107,255,0.7)' : '0 0 0 1px rgba(17,17,19,0.07)' }}>{h}</div>;
            })}
          </div>
          <div style={{ height: 1, background: L.hairline, margin: '22px 0' }} />
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 22 }}>
            <span style={{ fontWeight: 650 }}>Next check-in</span>
            <span style={{ color: L.ink2, fontVariantNumeric: 'tabular-nums' }}>{f > 46 ? 'Today, 11:00 AM' : 'Today, 12:00 PM'}</span>
          </div>
          <div style={{ display: 'flex', gap: 12, marginTop: 22 }}>
            {['Pause for 3 days', 'Skip 11 AM', 'Check in now'].map((t, i) => (
              <div key={t} style={{ padding: '12px 20px', borderRadius: 999, fontSize: 19, fontWeight: 650, opacity: prog(f, 84 + i * 6, 14),
                background: i === 2 ? L.ink : L.surface, color: i === 2 ? '#fff' : L.ink, boxShadow: i === 2 ? 'none' : '0 0 0 1px rgba(17,17,19,0.12)' }}>{t}</div>
            ))}
          </div>
          <div style={{ position: 'absolute', right: 30, top: -26, padding: '10px 18px', borderRadius: 14, background: L.ink, color: '#fff', fontSize: 18, fontWeight: 650,
            opacity: pause, transform: `translateY(${(1 - pause) * 10}px)` }}>Weekends off</div>
          <Pointer path={[{ f: 30, x: 900, y: 260 }, { f: 44, x: 760, y: 190 }, { f: 52, x: 760, y: 190 }, { f: 62, x: 120, y: 260 }, { f: 70, x: 120, y: 260 }, { f: 76, x: 690, y: 48 }, { f: 86, x: 760, y: 48 }]} clickAt={[44, 62, 76, 82]} />
        </Card>
      </AbsoluteFill>
    </Paper>
  );
};

/** Setup: the checklist completes itself, step by step. */
export const SetupScene: React.FC = () => {
  const f = useCurrentFrame();
  const steps = [
    ['Window titles', 'Accessibility'], ['Chrome tabs', 'Automation'], ['Claude Code', 'Signed in with your plan'],
    ['Connect ATLAS to Claude', 'MCP server'], ['Check-in schedule', 'Created in Claude with one paste'], ['Email', 'Designed check-ins to your inbox'],
  ];
  const done = steps.filter((_, i) => f > 26 + i * 14).length;
  return (
    <Paper>
      <AbsoluteFill style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 100, padding: '0 110px' }}>
        <Lead kicker="Setup" color={L.on} title="Ready in a few minutes." sub="A checklist walks you through every permission and connection, one button each. Everything stays on your Mac." />
        <Card style={{ width: 820, padding: '30px 34px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
            <div style={{ fontSize: 30, fontWeight: 750 }}>Set up ATLAS</div>
            <div style={{ fontSize: 20, color: done === steps.length ? L.on : L.ink3, fontWeight: 650 }}>{done === steps.length ? 'All set' : `${steps.length - done} steps left`}</div>
          </div>
          <div style={{ height: 8, borderRadius: 4, background: L.track, margin: '18px 0 10px', overflow: 'hidden' }}>
            <div style={{ height: '100%', width: `${(done / steps.length) * 100}%`, background: L.on, borderRadius: 4, transition: 'none' }} />
          </div>
          {steps.map(([t, d], i) => {
            const ok = i < done;
            const pop = prog(f, 26 + i * 14, 10);
            return (
              <div key={t} style={{ display: 'flex', alignItems: 'center', gap: 18, padding: '15px 0', borderTop: i ? `1px solid ${L.hairline}` : 'none', opacity: prog(f, 4 + i * 3, 14) }}>
                <div style={{ width: 34, height: 34, borderRadius: 17, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontWeight: 900, fontSize: 18,
                  background: ok ? L.on : 'transparent', border: ok ? 'none' : `3px solid ${L.mixed}`, transform: `scale(${ok ? 1 + 0.25 * Math.sin(pop * Math.PI) : 1})` }}>{ok ? '✓' : ''}</div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 23, fontWeight: 650 }}>{t}</div>
                  <div style={{ fontSize: 17, color: L.ink3 }}>{d}</div>
                </div>
                <div style={{ fontSize: 17, fontWeight: 700, color: ok ? L.on : L.ink2 }}>{ok ? 'Done' : 'Allow…'}</div>
              </div>
            );
          })}
        </Card>
      </AbsoluteFill>
    </Paper>
  );
};

/** Install with Homebrew or a download; updates arrive by themselves. */
export const InstallScene: React.FC = () => {
  const f = useCurrentFrame();
  const cmd = 'brew install --cask zahintapadar/tap/atlas';
  const typed = Math.round(interpolate(f, [16, 56], [0, cmd.length], clamp));
  const out = prog(f, 62, 12);
  const update = prog(f, 92, 18);
  const progress = interpolate(f, [118, 150], [0, 1], clamp);
  return (
    <Paper>
      <AbsoluteFill style={{ flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 44 }}>
        <div style={{ textAlign: 'center' }}>
          <div style={{ opacity: prog(f, 0, 14) }}><Kicker color={L.accent}>Free and open source</Kicker></div>
          <div style={{ marginTop: 20 }}><Words text="One line to install. Updates itself after that." at={4} size={64} /></div>
        </div>
        <div style={{ display: 'flex', gap: 34, alignItems: 'stretch' }}>
          <Card style={{ width: 860, padding: 0, overflow: 'hidden', background: '#16161a' }}>
            <div style={{ display: 'flex', gap: 8, padding: '16px 18px' }}>{['#ff5f57', '#febc2e', '#28c840'].map((c) => <span key={c} style={{ width: 13, height: 13, borderRadius: 7, background: c }} />)}</div>
            <div style={{ padding: '6px 30px 30px', fontFamily: MONO, fontSize: 24, color: '#e5e5ea', lineHeight: 1.7 }}>
              <div><span style={{ color: '#3dd68c' }}>❯</span> {cmd.slice(0, typed)}<span style={{ opacity: f % 14 < 7 && typed < cmd.length ? 1 : 0 }}>▍</span></div>
              <div style={{ opacity: out, color: '#8f8f99' }}>==&gt; Installing Cask atlas</div>
              <div style={{ opacity: out, color: '#8f8f99' }}>==&gt; Moving App 'ATLAS.app' to '/Applications/ATLAS.app'</div>
              <div style={{ opacity: prog(f, 72, 10), color: '#e5e5ea' }}>🍺  atlas was successfully installed!</div>
            </div>
          </Card>
          <Card style={{ width: 420, padding: '28px 28px', display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 16, opacity: update, transform: `translateY(${(1 - update) * 40}px)` }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
              <div style={{ width: 44, height: 44, borderRadius: 22, background: `${L.live}1f`, color: L.live, fontSize: 26, display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 800 }}>↓</div>
              <div><div style={{ fontSize: 23, fontWeight: 700 }}>Update available</div><div style={{ fontSize: 18, color: L.ink3 }}>ATLAS 1.5.0</div></div>
            </div>
            <div style={{ height: 10, borderRadius: 5, background: L.track, overflow: 'hidden' }}>
              <div style={{ height: '100%', width: `${progress * 100}%`, background: L.live }} />
            </div>
            <div style={{ fontSize: 17, color: L.ink2 }}>{progress >= 1 ? 'Verified and installed. Restarting…' : progress > 0 ? 'Downloading and verifying…' : 'Install and restart'}</div>
          </Card>
        </div>
        <div style={{ display: 'flex', gap: 16, opacity: prog(f, 40, 16) }}>
          {['macOS 14+', 'Apple Silicon and Intel', 'Your data stays on your Mac', 'Runs on your Claude plan'].map((t) => (
            <div key={t} style={{ padding: '12px 22px', borderRadius: 999, background: L.surface, boxShadow: '0 0 0 1px rgba(17,17,19,0.08)', fontSize: 21, fontWeight: 600, color: L.ink2 }}>{t}</div>
          ))}
        </div>
      </AbsoluteFill>
    </Paper>
  );
};

export const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame: f - 2, fps, config: { damping: 14 } });
  const url = prog(f, 44, 20);
  return (
    <Paper>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 34 }}>
        <Img src={staticFile('icon.png')} style={{ width: 190, transform: `scale(${icon})`, filter: 'drop-shadow(0 30px 50px rgba(17,17,19,0.25))' }} />
        <Words text="Track honestly. Act on it." at={12} size={108} />
        <div style={{ display: 'flex', gap: 16, alignItems: 'center', opacity: url, transform: `translateY(${(1 - url) * 14}px)` }}>
          <div style={{ padding: '18px 34px', borderRadius: 999, background: L.ink, color: '#fff', fontSize: 30, fontWeight: 700 }}>Download for Mac</div>
          <div style={{ fontFamily: MONO, fontSize: 30, color: L.ink2 }}>atlasmac.web.app</div>
        </div>
        <div style={{ position: 'absolute', bottom: 54, fontSize: 19, color: L.ink3, opacity: url }}>Sample data shown</div>
      </AbsoluteFill>
    </Paper>
  );
};
