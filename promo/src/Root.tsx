import React from 'react';
import { Composition, Series } from 'remotion';
import { FPS } from './theme';
import { Hook, Intro, Loop, Outro, Private, Ribbon, Screens, Today, Verdicts } from './scenes';

const scenes: [React.FC, number][] = [
  [Intro, 90],
  [Hook, 142],
  [Today, 210],
  [Verdicts, 180],
  [Ribbon, 180],
  [Loop, 210],
  [Screens, 180],
  [Private, 140],
  [Outro, 120],
];

const total = scenes.reduce((n, [, d]) => n + d, 0);

const Promo: React.FC = () => (
  <Series>
    {scenes.map(([Scene, d], i) => (
      <Series.Sequence key={i} durationInFrames={d}>
        <Scene />
      </Series.Sequence>
    ))}
  </Series>
);

export const Root: React.FC = () => <Composition id="Promo" component={Promo} durationInFrames={total} fps={FPS} width={1920} height={1080} />;
