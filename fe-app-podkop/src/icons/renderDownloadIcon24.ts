import { svgEl } from '../helpers';

export function renderDownloadIcon24() {
  const NS = 'http://www.w3.org/2000/svg';
  return svgEl(
    'svg',
    {
      xmlns: NS,
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'lucide lucide-download',
    },
    [
      svgEl('path', { d: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4' }),
      svgEl('polyline', { points: '7 10 12 15 17 10' }),
      svgEl('line', { x1: '12', y1: '15', x2: '12', y2: '3' }),
    ],
  );
}
