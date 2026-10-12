# 아키텍처

## 구성
```
브라우저 (Next.js 반응형 웹, Vercel 서울)
│  Supabase Auth(Google) 로그인 → access token을 Bearer로 FastAPI 직접 호출
│  사진은 브라우저에서 축소 · EXIF 제거 후 업로드
▼
FastAPI (Cloud Run 서울) ── JWT 검증 → 허용 이메일 → 프로필·동의 → Pro 권한·AI 생성 가능 여부 → 비즈니스 로직
│  ├─ extraction: 추출 함수 하나 (MVP = llm 래퍼로 Opus 호출, P4 = 서버 내장 모델)
│  ├─ judgment · safety: 순수 함수 (결과 + 시드 JSON → 판정 · 위급 여부)
│  ├─ llm: Claude 호출 래퍼 (용도별 모델, JSON 스키마 강제, 사용량 기록, 일일 비용 한도)
│  ├─ habits: 라이브러리 JSON + 날씨 태그 규칙
│  ├─ nutrition: 식약처 DB(적재본) 계산
│  ├─ weather: 기상청 · 에어코리아 시도별 (메모리 캐시)
│  └─ billing: Polar checkout · webhook(서명 검증, 멱등) — P4에서 연결
├─▶ Supabase Postgres 서울: `app` 스키마 (Data API 비노출 + RLS)
└─▶ 외부: Claude API · 기상청 · 에어코리아 · Polar
```

## 디렉토리 구조
```
web/                 Next.js (src/app, components, lib/api-client, lib/supabase-auth, types)
api/
  app/routers/       extractions, checkups, habits, today, meals, reviews, billing, me
  app/services/      extraction, judgment, safety, llm, habits, weather, nutrition, billing
  app/schemas/       Pydantic 요청·응답 모델 (API 계약)
  app/seed/          standard_items.json(판정 기준·위급 수치 포함), habits.json, regions.json
  app/db/            쿼리
  tests/             test_*.py
supabase/
  migrations/        스키마 · RLS (단일 출처, Supabase CLI)
  seed/              식약처 영양성분 적재 스크립트
package.json         루트 lint·build·test → web + api 모두 실행 (Stop 훅·harness 그대로 사용)
```
- 샘플 결과지(개인 건강정보)는 git 제외 폴더에만 둔다. 샘플 제공 방식은 별도 상담 (TBD)

## 패턴 (설계 규칙)
1. 비즈니스 코드는 Claude를 직접 부르지 않는다. 결과지 추출은 `extraction` 모듈의 함수 하나로 하고, 나머지 AI 호출은 `llm` 래퍼로만 한다. 이렇게 하면 공개 전 교체 지점이 하나가 된다. MVP의 추출 구현도 내부에서 `llm` 래퍼를 써서 사용량 기록과 일일 한도를 똑같이 적용받는다
2. harness 정합(P0에서 수행)
   - 루트 `package.json` 스크립트가 web·api 양쪽을 실행한다
   - `tdd-guard.sh`에 `*.py` 규칙을 추가한다(`test_*.py`, `api/tests/` 허용)
   - `.gitignore`에 Python·Supabase 산출물과 샘플 폴더를 추가한다
3. 업로드는 브라우저에서 FastAPI로 직접 보낸다. Cloud Run 요청 32MB 제한 때문에 사진은 축소한다. 추출은 파일 단위로 동기 처리한다
4. 날짜는 모두 KST로 다룬다. 적용 대상은 '오늘', 소급 마감(다음 날 23:59:59), 무료 주간 달성률의 주(월요일~일요일), AI 리뷰 기준일과 분석 범위(날짜 단위)다
5. 판정·위급 수치·영양 계산·날씨 규칙은 외부 호출이 없는 순수 모듈로 만들고 TDD한다. LLM 호출은 고정 응답(fixture)으로 테스트한다
6. AI 생성은 POST 요청으로만 하고, GET은 AI를 호출하지 않는다. 검진 해석은 값을 저장한 직후 클라이언트가 자동으로 요청한다. 주간·월간 리뷰는 사용자가 활성화된 버튼을 눌러 요청한다. 서버는 권한, 생성 상태, 검진당 1회, 리뷰 주기(7일·30일)를 확인하고, 생성된 결과를 조회할 때는 AI를 다시 호출하지 않는다. 실패한 생성은 재시도할 수 있다
7. AI 리뷰의 분석 범위, 생성 당시 입력 요약, 생성 시각을 보존한다. 소급 입력이나 새 검진 등록 후에도 해당 리뷰를 유지하고, 화면에 기록 기준 시점을 표시한다
8. 해석·리뷰 AI 입력에는 결과지 원문을 넣지 않고 확인된 구조화 값만 넣는다. 금지 표현 목록은 프롬프트에 넣는다

