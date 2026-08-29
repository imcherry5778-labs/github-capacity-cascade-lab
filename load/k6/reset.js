import { resetFault } from './lib/admin.js';

// Local runner의 EXIT trap에서도 호출할 수 있는 독립 fault 정리 스크립트다.
export const options = { vus: 1, iterations: 1 };

export default function () {
  // 실험이 실패하거나 중단되어도 다음 실행에 fault가 남지 않게 한다.
  resetFault();
}
