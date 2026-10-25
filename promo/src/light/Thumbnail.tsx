import React from 'react';
import { AbsoluteFill, Img, staticFile } from 'remotion';
import { FONT } from '../theme';
import { L } from './theme';

/** Poster and link-preview image: the promise on the left, the product on the right. `w` sets the layout scale. */
export const Thumbnail: React.FC<{ w?: number }> = ({ w = 1920 }) => {
  const s = w / 1920;
  const D = { card: '#1a1a1e', ink: '#f4f4f6', ink2: '#a1a1aa', on: '#3dd68c' };
  return (
    <AbsoluteFill style={{ background: L.ground, fontFamily: FONT, color: L.ink, overflow: 'hidden' }}>
      <AbsoluteFill style={{ background: 'radial-gradient(60% 70% at 78% 30%, rgba(47,107,255,0.16), rgba(255,255,255,0) 70%), radial-gradient(45% 55% at 8% 95%, rgba(22,128,74,0.10), rgba(255,255,255,0) 70%)' }} />
      <AbsoluteFill style={{ backgroundImage: 'radial-gradient(rgba(17,17,19,0.07) 1px, transparent 1px)', backgroundSize: `${28 * s}px ${28 * s}px`,
        maskImage: 'radial-gradient(60% 70% at 30% 50%, black, transparent)' }} />

      {/* Product, right */}
      <div style={{ position: 'absolute', left: 860 * s, top: 150 * s, width: 1500 * s, transform: 'perspective(2600px) rotateY(-14deg) rotateX(6deg)', transformOrigin: 'left center' }}>
        <div style={{ borderRadius: 18 * s, overflow: 'hidden', boxShadow: `0 ${4 * s}px ${8 * s}px rgba(17,17,19,0.06), 0 ${80 * s}px ${160 * s}px -${50 * s}px rgba(17,17,19,0.5), 0 0 0 ${1.5 * s}px rgba(17,17,19,0.08)` }}>
          <Img src={staticFile('today-light.webp')} style={{ width: '100%', display: 'block' }} />
        </div>
      </div>

      {/* Phone with the email */}
      <div style={{ position: 'absolute', left: 1430 * s, top: 330 * s, width: 330 * s, height: 680 * s, borderRadius: 56 * s, background: '#0b0b0d', padding: 11 * s,
        boxShadow: `0 ${60 * s}px ${120 * s}px -${30 * s}px rgba(17,17,19,0.6), 0 0 0 ${2 * s}px #2a2a30`, transform: 'rotate(4deg)' }}>
        <div style={{ width: '100%', height: '100%', borderRadius: 46 * s, background: '#0e0e10', overflow: 'hidden', padding: `${58 * s}px ${16 * s}px`, color: D.ink }}>
          <div style={{ fontSize: 11 * s, letterSpacing: 2.5 * s, fontWeight: 800 }}>ATLAS</div>
          <div style={{ marginTop: 12 * s, borderRadius: 18 * s, padding: 16 * s, background: 'linear-gradient(180deg, rgba(61,214,140,0.18), rgba(61,214,140,0.05))', border: `${1 * s}px solid rgba(61,214,140,0.3)` }}>
            <div style={{ fontSize: 30 * s, fontWeight: 800, color: D.on, letterSpacing: -1 * s }}>On track</div>
            <div style={{ fontSize: 13 * s, fontWeight: 600, marginTop: 6 * s, lineHeight: 1.35 }}>1h 39m of focused coding, gaming held to 16 minutes.</div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 * s, marginTop: 12 * s }}>
            {[['77%', 'focus share'], ['4 days', 'streak']].map(([v, l]) => (
              <div key={v} style={{ background: D.card, borderRadius: 12 * s, padding: 10 * s }}>
                <div style={{ fontSize: 20 * s, fontWeight: 800, color: D.on }}>{v}</div><div style={{ fontSize: 10 * s, color: D.ink2 }}>{l}</div>
              </div>
            ))}
          </div>
          <div style={{ marginTop: 12 * s, background: D.card, borderRadius: 12 * s, padding: 10 * s, display: 'flex', gap: 3 * s, alignItems: 'flex-end', height: 70 * s }}>
            {[0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.85, 0.55, 0.75, 0.95, 0.6, 0.8].map((h, i) => (
              <div key={i} style={{ flex: 1, height: `${h * 100}%`, borderRadius: 3 * s, background: ['#2f6bff', '#0b8bc6', '#0f9f98', '#7c4ddb'][i % 4] }} />
            ))}
          </div>
          <div style={{ marginTop: 14 * s, fontSize: 12 * s, fontWeight: 700 }}>Today's to-dos</div>
          <div style={{ marginTop: 8 * s, background: D.card, borderRadius: 12 * s, padding: `${4 * s}px ${12 * s}px` }}>
            {[['Read Chapter 7', true], ['Lab 4 analysis', true], ['Problem set 3', false], ['Review before tutorial', false]].map(([t, d], i) => (
              <div key={i} style={{ display: 'flex', gap: 8 * s, alignItems: 'center', padding: `${8 * s}px 0`, borderTop: i ? `${1 * s}px solid #2a2a30` : 'none', fontSize: 12 * s,
                color: d ? D.ink2 : D.ink, textDecoration: d ? 'line-through' : 'none' }}>
                <span style={{ width: 11 * s, height: 11 * s, borderRadius: 6 * s, background: d ? D.on : 'transparent', border: d ? 'none' : `${2 * s}px solid #6e6e78` }} />{t as string}
              </div>
            ))}
          </div>
          <div style={{ marginTop: 12 * s, padding: 12 * s, borderRadius: 12 * s, background: 'rgba(61,214,140,0.12)', fontSize: 12 * s, fontWeight: 650, lineHeight: 1.35 }}>
            <span style={{ color: D.on }}>Next</span> · Review Chapter 7 before the 4:30 tutorial.
          </div>
        </div>
      </div>

      {/* Floating chips */}
      <div style={{ position: 'absolute', left: 900 * s, top: 760 * s, padding: `${16 * s}px ${22 * s}px`, borderRadius: 20 * s, background: L.surface, display: 'flex', gap: 14 * s, alignItems: 'center',
        boxShadow: `0 ${30 * s}px ${60 * s}px -${24 * s}px rgba(17,17,19,0.4), 0 0 0 ${1 * s}px rgba(17,17,19,0.06)` }}>
        <div style={{ width: 40 * s, height: 40 * s, borderRadius: 20 * s, background: L.on, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 22 * s, fontWeight: 900 }}>✓</div>
        <div><div style={{ fontSize: 22 * s, fontWeight: 750 }}>Problem set done</div><div style={{ fontSize: 16 * s, color: L.ink3 }}>85-minute focus block</div></div>
      </div>

      {/* Copy, left */}
      <div style={{ position: 'absolute', left: 120 * s, top: 0, bottom: 0, width: 700 * s, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 20 * s }}>
          <Img src={staticFile('icon.png')} style={{ width: 92 * s, filter: `drop-shadow(0 ${14 * s}px ${24 * s}px rgba(17,17,19,0.25))` }} />
          <div style={{ fontSize: 44 * s, fontWeight: 800, letterSpacing: '0.2em' }}>ATLAS</div>
        </div>
        <div style={{ fontSize: 104 * s, fontWeight: 800, letterSpacing: '-0.045em', lineHeight: 1.0, marginTop: 44 * s }}>Know where your time actually goes.</div>
        <div style={{ fontSize: 30 * s, color: L.ink2, marginTop: 28 * s, lineHeight: 1.4, fontWeight: 500 }}>A Mac time tracker with Claude check-ins that tell you, plainly, if you're on track.</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 20 * s, marginTop: 44 * s }}>
          <div style={{ width: 88 * s, height: 88 * s, borderRadius: 44 * s, background: L.ink, display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: `0 ${20 * s}px ${40 * s}px -${16 * s}px rgba(17,17,19,0.6)` }}>
            <svg width={34 * s} height={34 * s} viewBox="0 0 24 24"><path d="M8 5.5v13l11-6.5z" fill="#fff" /></svg>
          </div>
          <div style={{ fontSize: 26 * s, fontWeight: 700 }}>Watch the film <span style={{ color: L.ink3, fontWeight: 500 }}>· 54 s</span></div>
        </div>
      </div>
    </AbsoluteFill>
  );
};
