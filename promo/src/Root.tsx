import React from 'react';
import { Composition, Series, Still } from 'remotion';
import { FPS } from './theme';
import { Hook, Intro, Loop, Outro, Private, Ribbon, Screens, Today, Verdicts } from './scenes';
import { Film, filmLength } from './light/Film';
import { Thumbnail } from './light/Thumbnail';

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

export const Root: React.FC = () => (
  <>
    <Composition id="Promo" component={Promo} durationInFrames={total} fps={FPS} width={1920} height={1080} />
    <Still id="Thumbnail" component={Thumbnail} width={1920} height={1080} defaultProps={{ w: 1920 }} />
    <Still id="OpenGraph" component={Thumbnail} width={1200} height={630} defaultProps={{ w: 1120 }} />
    <Composition id="Film" component={Film} durationInFrames={filmLength} fps={FPS} width={1920} height={1080} defaultProps={{ music: true }} />
  </>
);
