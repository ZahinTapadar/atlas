import React from 'react';
import { AbsoluteFill, Easing, interpolate, spring, useCurrentFrame, useVideoConfig } from 'remotion';
import { C, FONT } from './theme';

export const ease = Easing.bezier(0.22, 1, 0.36, 1);

/** 0→1 over [start, start+dur] with an expo-out curve. */
export const useIn = (start: number, dur = 24) => {
  const f = useCurrentFrame();
  return interpolate(f, [start, start + dur], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: ease });
};

export const useSpring = (delay = 0, damping = 18, mass = 0.9) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({ frame: f - delay, fps, config: { damping, mass } });
};

/** Graphite ground with a slow-drifting light, shared by every scene. */
export const Ground: React.FC<{ children?: React.ReactNode; hue?: string }> = ({ children, hue = 'rgba(92,141,255,0.10)' }) => {
  const f = useCurrentFrame();
  const x = 62 + Math.sin(f / 90) * 8;
  const y = 18 + Math.cos(f / 110) * 6;
  return (
    <AbsoluteFill style={{ background: C.ground, fontFamily: FONT, color: C.ink, overflow: 'hidden' }}>
      <AbsoluteFill style={{ background: `radial-gradient(70% 60% at ${x}% ${y}%, ${hue} 0%, rgba(0,0,0,0) 70%)` }} />
      <AbsoluteFill style={{ background: 'radial-gradient(120% 90% at 50% 120%, rgba(0,0,0,0.6), rgba(0,0,0,0) 60%)' }} />
      {children}
    </AbsoluteFill>
  );
};

/** Words rise in one after another (mask reveal). */
export const Rise: React.FC<{ text: string; start?: number; size: number; weight?: number; color?: string; stagger?: number; tracking?: number }> = ({
  text, start = 0, size, weight = 700, color = C.ink, stagger = 3, tracking = -0.04,
}) => {
  const f = useCurrentFrame();
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: `0 ${size * 0.26}px`, fontSize: size, fontWeight: weight, letterSpacing: `${tracking}em`, lineHeight: 1.08, color }}>
      {text.split(' ').map((w, i) => {
        const p = interpolate(f, [start + i * stagger, start + i * stagger + 22], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: ease });
        return (
          <span key={i} style={{ display: 'inline-block', overflow: 'hidden', paddingBottom: size * 0.12, marginBottom: -size * 0.12 }}>
            <span style={{ display: 'inline-block', transform: `translateY(${(1 - p) * 105}%)`, opacity: p }}>{w}</span>
          </span>
        );
      })}
    </div>
  );
};

/** Fades a whole scene out over its last frames. */
export const Out: React.FC<{ at: number; dur?: number; children: React.ReactNode }> = ({ at, dur = 12, children }) => {
  const f = useCurrentFrame();
  const o = interpolate(f, [at, at + dur], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  const s = interpolate(f, [at, at + dur], [1, 0.98], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  return <AbsoluteFill style={{ opacity: o, transform: `scale(${s})` }}>{children}</AbsoluteFill>;
};

export const Eyebrow: React.FC<{ children: React.ReactNode; color?: string; o?: number }> = ({ children, color = C.ink3, o = 1 }) => (
  <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: '0.18em', textTransform: 'uppercase', color, opacity: o }}>{children}</div>
);

/** A window screenshot with the app's corner radius and a deep shadow. */
export const Shot: React.FC<{ src: string; width: number; style?: React.CSSProperties }> = ({ src, width, style }) => (
  <img src={src} style={{ width, borderRadius: width * 0.014, boxShadow: '0 50px 140px -30px rgba(0,0,0,0.85), 0 0 0 1.5px rgba(255,255,255,0.07)', ...style }} />
);