## 데이터 흐름
### 결과지 → 해석
```
업로드(PDF·사진) → POST /extractions: extraction(Opus)이 항목 추출·항목군 분류 → 초안 JSON 응답 (원본 저장 없음)
→ 브라우저: 확인 표(의심 항목 강조) → '모두 맞음'
→ POST /checkups: 확인값 저장, judgment·safety로 판정·위급 여부 계산
→ 클라이언트가 자동으로 POST /checkups/{id}/report/ai 호출
   (이번 검진 확인값 + DB의 이전 검진 값 + 이전 검진 이후 실천 기록 요약 → Opus → 저장)
→ GET /checkups/{id}/report: 규칙 판정·추이·저장된 AI 해석 표시
```
- 한 번에 여러 검진을 저장하면(여러 해가 든 PDF) 가장 최근 검진만 AI 해석을 요청하고, 이전 검진은 비교 값으로 쓴다

### AI 리뷰
```
GET /reviews?kind=weekly → 생성 가능 여부·다음 활성화 날짜 (AI 호출 없음)
→ 버튼 활성화 → POST /reviews/weekly
→ 서버: 권한(Pro 또는 첫 무료 1회) · 주기 · 생성 상태 확인 → 분석 범위의 기록 요약 → Opus → 저장
```
- 기준일: 같은 종류의 마지막 성공 리뷰 생성일, 첫 리뷰는 습관 첫 등록일(KST 날짜). 주간은 기준일 + 7일, 월간은 기준일 + 30일부터 생성할 수 있다. 주간·월간 타이머는 서로 독립이다
- 분석 범위: 직전 같은 종류 리뷰의 범위 다음 날부터 생성일까지(첫 리뷰는 습관 첫 등록일부터). 최신 검진과 범위 안의 실천·식단 기록을 쓰고, 월간은 자가측정도 포함한다

### 오늘의 건강행동
```
GET /today → 유효한 user_habits + 날씨(캐시) → habits 규칙이 날씨 태그로 대체 습관 선택 → 체크 상태·이번 주 달성률 (AI 호출 없음)
```

## 상태 관리
- 서버 상태는 FastAPI 응답이 단일 출처다
- 클라이언트 상태는 추출 초안 정도로 최소화한다. 초안은 브라우저에만 있다

## 데이터 모델 (MVP, 테이블 11개 + 적재 1개)
- `users`: 성별, 출생연도, 시도 코드, 민감정보·국외이전 동의 시각, 동의 문구 버전
- `checkups`: 검진일, 기관, 국가검진/추가 검사, AI 해석 생성 상태·시각, AI 해석 요약(이전 검진 대비 변화·실천 회고)
  - 동일 검진 중복은 구분하되, 같은 날 같은 기관의 일반검진·추가 검사와 분할 업로드는 함께 등록할 수 있게 한다. 식별·병합 방식은 P1 구현 때 정한다 (TBD)
- `results`: 표준 항목 코드 또는 원문 항목명, 항목군, 값, 단위, 참고치 원문, 기관 판정, 계산 판정, 판정 근거, AI 설명 텍스트
- `goals`: 관리 목표(최대 3개)
- `user_habits`: 습관 id, 개인화 문구, 유효 시작·종료일
- `habit_checks`: KST 날짜, 소급 여부
- `meals`: 사진/직접 입력, 음식·양·영양 합계, 추정치 여부
- `measurements`: 체중·허리둘레·혈압
- `reviews`: 주간/월간 구분, 분석 범위(시작·끝 날짜), 생성 상태·시각, 참조 검진 id, 생성 당시 입력 요약·달성률, AI 텍스트, 무료 체험 여부
  - 생성 가능 여부는 같은 종류의 마지막 성공 리뷰 생성일(없으면 습관 첫 등록일) + 7일·30일로 판단한다
  - `(user_id, 종류) WHERE 상태 = 생성 중` 부분 유니크로 동시 생성을 막는다
  - `(user_id) WHERE 무료 체험` 부분 유니크로 첫 무료 1회를 보장한다
