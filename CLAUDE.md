# 프로젝트: Wellsight

건강검진 결과지를 쉽게 해석해 주고, 매일의 건강행동과 주간·월간 AI 리뷰로 이어지게 하는 웰니스 서비스.
- 문서: `docs/PRD.md`, `docs/USER_FLOW.md`, `docs/ARCHITECTURE.md`, `docs/ADR.md`, `docs/UI_GUIDE.md`

## 기술 스택
- `web/`: Next.js(App Router, `src/app`) + TypeScript, Vercel 서울. 스타일링은 디자인 가이드를 받은 뒤 정한다 (TBD)
- `api/`: FastAPI(Python, uv), Cloud Run 서울
- `supabase/`: Postgres·Auth(Google provider) 서울, Supabase CLI 마이그레이션
- LLM: Claude API. 분석은 Opus 5.5(`claude-opus-5-5`), 식단 사진은 Sonnet 5.5(`claude-sonnet-5-5`)
- 개발 단계는 P0~P4, 사용자 여정 단계는 ①~⑤로 표기한다

## 아키텍처 규칙
- CRITICAL: 판정·위급 여부는 시드 규칙 데이터로만 계산한다. AI는 판정을 바꾸지 않는다
- CRITICAL: 결과지 추출은 `extraction` 모듈로만 하고, 추출을 포함한 모든 AI 호출은 `llm` 래퍼를 거친다. 비즈니스 코드에서 Claude SDK를 직접 부르지 않는다
- CRITICAL: 결과지 원본과 식단 사진은 저장하지 않는다(DB·Storage·디스크·로그 모두)
- CRITICAL: 해석·리뷰 AI 입력에 결과지 원문을 넣지 않는다. 확인된 구조화 값만 넣는다
- CRITICAL: 금지 표현 목록(질환명 단정, 질환 가능성, 발병위험도, 신체나이, 약물·치료 조언)은 프롬프트에 넣는다
- CRITICAL: AI 출력은 일반 텍스트로 렌더링한다(HTML·마크다운 렌더링 금지)
- CRITICAL: 프론트는 DB를 직접 읽지 않고 FastAPI만 호출한다. 앱 테이블은 `app` 스키마에 두고 RLS를 건다
- CRITICAL: user_id는 검증된 JWT에서만 꺼낸다. 요청 본문·쿼리의 user_id는 쓰지 않는다
- CRITICAL: 로그에 건강정보, 요청·응답 본문, 프롬프트 원문을 남기지 않는다
- CRITICAL: 건강 데이터 샘플(결과지 PDF·사진 등)은 커밋하지 않는다
- CRITICAL: 런타임 습관은 검수된 습관 라이브러리(`api/app/seed/habits.json`)에서만 가져온다
- CRITICAL: 날짜는 KST로 다룬다(오늘, 소급 마감, 주·월 경계, 리뷰 기준일)
- CRITICAL: AI 생성은 POST로만 하고 GET은 AI를 호출하지 않는다. 서버가 검진당 1회와 리뷰 주기(7일·30일)를 판단하고, 생성한 결과를 재사용한다
- CRITICAL: AI 리뷰는 분석 범위와 생성 당시 기록을 보존하고, 기록 기준 시점을 표시한다
- 디렉토리 구조, 데이터 모델, API 계약은 `docs/ARCHITECTURE.md`를 따른다

## 개발 프로세스
- CRITICAL: 새 기능 구현 시 반드시 테스트를 먼저 작성하고, 테스트가 통과하는 구현을 작성할 것 (TDD)
- 판정·위급 수치·영양 계산·날씨 규칙은 순수 함수로 만들고 테스트한다. LLM 호출은 고정 응답(fixture)으로 테스트한다
- Python 테스트는 `api/tests/test_*.py`에 둔다
- 커밋 메시지는 conventional commits 형식을 따를 것 (feat:, fix:, docs:, refactor:)

## 명령어
P0에서 구성한다.
```
npm run lint                # web + api
npm run build               # web + api
npm run test                # web + api
npm run dev --prefix web    # 웹 개발 서버
uv run fastapi dev          # API 개발 서버 (api/에서 실행)
supabase start              # 로컬 Supabase
```
