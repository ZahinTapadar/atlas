import React from 'react';
import { AbsoluteFill, Audio, interpolate, staticFile } from 'remotion';
import { TransitionSeries, linearTiming } from '@remotion/transitions';
import { fade } from '@remotion/transitions/fade';
import { slide } from '@remotion/transitions/slide';
import { Hook, Opening } from './open';
import { CheckinsScene, ReportsScene, TodayScene, TodosScene } from './product';
import { EmailScene, InstallScene, Outro, ScheduleScene, SetupScene } from './close';

const T = 16;
export const scenes: [React.FC, number, 'fade' | 'slide'][] = [
  [Opening, 112, 'fade'],
  [Hook, 142, 'fade'],
  [TodayScene, 200, 'fade'],
  [TodosScene, 200, 'slide'],
  [CheckinsScene, 150, 'slide'],
  [ReportsScene, 190, 'slide'],
  [EmailScene, 196, 'slide'],
  [ScheduleScene, 150, 'slide'],
  [SetupScene, 140, 'slide'],
  [InstallScene, 176, 'fade'],
  [Outro, 130, 'fade'],
];
export const filmLength = scenes.reduce((n, [, d]) => n + d, 0) - T * (scenes.length - 1);

export const Film: React.FC<{ music?: boolean }> = ({ music = true }) => (
  <AbsoluteFill style={{ background: '#f4f4f6' }}>
    {music && (
      <Audio src={staticFile('music.mp3')}
        volume={(f) => interpolate(f, [0, 20, filmLength - 60, filmLength], [0, 0.9, 0.9, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })} />
    )}
    <TransitionSeries>
      {scenes.flatMap(([Scene, d, kind], i) => {
        const seq = <TransitionSeries.Sequence key={`s${i}`} durationInFrames={d}><Scene /></TransitionSeries.Sequence>;
        if (i === scenes.length - 1) return [seq];
        const next = scenes[i + 1][2];
        return [seq, <TransitionSeries.Transition key={`t${i}`} timing={linearTiming({ durationInFrames: T })}
          presentation={next === 'slide' ? slide({ direction: 'from-right' }) : fade()} />];
      })}
    </TransitionSeries>
  </AbsoluteFill>
);