- `subscriptions`: 출처(manual/polar), Polar id(nullable), 상태, 기간, 마지막 이벤트 시각. 테이블은 P0에서 만든다. P4 전에는 SQL로 넣은 수동 행으로 Pro를 부여하고, Polar 연동은 P4에서 한다
- `ai_usage`: 사용자, 용도, 모델, 비용, 시각. `llm` 래퍼가 추출을 포함한 모든 호출을 기록하고, 오늘(KST) 비용 합계로 일일 한도를 판단한다
- (적재) `foods`: 식약처 영양성분, pg_trgm 검색

## 인터페이스 (REST 초안)
- 계정: `GET /me`, `PUT /me`(성별·출생연도·시도), `POST /consents`, `DELETE /me`
- 결과지
  - `POST /extractions`(PDF·사진 → 초안 JSON, 저장 없음)
  - `POST /checkups`(확인된 값 저장)
  - `DELETE /checkups/{id}`
- 해석
  - `GET /checkups/{id}/report`(규칙 판정·저장된 AI 해석·생성 상태, AI 호출 없음)
  - `POST /checkups/{id}/report/ai`(값 저장 직후 클라이언트가 자동 호출. 검진당 성공한 생성 1회, 이미 생성됐으면 저장된 해석 반환, 실패하면 재시도)
  - `GET /trends?items=`
- 목표·습관
  - `POST /habits/recommendations`(목표 설정 때 AI 선택·개인화)
  - `POST /goals`, `POST /user-habits`
  - `PATCH /user-habits/{id}`(유효 종료일 설정, 계획 조정)
- 오늘: `GET /today`(AI 호출 없음), `POST /habit-checks`(오늘 또는 어제, KST), `DELETE /habit-checks/{id}`(체크 취소, 소급 마감 동일)
- 식단: `GET /foods/search?q=`, `POST /meals`, `PATCH /meals/{id}`, `DELETE /meals/{id}`, `POST /meals/photo`(Pro, Sonnet, 인식 초안 반환, 사진 저장 없음)
- 리뷰
  - `POST /measurements`, `GET /measurements`(자가측정 기록·변화)
  - `GET /achievements/weekly/{week}`(달력 주 달성률, 무료. `{week}`는 ISO 주, 예: `2026-W42`)
  - `GET /reviews?kind=weekly|monthly`(저장된 AI 리뷰 목록·생성 상태·생성 가능 여부·다음 활성화 날짜, AI 호출 없음)
  - `POST /reviews/weekly`(마지막 주간 리뷰 + 7일 이후, Pro 또는 첫 무료 1회)
  - `POST /reviews/monthly`(마지막 월간 회고 + 30일 이후, Pro)
- 결제(P4): `POST /billing/checkout`, `POST /webhooks/polar`
- 에러 형식
  - 응답은 `{code, message}`
  - code: `not_allowed`, `consent_required`(프로필·동의 미완료), `age_restricted`, `pro_required`, `review_not_ready`, `generation_in_progress`, `ai_failed`, `ai_paused`, `encrypted_pdf`, `file_too_large`, `not_owner_document`, `duplicate_checkup`, `extraction_failed`

