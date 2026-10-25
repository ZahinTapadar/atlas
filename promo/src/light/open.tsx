import React from 'react';
import { AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { CATL, L } from './theme';
import { Paper, Words, clamp, prog } from './kit';

/** Icon lands with a soft bloom; the wordmark tracks in; the promise follows. */
export const Opening: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame: f - 4, fps, config: { damping: 13, mass: 0.9 } });
  const bloom = prog(f, 0, 40);
  const word = prog(f, 20, 30);
  const out = interpolate(f, [92, 110], [1, 0], clamp);
  return (
    <Paper>
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', flexDirection: 'column', gap: 30, opacity: out, transform: `scale(${1 - (1 - out) * 0.04})` }}>
        <div style={{ position: 'relative' }}>
          <div style={{ position: 'absolute', inset: -140, borderRadius: '50%', background: `radial-gradient(circle, rgba(47,107,255,${0.22 * bloom}), transparent 62%)` }} />
          <Img src={staticFile('icon.png')} style={{ width: 230, position: 'relative', transform: `scale(${0.55 + icon * 0.45}) rotate(${(1 - icon) * -10}deg)`, opacity: Math.min(1, icon * 1.3),
            filter: 'drop-shadow(0 30px 50px rgba(17,17,19,0.28))' }} />
        </div>
        <div style={{ fontSize: 70, fontWeight: 750, letterSpacing: `${0.55 - word * 0.33}em`, opacity: word, transform: `translateY(${(1 - word) * 14}px)` }}>ATLAS</div>
        <div style={{ marginTop: -6 }}><Words text="Know where your time actually goes." at={44} size={38} weight={500} color={L.ink2} stagger={2} /></div>
      </AbsoluteFill>
    </Paper>
  );
};

/** The problem, in motion: a planned day, then the apps that ate it. */
export const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const apps = [
    ['YouTube', CATL.entertainment, -620, -230], ['X', '#111113', 560, -260], ['Discord', CATL.focused, -700, 140], ['Steam', CATL.gaming, 640, 120],
    ['Reddit', CATL.social, -360, 330], ['Instagram', '#c13584', 380, 320], ['Messages', CATL.eduVideo, -40, -360], ['Chrome', CATL.coding, 120, 380],
  ] as const;
  const second = f >= 58;
  const count = Math.round(interpolate(f, [62, 104], [0, 41], { ...clamp }));
  const out = interpolate(f, [128, 140], [1, 0], clamp);
  return (
    <Paper tint="rgba(198,40,40,0.07)">
      <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', opacity: out }}>
        {!second ? (
          <div style={{ opacity: interpolate(f, [46, 56], [1, 0], clamp) }}>
            <Words text="You planned to study." at={4} size={120} />
          </div>
        ) : (
          <>
            {apps.map(([name, color, x, y], i) => {
              const p = prog(f, 60 + i * 4, 18);
              const drift = Math.sin((f + i * 20) / 22) * 8;
              return (
                <div key={name} style={{ position: 'absolute', transform: `translate(${x * p}px, ${y * p + drift}px) scale(${0.6 + p * 0.4})`, opacity: p,
                  padding: '14px 24px', borderRadius: 999, background: L.surface, boxShadow: '0 20px 40px -18px rgba(17,17,19,0.3), 0 0 0 1px rgba(17,17,19,0.06)',
                  display: 'flex', alignItems: 'center', gap: 12, fontSize: 30, fontWeight: 650 }}>
                  <span style={{ width: 14, height: 14, borderRadius: 7, background: color }} />{name}
                </div>
              );
            })}
            <div style={{ textAlign: 'center' }}>
              <div style={{ fontSize: 200, fontWeight: 800, letterSpacing: '-0.05em', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{count}</div>
              <div style={{ fontSize: 44, fontWeight: 600, color: L.ink2, marginTop: 10 }}>app switches before lunch.</div>
            </div>
          </>
        )}
      </AbsoluteFill>
    </Paper>
  );
};
