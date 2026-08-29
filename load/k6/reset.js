import { resetFault } from './lib/admin.js';

export const options = { vus: 1, iterations: 1 };

export default function () {
  resetFault();
}
