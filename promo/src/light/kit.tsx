import React from 'react';
import { AbsoluteFill, interpolate, useCurrentFrame } from 'remotion';
import { FONT } from '../theme';
import { ease } from '../kit';
import { L } from './theme';

export const clamp = { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' } as const;

/** 0→1 between frames, expo-out. */
export const prog = (f: number, a: number, d = 20) => interpolate(f, [a, a + d], [0, 1], { ...clamp, easing: ease });

/** Light ground: warm-neutral paper with two slow-moving soft lights. */
export const Paper: React.FC<{ children?: React.ReactNode; tint?: string }> = ({ children, tint = 'rgba(47,107,255,0.10)' }) => {
  const f = useCurrentFrame();
  const x = 70 + Math.sin(f / 80) * 8, y = 12 + Math.cos(f / 95) * 6;
  const x2 = 18 + Math.cos(f / 110) * 6, y2 = 88 + Math.sin(f / 90) * 5;
  return (
    <AbsoluteFill style={{ background: L.ground, fontFamily: FONT, color: L.ink, overflow: 'hidden' }}>
      <AbsoluteFill style={{ background: `radial-gradient(55% 55% at ${x}% ${y}%, ${tint}, rgba(255,255,255,0) 70%)` }} />
      <AbsoluteFill style={{ background: `radial-gradient(45% 45% at ${x2}% ${y2}%, rgba(22,128,74,0.07), rgba(255,255,255,0) 70%)` }} />
      <AbsoluteFill style={{ backgroundImage: 'radial-gradient(rgba(17,17,19,0.06) 1px, transparent 1px)', backgroundSize: '28px 28px', opacity: 0.5,
        maskImage: 'radial-gradient(70% 60% at 50% 50%, black, transparent)' }} />
      {children}
    </AbsoluteFill>
  );
};

/** Masked word-by-word rise. */
export const Words: React.FC<{ text: string; at?: number; size: number; weight?: number; color?: string; stagger?: number; align?: 'center' | 'left'; muted?: string[] }> = ({
  text, at = 0, size, weight = 700, color = L.ink, stagger = 3, align = 'center', muted = [],
}) => {
  const f = useCurrentFrame();
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: align === 'center' ? 'center' : 'flex-start', gap: `0 ${size * 0.25}px`,
      fontSize: size, fontWeight: weight, letterSpacing: '-0.04em', lineHeight: 1.06 }}>
      {text.split(' ').map((w, i) => {
        const p = prog(f, at + i * stagger, 22);
        return (
          <span key={i} style={{ display: 'inline-block', overflow: 'hidden', paddingBottom: size * 0.14, marginBottom: -size * 0.14 }}>
            <span style={{ display: 'inline-block', transform: `translateY(${(1 - p) * 110}%)`, color: muted.includes(w) ? L.ink3 : color }}>{w}</span>
          </span>
        );
      })}
    </div>
  );
};

export const Kicker: React.FC<{ children: React.ReactNode; color?: string; o?: number }> = ({ children, color = L.accent, o = 1 }) => (
  <div style={{ display: 'inline-flex', alignItems: 'center', gap: 10, padding: '8px 16px', borderRadius: 999, background: `${color}14`, color,
    fontSize: 22, fontWeight: 650, opacity: o }}>
    <span style={{ width: 8, height: 8, borderRadius: 4, background: color }} />{children}
  </div>
);

/** A macOS window frame around a screenshot. */
export const MacWindow: React.FC<{ src: string; width: number; style?: React.CSSProperties }> = ({ src, width, style }) => (
  <div style={{ width, borderRadius: width * 0.012, overflow: 'hidden', background: L.surface, boxShadow: '0 2px 6px rgba(17,17,19,0.06), 0 70px 160px -50px rgba(17,17,19,0.45), 0 0 0 1px rgba(17,17,19,0.08)', ...style }}>
    <img src={src} style={{ width: '100%', display: 'block' }} />
  </div>
);

/** Card surface used by the code-built UI. */
export const Card: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ background: L.surface, borderRadius: 28, boxShadow: '0 1px 2px rgba(17,17,19,0.05), 0 40px 100px -40px rgba(17,17,19,0.35), 0 0 0 1px rgba(17,17,19,0.06)', ...style }}>{children}</div>
);

/** An animated macOS-style pointer gliding between points. */
export const Pointer: React.FC<{ path: { f: number; x: number; y: number }[]; clickAt?: number[] }> = ({ path, clickAt = [] }) => {
  const f = useCurrentFrame();
  const frames = path.map((p) => p.f);
  const x = interpolate(f, frames, path.map((p) => p.x), { ...clamp, easing: ease });
  const y = interpolate(f, frames, path.map((p) => p.y), { ...clamp, easing: ease });
  const press = clickAt.some((c) => f >= c && f < c + 6) ? 0.85 : 1;
  const ring = clickAt.map((c) => (f >= c && f < c + 18 ? (f - c) / 18 : -1)).find((v) => v >= 0);
  return (
    <div style={{ position: 'absolute', left: x, top: y, transform: `scale(${press})`, transformOrigin: '4px 4px', zIndex: 50, opacity: interpolate(f, [path[0].f - 8, path[0].f], [0, 1], clamp) }}>
      {ring !== undefined && <div style={{ position: 'absolute', left: -26, top: -26, width: 56, height: 56, borderRadius: 28, border: `3px solid ${L.accent}`, opacity: 1 - ring, transform: `scale(${0.4 + ring})` }} />}
      <svg width="34" height="44" viewBox="0 0 17 22"><path d="M1 1 L1 17 L5 13 L8 20 L11 19 L8 12 L14 12 Z" fill="#111113" stroke="#fff" strokeWidth="1.4" strokeLinejoin="round" /></svg>
    </div>
  );
};
