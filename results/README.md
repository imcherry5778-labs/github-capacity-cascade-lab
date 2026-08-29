# Experiment evidence

`results/` 아래에는 로컬 scenario 실행에서 생성된 evidence가 저장된다. 각 실행은
`results/<scenario>/<UTC timestamp>/` 형태의 새 디렉터리를 사용하며 기존 결과를
덮어쓰지 않는다.

생성 결과는 머신 종속적인 exploratory evidence이므로 기본적으로 Git에서 제외한다.
공유 가능한 portfolio evidence로 승격할 때에는 반복 실행, 동일 조건 비교, secret 검토를
별도로 수행한다.