## 외부 의존성
| 대상 | 용도 | 비고 |
|---|---|---|
| Claude API | 추출·해석·습관 추천·리뷰는 Opus 5.5(`claude-opus-5-5`), 식단 사진은 Sonnet 5.5(`claude-sonnet-5-5`) | 모델 ID는 `llm` 래퍼 설정 한 곳에서 관리한다. 호출 코드는 구현할 때 claude-api 스킬로 최신 SDK 사용법을 확인한다 |
| Supabase | Postgres, Auth(Google provider), JWKS | dev/prod 프로젝트 분리 |
| 기상청 단기예보 | 날씨 | 시도 대표 좌표 → 격자 변환 공식, FastAPI 메모리 캐시(TTL) |
| 에어코리아 시도별 API | 미세먼지 | FastAPI 메모리 캐시(TTL) |
| 식약처 식품영양성분 DB | 영양 계산 | `foods` 테이블에 적재 |
| 질병관리청 건강수칙 | 날씨 맞춤 습관 문구의 출처 | 화면에 출처 표기 |
| Polar | 구독 결제 | P4 |
| Vercel · Cloud Run | 웹 · API 호스팅 | 서울 리전 |

## 엣지케이스·에러 처리
| # | 상황 | 처리 |
|---|---|---|
| E1 | 암호가 걸린 PDF | 거부하고 "인쇄 → PDF로 저장" 방법을 안내 (`encrypted_pdf`) |
| E2 | 큰 파일·많은 페이지 | 파일 크기와 페이지 수 상한 (`file_too_large`). 사진은 브라우저에서 축소 |
| E3 | 한 PDF에 여러 해 결과 | 검진일별로 여러 `checkups` 초안으로 나눈다. AI 해석은 가장 최근 검진만 자동 생성하고, 이전 검진은 비교 값으로 쓴다 |
| E4 | 타인 결과지 | 성별·출생연도가 프로필과 다르면 차단 (`not_owner_document`) |
| E5 | 같은 날 같은 기관의 검사·분할 업로드·중복 | 일반검진과 추가 검사는 함께 등록할 수 있게 한다. 분할 업로드 시 기존 항목을 보존하는 식별·병합 규칙은 P1 구현 때 정하고(TBD), 실제 중복만 `duplicate_checkup`으로 안내한다 |
| E6 | Claude 오류(429·529·5xx·시간 초과) | 지수 백오프로 재시도. 추출이 실패하면 `extraction_failed` + "다시 올려 주세요", 해석·리뷰 생성이 실패하면 `ai_failed` + '다시 시도' 버튼 |
| E7 | 스키마 위반·이상값·다른 단위 | 표준 항목의 기대 단위·허용 범위와 다르면 확인 표에서 강조. 단위 변환·참고치 파싱·정규화 실패 시 판정·추이 처리 규칙은 P1 구현 때 정한다 (TBD) |
| E8 | 확인 전에 이탈 | 초안은 브라우저에만 있으므로 다시 업로드 |
| E9 | 판정 근거 없음 | '판정 없음' + 설명만. 성별 기준이 필요하면 프로필 성별을 쓴다 |
| E10 | 검진일 누락이나 미래 날짜 | 확인 단계에서 입력 요구 |
| E11 | 날씨 API 실패·지연 | 캐시를 쓰고, 캐시가 없으면 날씨를 반영하지 않은 기본 습관 + 안내 문구 |
| E12 | 주중에 목표·습관을 바꿈 | 습관 유효 기간 기준으로 그날 유효했던 습관만 달성률에 넣는다 |
| E13 | 위급 수치 | 진료 안내를 최우선으로 표시 |
| E14 | 자가측정·식단 입력 오류 | 허용 범위 검증 |
| E15 | 음식이 아닌 사진, 인식 실패, DB에 없는 음식 | 수정이나 직접 입력으로 전환. DB에 없으면 유사 항목 + '추정치' |
| E16 | Polar webhook 중복·순서 뒤바뀜(P4) | 이벤트 id로 멱등 처리, 최신 이벤트 시각만 반영. 결제 완료 페이지는 권한을 주지 않는다 |
| E17 | AI 해석·리뷰 중복 요청 또는 생성 실패 | 검진별·리뷰 종류별 생성 상태를 서버에서 확인한다. 생성 중이면 `generation_in_progress`로 막고, 완료된 결과는 재사용하며, 실패하면 재시도를 허용한다. 인스턴스 재시작에 대비해 생성 중 상태가 10분을 넘으면 실패로 본다. 첫 무료 AI 리뷰는 `reviews`의 부분 유니크 제약으로 성공한 생성 1회만 사용 처리한다 |
| E18 | 탈퇴 | DB 행 + Supabase auth 사용자 삭제. Anthropic API 보관 정책은 처리방침에 명시(구현 시 확인) |
| E19 | AI 비용 차단기 발동 | AI 기능만 `ai_paused`로 막는다. 체크·직접 입력·판정·추이는 정상 동작 |
| E20 | AI 리뷰 생성 후 소급 입력·새 검진 등록 | 무료 달성률·추이는 최신 기록으로 계산한다. AI 리뷰는 생성 당시 입력 요약·검진 기준으로 유지하고 '○월 ○일 기록 기준'을 표시한다 |
| E21 | 허용 목록에 없는 이메일로 로그인(P4 전) | `not_allowed` + "현재 비공개 테스트 중" 안내 |
| E22 | 습관 등록 전이거나 리뷰 주기(7일·30일) 전에 생성 요청 | `review_not_ready` + 다음 활성화 날짜 |

## 보안
| # | 위협 | 대책 |
|---|---|---|
| S1 | anon 키로 건강 데이터 조회 | `app` 스키마 비노출 + RLS |
| S2 | 다른 사용자 데이터 조회(IDOR) | user_id는 검증된 JWT에서만 꺼낸다. 모든 쿼리에 user_id 조건을 건다. 교차 사용자 접근 테스트 필수 |
| S3 | JWT 위조 | Supabase JWKS로 서명, `exp`, `aud`, `iss` 검증 |
| S4 | 비밀 키 노출 | service key, Claude, Polar, 공공 API 키는 Cloud Run 시크릿에만 둔다. 웹에는 anon 키와 URL만 둔다 |
| S5 | 악성 파일 | magic byte 검사, 크기·페이지·픽셀 상한, 처리 시간 제한, 파서 라이브러리 최신 유지 |
| S6 | 결과지 속 프롬프트 인젝션 | 추출은 JSON 스키마 강제 + 도구 없음 + 범위 검증 + 사용자 확인. 해석·리뷰에는 원문을 넣지 않는다 |
| S7 | AI 출력으로 XSS | 일반 텍스트로 렌더링 + CSP 헤더 |
| S8 | CORS 오설정 | 운영 도메인과 이 프로젝트 전용 preview 패턴만 허용한다. `*.vercel.app` 전체 허용 금지 |
| S9 | 가짜 Polar webhook(P4) | 서명 검증 |
| S10 | 로그로 건강정보 유출 | 요청·응답 본문과 프롬프트 원문은 로그에 남기지 않는다 |
| S11 | Claude 비용 폭증 공격 | 가입 허용 이메일 제한 + AI 해석 검진당 1회·리뷰 7일·30일 주기 + 일일 비용 한도(기본 $5, `ai_paused`) + Console 월 한도($30) |
| S12 | preview·로컬에서 실제 데이터 접근 | Supabase dev/prod 분리. preview·로컬은 dev만 쓴다 |
| S13 | 데이터 유실 | 본인 테스트 기간은 위험을 감수하고, 공개 전 Pro 전환 때 백업 확인 |
| S14 | MVP에서 원본이 Claude(국외)로 전송됨 | 동의 문구에 명시하고 서버에는 저장하지 않는다. 서버 내장 모델 교체가 공개 출시 조건 |
| S15 | 출시 전 법적 요건 | 공개 출시 조건의 법적 체크리스트(전문가 확인) |
| S16 | P4 전 외부인의 가입·결과지 업로드 | 허용 이메일 목록(`ALLOWED_EMAILS`) 밖이면 `not_allowed`. 해제는 공개 출시 조건 |

## TBD
- 샘플 결과지(PDF·사진) 제공 방식: 별도 상담. git 제외 폴더에 둔다
- 위급 수치 기준값과 출처: 판정 기준(별표4)이나 습관 라이브러리처럼 근거를 붙이고 본인이 검수한다. P1 구현 전에 확정한다
- 검사값 단위 정규화·참고치 파싱·정규화 실패 처리, 같은 날 같은 기관의 일반검진·추가 검사 등록 방식: P1 구현 때 정한다
- 서버 내장 추출 모델 선정: P4 준비 단계
- 배포 자동화, 에러 모니터링 도구
- 디자인 가이드: 사용자가 별도로 제공한다
